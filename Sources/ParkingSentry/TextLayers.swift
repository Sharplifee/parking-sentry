import Foundation
import NaturalLanguage

/// Language layers run on whatever text the other layers have produced — the
/// transcript and anything read off a sign — so they are only useful with
/// transcription or OCR also switched on. Each one says so rather than sitting
/// there producing nothing.
///
/// NLTagger is explicitly documented as not thread-safe, including its
/// read-looking query methods, so every layer below owns its own tagger and none
/// of them share one.

/// Collects text from any layer that produces it, so language layers have an input.
final class TextBus {

    static let shared = TextBus()

    struct Entry {
        let text: String
        let source: String
        let at: Date
    }

    private var entries: [Entry] = []
    private let lock = NSLock()
    /// Bumped on every addition so a language layer can tell whether there is
    /// anything new without re-processing the same sentence every frame.
    private(set) var version = 0

    func add(_ text: String, source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return }
        lock.lock()
        entries.append(Entry(text: trimmed, source: source, at: Date()))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        version += 1
        lock.unlock()
    }

    /// Everything from the last `seconds`, oldest first.
    func recent(seconds: TimeInterval = 180) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-seconds)
        return entries.filter { $0.at > cutoff }
    }

    var latest: Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.last
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.isEmpty
    }
}

/// Shared base: language layers are driven off the frame clock because there is no
/// text clock, but they only do work when TextBus has something new.
class TextDrivenLayer: VideoAILayer {
    var id: String { "" }
    var title: String { "" }
    var detail: String { "" }
    let group = LayerGroup.language
    let modality = LayerModality.text
    var availability: LayerAvailability {
        TextBus.shared.isEmpty
            ? .needsSetup("Needs text — switch on Live transcription or Scene text")
            : .available
    }
    /// Text does not change thirty times a second.
    let preferredInterval = 15

    private var lastVersion = -1

    final func process(_ ctx: FrameContext) throws -> LayerOutput? {
        let version = TextBus.shared.version
        guard version != lastVersion else { return nil }
        lastVersion = version
        return analyze()
    }

    func analyze() -> LayerOutput? { nil }
}

// MARK: - Sentiment

final class SentimentLayer: TextDrivenLayer {
    override var id: String { "text.sentiment" }
    override var title: String { "Sentiment" }
    override var detail: String { "Scores the tone of what has been said or read, -1 to +1." }

    private let tagger = NLTagger(tagSchemes: [.sentimentScore])

    override func analyze() -> LayerOutput? {
        let text = TextBus.shared.recent(seconds: 120)
            .map(\.text).joined(separator: ". ")
        guard text.count > 12 else { return nil }

        tagger.string = text
        // Sentiment is only produced at paragraph granularity; asking for it per
        // word or per sentence returns nothing at all, which reads as a dead layer.
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph,
                                  scheme: .sentimentScore)
        // The tag's rawValue is a numeric string, not a number.
        guard let raw = tag?.rawValue, let score = Double(raw) else { return nil }

        var out = LayerOutput()
        out.badge = String(format: "%+.2f", score)
        if score < -0.4 {
            out.lines = [String(format: "negative tone (%+.2f)", score)]
        } else if score > 0.4 {
            out.lines = [String(format: "positive tone (%+.2f)", score)]
        }
        return out
    }
}

// MARK: - Named entities

final class EntityLayer: TextDrivenLayer {
    override var id: String { "text.entities" }
    override var title: String { "Named entities" }
    override var detail: String { "Pulls people, places and organizations out of the text." }

    private let tagger = NLTagger(tagSchemes: [.nameType])
    private var reported = Set<String>()

    override func analyze() -> LayerOutput? {
        let text = TextBus.shared.recent(seconds: 180)
            .map(\.text).joined(separator: ". ")
        guard text.count > 8 else { return nil }

        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)

        var found: [String] = []
        let wanted: [NLTag] = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            guard let tag, wanted.contains(tag) else { return true }
            let value = String(text[range])
            let key = "\(tag.rawValue):\(value)"
            if !reported.contains(key) {
                reported.insert(key)
                found.append("\(value) — \(EntityLayer.pretty(tag))")
            }
            return true
        }

        if reported.count > 300 { reported.removeAll() }
        var out = LayerOutput()
        out.badge = reported.isEmpty ? nil : "\(reported.count)"
        out.lines = found
        return out.isEmpty ? nil : out
    }

    private static func pretty(_ tag: NLTag) -> String {
        switch tag {
        case .personalName:     return "person"
        case .placeName:        return "place"
        case .organizationName: return "organization"
        default:                return tag.rawValue
        }
    }
}

// MARK: - Keywords and intent

/// Keyword and intent spotting over the transcript and any text read in frame.
/// The watch list is editable in Settings; a hit raises an alert through the normal
/// path, which makes this the one language layer that does something rather than
/// just reporting.
final class KeywordLayer: TextDrivenLayer {
    override var id: String { "text.keywords" }
    override var title: String { "Keywords & intent" }
    override var detail: String { "Watches for words you choose and raises an alert on a hit." }
    override var availability: LayerAvailability {
        if Settings.shared.live.watchKeywords.trimmingCharacters(in: .whitespaces).isEmpty {
            return .needsSetup("Add words to watch for in Settings")
        }
        return TextBus.shared.isEmpty
            ? .needsSetup("Needs text — switch on Live transcription or Scene text")
            : .available
    }

    private var hitAlready = Set<String>()

    override func analyze() -> LayerOutput? {
        let words = Settings.shared.live.watchKeywords
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count > 1 }
        guard !words.isEmpty else { return nil }

        let entries = TextBus.shared.recent(seconds: 90)
        var hits: [String] = []
        for entry in entries {
            let lower = entry.text.lowercased()
            for word in words where lower.contains(word) {
                let key = "\(word)|\(entry.at.timeIntervalSince1970)"
                guard !hitAlready.contains(key) else { continue }
                hitAlready.insert(key)
                hits.append("\"\(word)\" heard in: \(entry.text)")
            }
        }
        if hitAlready.count > 400 { hitAlready.removeAll() }

        var out = LayerOutput()
        out.badge = "\(words.count) watched"
        if !hits.isEmpty {
            out.lines = hits
            out.alert = hits.first
        }
        return out
    }
}

// MARK: - Language identification

final class LanguageIDLayer: TextDrivenLayer {
    override var id: String { "text.language" }
    override var title: String { "Language detection" }
    override var detail: String { "Identifies what language is being spoken or shown." }

    override func analyze() -> LayerOutput? {
        guard let latest = TextBus.shared.latest, latest.text.count > 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(latest.text)
        guard let language = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0

        var out = LayerOutput()
        let name = Locale.current.localizedString(forIdentifier: language.rawValue)
            ?? language.rawValue
        out.badge = language.rawValue
        if confidence > 0.6 {
            out.lines = [String(format: "%@ (%.0f%%)", name, confidence * 100)]
        }
        return out
    }
}

// MARK: - Declared unavailable

enum LanguageLayerGaps {
    static func all() -> [AILayer] {
        [
        ]
    }
}

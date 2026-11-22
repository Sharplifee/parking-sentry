import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Translation)
import Translation
#endif

/// Layers backed by Apple's own on-device language model and translator.
///
/// Summarization, question answering and translation were all listed as having no
/// on-device option, which was true of NaturalLanguage and is no longer true of the
/// OS: iOS 26 added the Foundation Models framework, which is a real language model
/// running on the Neural Engine, and the Translation framework gained an
/// initializer usable without a SwiftUI view. So these three need no download, no
/// API key, and nothing leaves the device.
///
/// Everything here is gated on iOS 26 at runtime rather than by raising the app's
/// deployment target, so the app still installs on iOS 17 and these three layers
/// simply report why they are unavailable there. The model is also only present on
/// Apple-Intelligence-capable hardware, and the availability check below reports
/// the actual reason the OS gives rather than guessing.

// MARK: - On-device language model

final class OnDeviceLLM {

    static let shared = OnDeviceLLM()

    /// Held as `Any?` because `LanguageModelSession` is iOS 26+ and this class has
    /// to exist on iOS 17 for the layer catalog to build. Casting inside an
    /// availability check is the cost of not raising the whole app's floor.
    private var sessionBox: Any?
    private let lock = NSLock()
    private(set) var lastError: String?

    private init() {}

    var status: LayerAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                // The OS gives the reason; repeating it verbatim beats guessing
                // which of several things is wrong with the device.
                return .noPublicAPI("Apple's on-device model is not usable here: \(reason). It needs an Apple-Intelligence-capable device with the feature enabled.")
            @unknown default:
                return .noPublicAPI("Apple's on-device model reported an availability state this build does not know about.")
            }
        }
        #endif
        return .noPublicAPI("Needs iOS 26 or later for Apple's on-device language model. This device is on \(OSVersion.current).")
    }

    var isUsable: Bool { status.isUsable }

    /// One prompt, one answer. The session is reused so the model stays warm, and
    /// rebuilt when the context window fills — a session accumulates a transcript
    /// and will eventually refuse, which is a normal condition rather than a fault.
    func ask(instructions: String, prompt: String,
             completion: @escaping (Result<String, Error>) -> Void) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            Task.detached(priority: .utility) {
                do {
                    let session = self.session(instructions: instructions)
                    // No GenerationOptions passed: respond(to:) defaults it, and
                    // the defaults are fine for short factual answers.
                    let response = try await session.respond(to: prompt)
                    self.lastError = nil
                    completion(.success(response.content))
                } catch {
                    // A full context window is recoverable: drop the session so
                    // the next question starts clean.
                    self.lock.lock(); self.sessionBox = nil; self.lock.unlock()
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                }
            }
            return
        }
        #endif
        completion(.failure(NSError(domain: "OnDeviceLLM", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Apple's on-device model needs iOS 26 or later"])))
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func session(instructions: String) -> LanguageModelSession {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessionBox as? LanguageModelSession { return existing }
        let fresh = LanguageModelSession(instructions: instructions)
        sessionBox = fresh
        return fresh
    }
    #endif

    func reset() {
        lock.lock(); sessionBox = nil; lock.unlock()
    }
}

/// Small helper so the unavailable message can name the actual OS version instead
/// of saying "this device is too old" with no detail.
enum OSVersion {
    static var current: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}

// MARK: - Summarization

/// Condenses everything the layers have heard and read into a few lines.
///
/// This is the layer that makes a long unattended session reviewable: instead of
/// four hundred transcript fragments and OCR hits, one paragraph saying what
/// happened. It runs on a timer rather than per frame, because a summary of the
/// last thirty seconds is not worth the tokens.
final class SummarizationLayer: VideoAILayer {
    let id = "text.summary"
    let title = "Summarization"
    let detail = "Condenses the transcript and everything read on screen into a few lines. On-device."
    let group = LayerGroup.language
    let modality = LayerModality.text
    var availability: LayerAvailability {
        let llm = OnDeviceLLM.shared.status
        guard llm.isUsable else { return llm }
        return TextBus.shared.isEmpty
            ? .needsSetup("Needs text — switch on Live transcription or Scene text")
            : .available
    }
    let preferredInterval = 30
    let warmAtLaunch = false

    private var lastRun = Date.distantPast
    private let handoff = LayerHandoff<(text: String, failed: Bool)>()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var out = LayerOutput()
        if let ready = handoff.take() {
            out.lines = [ready.text]
            out.badge = ready.failed ? "error" : "summary"
            return out
        }

        // Every two minutes, and only when there is genuinely new material.
        guard Date().timeIntervalSince(lastRun) > 120 else { return nil }
        let entries = TextBus.shared.recent(seconds: 900)
        guard entries.count >= 4 else { return nil }
        guard handoff.begin() else { return nil }
        lastRun = Date()

        let material = entries.suffix(80)
            .map { "[\($0.source)] \($0.text)" }
            .joined(separator: "\n")

        OnDeviceLLM.shared.ask(
            instructions: "You summarize security camera logs. Be factual and brief. Report only what the log states; never speculate about intent or identity. If the log is trivial, say so in one line.",
            prompt: "Summarize what happened, in at most three sentences:\n\n\(material)") { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    self.handoff.finish((text, false))
                    TextBus.shared.add("summary: " + text, source: "summary")
                case .failure(let error):
                    self.handoff.finish((error.localizedDescription, true))
                }
            }
        return nil
    }
}

// MARK: - Question answering

/// Ask a question about what the camera has seen and heard.
///
/// The question comes from Settings and is answered against the text the other
/// layers have produced — transcript, scene text, plate reads, scene labels. It is
/// deliberately grounded in that material rather than in the model's own
/// knowledge, and the instructions tell it to say when the log does not contain
/// the answer, because a confident invented answer about a security log is worse
/// than no answer.
final class QuestionAnsweringLayer: VideoAILayer {
    let id = "text.qa"
    let title = "Question answering"
    let detail = "Answers a question you set, from what the camera has actually seen and heard."
    let group = LayerGroup.language
    let modality = LayerModality.text
    var availability: LayerAvailability {
        let llm = OnDeviceLLM.shared.status
        guard llm.isUsable else { return llm }
        if Settings.shared.live.llmQuestion.trimmingCharacters(in: .whitespaces).isEmpty {
            return .needsSetup("Type a question in Settings")
        }
        return TextBus.shared.isEmpty
            ? .needsSetup("Needs text — switch on Live transcription or Scene text")
            : .available
    }
    let preferredInterval = 30
    let warmAtLaunch = false

    private var askedFor = ""
    private let handoff = LayerHandoff<(text: String, failed: Bool)>()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var out = LayerOutput()
        if let ready = handoff.take() {
            out.lines = [ready.text]
            out.badge = ready.failed ? "error" : "answered"
            return out
        }

        let question = Settings.shared.live.llmQuestion.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return nil }
        let entries = TextBus.shared.recent(seconds: 1800)
        guard !entries.isEmpty else { return nil }

        // Re-ask only when the question changes or substantially new material has
        // arrived, rather than every thirty frames.
        let fingerprint = "\(question)|\(entries.count)"
        guard fingerprint != askedFor else { return nil }
        guard handoff.begin() else { return nil }
        askedFor = fingerprint

        let material = entries.suffix(80)
            .map { "[\($0.source)] \($0.text)" }
            .joined(separator: "\n")

        OnDeviceLLM.shared.ask(
            instructions: "You answer questions about a security camera's log. Use only the log provided. If the log does not contain the answer, say exactly that — never guess, and never infer intent or identity. Answer in one or two sentences.",
            prompt: "Log:\n\(material)\n\nQuestion: \(question)") { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text): self.handoff.finish(("Q: \(question)\nA: \(text)", false))
                case .failure(let error): self.handoff.finish((error.localizedDescription, true))
                }
            }
        return nil
    }
}

// MARK: - Translation

/// On-device translation of the transcript.
///
/// The Translation framework will only hand a headless session the language pairs
/// already downloaded, and a background pipeline cannot ask permission to download
/// more — that consent has to come from a SwiftUI view. So this layer checks the
/// pair's status, works when it is installed, and when it is not, says precisely
/// that and points at the button in Settings that does the one-time download.
final class OnDeviceTranslationLayer: VideoAILayer {
    let id = "text.translate"
    let title = "Translation"
    let detail = "Translates the transcript on-device, into the language set in Settings."
    let group = LayerGroup.language
    let modality = LayerModality.text
    var availability: LayerAvailability {
        if #available(iOS 26.0, *) {
            guard !Settings.shared.live.translationTarget.isEmpty else {
                return .needsSetup("Pick a language in Settings")
            }
            switch TranslationBridge.shared.lastStatus {
            case .installed:
                return TextBus.shared.isEmpty
                    ? .needsSetup("Needs text — switch on Live transcription")
                    : .available
            case .supported:
                return .needsDownload("Apple supports this pair but has not downloaded it. Install it in iOS Settings › General › Language & Region › Translation Languages, then switch this on. A background layer cannot request that download itself.")
            case .unsupported:
                return .noPublicAPI("Apple's translator does not support this pair")
            case .unknown:
                return .needsSetup("Checking language availability…")
            }
        }
        return .noPublicAPI("Needs iOS 26 or later: before that, the Translation framework only hands out a session through a SwiftUI view, which a background layer cannot reach. This device is on \(OSVersion.current).")
    }
    let preferredInterval = 30
    let warmAtLaunch = false

    private var lastTranslated = ""
    private let handoff = LayerHandoff<(text: String, failed: Bool)>()

    func warm() {
        TranslationBridge.shared.refreshStatus()
    }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var out = LayerOutput()
        if let ready = handoff.take() {
            out.lines = [ready.text]
            out.badge = ready.failed ? "error" : "translated"
            return out
        }

        guard let latest = TextBus.shared.latest,
              latest.source != "translation", latest.text != lastTranslated,
              latest.text.count > 4 else { return nil }
        guard handoff.begin() else { return nil }
        lastTranslated = latest.text

        TranslationBridge.shared.translate(latest.text) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.handoff.finish((text, false))
                TextBus.shared.add(text, source: "translation")
            case .failure(let error):
                self.handoff.finish(("translation failed: \(error.localizedDescription)", true))
            }
        }
        return nil
    }
}

/// Wraps the Translation framework so the rest of the app never has to deal with
/// its availability gymnastics.
final class TranslationBridge {

    static let shared = TranslationBridge()

    enum Status { case installed, supported, unsupported, unknown }

    private(set) var lastStatus: Status = .unknown
    private var sessionBox: Any?
    private var sessionTarget = ""

    private init() {}

    private var targetLanguage: String { Settings.shared.live.translationTarget }

    func refreshStatus() {
        guard #available(iOS 18.0, *) else { lastStatus = .unsupported; return }
        // LanguageAvailability is iOS 18, but only iOS 26 can open a headless
        // session, so anything older is reported as unusable by the layer itself.
        let target = targetLanguage
        guard !target.isEmpty else { lastStatus = .unknown; return }

        Task.detached(priority: .utility) {
            let availability = LanguageAvailability()
            let source = Locale.Language(identifier: "en")
            let dest = Locale.Language(identifier: target)
            let status = await availability.status(from: source, to: dest)
            switch status {
            case .installed:   self.lastStatus = .installed
            case .supported:   self.lastStatus = .supported
            case .unsupported: self.lastStatus = .unsupported
            @unknown default:  self.lastStatus = .unknown
            }
            EventLog.action("translation.status", ["target": target,
                                                   "status": String(describing: status)])
        }
    }

    func translate(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard #available(iOS 26.0, *) else {
            completion(.failure(NSError(domain: "Translation", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Needs iOS 26 or later for a headless translation session"])))
            return
        }
        let target = targetLanguage
        guard !target.isEmpty else {
            completion(.failure(NSError(domain: "Translation", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "No target language set"])))
            return
        }

        Task.detached(priority: .utility) {
            do {
                // This initializer does not throw; it fails later, at translate
                // time, when the pair is not actually installed.
                let session: TranslationSession
                if let existing = self.sessionBox as? TranslationSession,
                   self.sessionTarget == target {
                    session = existing
                } else {
                    session = TranslationSession(
                        installedSource: Locale.Language(identifier: "en"),
                        target: Locale.Language(identifier: target))
                    self.sessionBox = session
                    self.sessionTarget = target
                }
                let response = try await session.translate(text)
                completion(.success(response.targetText))
            } catch {
                // Almost always the pair not being installed, so the status is
                // refreshed to make the panel say so.
                self.sessionBox = nil
                self.refreshStatus()
                completion(.failure(error))
            }
        }
    }
}

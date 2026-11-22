import Foundation

/// CLIP's byte-pair-encoding tokenizer, in Swift.
///
/// MobileCLIP's text tower takes 77 token IDs, not a string, so searching by words
/// needs the same tokenizer OpenAI trained with. An approximation does not work
/// here: feed it tokens from a different scheme and it returns a confident
/// embedding for something nobody asked about, which looks like a broken model
/// rather than a broken tokenizer.
///
/// The 49,408-entry vocabulary is not bundled. It is derivable, exactly, from the
/// merge list: 256 byte-level characters, then those same 256 with a word-ending
/// marker, then every merge joined in order, then the two special tokens. That was
/// checked against the real vocab.json entry by entry before relying on it, and it
/// halves what ships in the app to a single 525 KB file.
final class CLIPTokenizer {

    static let shared = CLIPTokenizer()

    private var ranks: [String: Int] = [:]
    private var ids: [String: Int32] = [:]
    private var byteEncoder: [UInt8: String] = [:]
    private(set) var ready = false

    /// CLIP's own pre-tokenizer pattern: contractions, then runs of letters, then
    /// single digits, then runs of anything else.
    private let pattern = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
    private var regex: NSRegularExpression?

    static let contextLength = 77
    static let startToken: Int32 = 49406
    static let endToken: Int32 = 49407

    private init() {}

    func load() {
        guard !ready else { return }
        guard let url = Bundle.main.url(forResource: "clip_merges", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            EventLog.action("clip.tokenizer.missing", [:])
            return
        }

        byteEncoder = CLIPTokenizer.bytesToUnicode()
        let base = CLIPTokenizer.orderedByteChars(byteEncoder)

        var merges: [String] = []
        merges.reserveCapacity(49_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // The first line is a version comment in the upstream file.
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            let joined = String(parts[0]) + String(parts[1])
            ranks[String(parts[0]) + "\u{1}" + String(parts[1])] = merges.count
            merges.append(joined)
        }

        // Vocabulary order, exactly as CLIP builds it.
        var vocab: [String] = []
        vocab.reserveCapacity(49_408)
        vocab.append(contentsOf: base)
        vocab.append(contentsOf: base.map { $0 + "</w>" })
        vocab.append(contentsOf: merges)
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")

        ids.reserveCapacity(vocab.count)
        for (i, token) in vocab.enumerated() { ids[token] = Int32(i) }

        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        ready = ids.count == 49_408 && regex != nil
        EventLog.action("clip.tokenizer.loaded", ["vocab": ids.count, "merges": merges.count])
    }

    /// Token IDs padded to 77, which is the shape the text tower demands.
    func encode(_ text: String) -> [Int32]? {
        if !ready { load() }
        guard ready, let regex else { return nil }

        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var tokens: [Int32] = [CLIPTokenizer.startToken]
        let ns = cleaned as NSString
        let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))

        for match in matches {
            let word = ns.substring(with: match.range)
            // Byte-level: every UTF-8 byte maps to a printable character, so any
            // input is representable and nothing is ever out of vocabulary.
            var encoded = ""
            for byte in Array(word.utf8) { encoded += byteEncoder[byte] ?? "" }
            guard !encoded.isEmpty else { continue }
            for piece in bpe(encoded) {
                guard let id = ids[piece] else { continue }
                tokens.append(id)
                if tokens.count >= CLIPTokenizer.contextLength - 1 { break }
            }
            if tokens.count >= CLIPTokenizer.contextLength - 1 { break }
        }

        tokens.append(CLIPTokenizer.endToken)
        // Pad with zeros to the fixed context length.
        if tokens.count < CLIPTokenizer.contextLength {
            tokens.append(contentsOf: [Int32](repeating: 0,
                                              count: CLIPTokenizer.contextLength - tokens.count))
        }
        return Array(tokens.prefix(CLIPTokenizer.contextLength))
    }

    /// Merge the lowest-ranked adjacent pair until none is left to merge.
    private func bpe(_ token: String) -> [String] {
        var word = token.map(String.init)
        guard !word.isEmpty else { return [] }
        // The final character carries the end-of-word marker.
        word[word.count - 1] += "</w>"
        guard word.count > 1 else { return word }

        while true {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(word.count - 1) {
                guard let rank = ranks[word[i] + "\u{1}" + word[i + 1]] else { continue }
                if rank < bestRank { bestRank = rank; bestIndex = i }
            }
            guard bestIndex >= 0 else { break }
            word[bestIndex] = word[bestIndex] + word[bestIndex + 1]
            word.remove(at: bestIndex + 1)
            if word.count == 1 { break }
        }
        return word
    }

    /// GPT-2's byte-to-printable-character map, which CLIP reuses.
    static func bytesToUnicode() -> [UInt8: String] {
        var bs: [Int] = []
        bs.append(contentsOf: Int(UInt8(ascii: "!"))...Int(UInt8(ascii: "~")))
        bs.append(contentsOf: 0xA1...0xAC)
        bs.append(contentsOf: 0xAE...0xFF)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var map: [UInt8: String] = [:]
        for (b, c) in zip(bs, cs) {
            guard let scalar = Unicode.Scalar(UInt32(c)) else { continue }
            map[UInt8(b)] = String(Character(scalar))
        }
        return map
    }

    /// The 256 base characters in the order CLIP's vocabulary expects, which is
    /// the byte order, not the character order.
    static func orderedByteChars(_ map: [UInt8: String]) -> [String] {
        var bs: [Int] = []
        bs.append(contentsOf: Int(UInt8(ascii: "!"))...Int(UInt8(ascii: "~")))
        bs.append(contentsOf: 0xA1...0xAC)
        bs.append(contentsOf: 0xAE...0xFF)
        for b in 0..<256 where !bs.contains(b) { bs.append(b) }
        return bs.compactMap { map[UInt8($0)] }
    }
}

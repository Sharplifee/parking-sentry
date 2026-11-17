import Foundation
import CoreImage
import CoreGraphics
import UIKit
import Security

/// Multimodal layers.
///
/// Three of the six fuse what the camera sees with what the microphone hears
/// entirely on-device, and they are the more useful three: a car horn means more
/// when there is a vehicle in frame, and a sound with no visible cause is exactly
/// what a sentry should raise. Those need no model and no network.
///
/// The two that genuinely need a vision-language model call out, and only after a
/// key is pasted in Settings. No key ships in the app, nothing is sent anywhere
/// until one is added and the layer is switched on, and the interval is slow by
/// default because every call costs money.

// MARK: - Key storage

/// The API key goes in the Keychain, not UserDefaults. A key in a plist backs up to
/// iCloud in the clear and is readable from a file dump of the container.
enum KeyStore {
    private static let service = "com.connor.parkingsentry.keys"

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var hasModelKey: Bool { (get("anthropic") ?? "").count > 10 }
}

// MARK: - Audio-visual fusion (local)

/// Pairs sound events with what is visible. The point is not the pairing itself but
/// the disagreement: a horn with a car in frame is ordinary, a horn with nothing in
/// frame means something is happening outside the camera's view, and that is worth
/// knowing about.
final class AudioVisualFusionLayer: DerivedAILayer {
    let id = "fusion.av"
    let title = "Audio-visual fusion"
    let detail = "Confirms events across both senses, and flags sounds with no visible cause."
    let group = LayerGroup.multimodal
    let modality = LayerModality.derived
    var availability: LayerAvailability {
        LayerRegistry.shared.isActive("sound.events")
            ? .available
            : .needsSetup("Switch on Sound events too — this layer reads from it")
    }

    /// Which sound classes imply something that should also be visible.
    private static let visualCause: [String: SubjectCategory] = [
        "car_horn": .vehicle, "vehicle_horn_car_horn_honking": .vehicle,
        "car_alarm": .vehicle, "engine": .vehicle, "car_passing_by": .vehicle,
        "dog_bark": .animal, "dog": .animal, "cat": .animal, "meow": .animal,
        "speech": .person, "shout": .person, "yell": .person, "footsteps": .person,
        "laughter": .person, "babble": .person
    ]

    private var lastFlag = Date.distantPast

    func process(_ ctx: FrameContext) -> LayerOutput? {
        let hits = SoundHub.shared.snapshot.filter {
            Date().timeIntervalSince($0.at) < 3 && $0.confidence > 0.45
        }
        guard !hits.isEmpty else { return nil }

        let visible = Set(ctx.tracks.filter { $0.misses <= 4 }.map(\.category))
        var out = LayerOutput()
        var confirmed: [String] = []
        var unexplained: [String] = []

        for hit in hits {
            guard let expected = AudioVisualFusionLayer.visualCause[hit.identifier] else { continue }
            let pretty = hit.identifier.replacingOccurrences(of: "_", with: " ")
            if visible.contains(expected) {
                confirmed.append("\(pretty) + \(expected.rawValue) in frame")
            } else {
                unexplained.append("\(pretty) heard, nothing visible")
            }
        }

        out.badge = confirmed.isEmpty ? (unexplained.isEmpty ? nil : "off-camera")
                                      : "confirmed"
        out.lines = confirmed + unexplained
        if !unexplained.isEmpty, Date().timeIntervalSince(lastFlag) > 45 {
            lastFlag = Date()
            out.alert = unexplained.first
        }
        return out.isEmpty ? nil : out
    }
}

/// One line describing the moment from both senses at once, which is what somebody
/// scanning a log actually wants to read.
final class LiveCaptionLayer: DerivedAILayer {
    let id = "fusion.caption"
    let title = "Live captioning"
    let detail = "A single line per moment combining what is seen and what is heard."
    let group = LayerGroup.multimodal
    let modality = LayerModality.derived
    let availability = LayerAvailability.available

    private var last = ""
    private var lastAt = Date.distantPast

    func process(_ ctx: FrameContext) -> LayerOutput? {
        guard Date().timeIntervalSince(lastAt) > 4 else { return nil }

        var seen: [String] = []
        var counts: [SubjectCategory: Int] = [:]
        for t in ctx.tracks where t.misses == 0 { counts[t.category, default: 0] += 1 }
        for (category, n) in counts.sorted(by: { $0.value > $1.value }) {
            seen.append(n == 1 ? "one \(category.rawValue)" : "\(n) \(category.rawValue)s")
        }

        let heard = SoundHub.shared.snapshot
            .filter { Date().timeIntervalSince($0.at) < 5 && $0.confidence > 0.5 }
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let uniqueHeard = Array(Set(heard)).sorted().prefix(2)

        var parts: [String] = []
        if !seen.isEmpty { parts.append("seeing " + seen.joined(separator: ", ")) }
        if !uniqueHeard.isEmpty { parts.append("hearing " + uniqueHeard.joined(separator: ", ")) }
        guard !parts.isEmpty else { return nil }

        let caption = parts.joined(separator: "; ")
        guard caption != last else { return nil }
        last = caption
        lastAt = Date()

        var out = LayerOutput()
        out.lines = [caption]
        out.badge = "live"
        return out
    }
}

/// Novelty across both senses at once. A frame that looks unusual is often just the
/// light changing; a frame that looks unusual while something unusual is also
/// audible is a much stronger signal, and requiring both is what keeps this from
/// firing every time a cloud passes.
final class AudioVisualAnomalyLayer: DerivedAILayer {
    let id = "fusion.anomaly"
    let title = "Audio-visual anomaly"
    let detail = "Raises only when sight and sound are both unusual at once."
    let group = LayerGroup.multimodal
    let modality = LayerModality.derived
    var availability: LayerAvailability {
        LayerRegistry.shared.isActive("anomaly") && LayerRegistry.shared.isActive("sound.events")
            ? .available
            : .needsSetup("Switch on Scene anomaly and Sound events too — this layer reads both")
    }

    private var soundHistory: [String: Int] = [:]
    private var frames = 0
    private var lastFlag = Date.distantPast

    func process(_ ctx: FrameContext) -> LayerOutput? {
        frames += 1
        let hits = SoundHub.shared.snapshot.filter { $0.confidence > 0.45 }
        for h in hits { soundHistory[h.identifier, default: 0] += 1 }

        // A sound is novel if it has barely been heard in this session.
        let recent = hits.filter { Date().timeIntervalSince($0.at) < 4 }
        let novelSound = recent.first { (soundHistory[$0.identifier] ?? 0) < 4 }

        // The visual half comes from the scene-anomaly layer's own badge, which is
        // its z-score — reading it here rather than recomputing a feature print.
        let visualBadge = LayerRegistry.shared.outputs["anomaly"]?.badge ?? ""
        let z = Double(visualBadge.replacingOccurrences(of: "σ", with: "")) ?? 0

        var out = LayerOutput()
        out.badge = String(format: "%.1fσ", z)
        guard frames > 120, let novel = novelSound, z > 2.0,
              Date().timeIntervalSince(lastFlag) > 90 else { return out }

        lastFlag = Date()
        let pretty = novel.identifier.replacingOccurrences(of: "_", with: " ")
        out.lines = [String(format: "unusual on both: %@ while the scene is %.1fσ from normal", pretty, z)]
        out.alert = "Unusual sight and sound together"
        return out
    }
}

// MARK: - Vision-language (needs a key)

/// Scene description from a vision-language model. There is no on-device VLM in any
/// public Apple API, so this is the one place the app leaves the device — and only
/// after a key is pasted in Settings.
final class SceneDescriptionLayer: VideoAILayer {
    let id = "vlm.describe"
    let title = "Scene description"
    let detail = "A written description of the view from a vision model. Sends a still image when it runs."
    let group = LayerGroup.multimodal
    let modality = LayerModality.video
    var availability: LayerAvailability {
        KeyStore.hasModelKey
            ? .needsNetwork("Sends a still image to Anthropic's API each time it runs")
            : .needsSetup("Paste an Anthropic API key in Settings first")
    }
    /// The frame interval is irrelevant here — the call interval is a wall clock in
    /// Settings, because a model call every few frames would be absurd.
    let preferredInterval = 30
    let warmAtLaunch = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastCall = Date.distantPast
    private var inFlight = false
    private var latest: String?
    private var failure: String?

    func cool() { latest = nil; failure = nil }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var out = LayerOutput()
        if let failure { out.lines = [failure]; out.badge = "error"; self.failure = nil; return out }
        if let latest { out.lines = [latest]; out.badge = "described"; self.latest = nil; return out }

        let interval = max(10, Settings.shared.modelCallInterval)
        guard !inFlight, Date().timeIntervalSince(lastCall) > interval else { return nil }
        guard let key = KeyStore.get("anthropic"), let jpeg = jpegData(from: ctx.pixelBuffer)
        else { return nil }

        lastCall = Date()
        inFlight = true
        ModelClient.describe(image: jpeg, key: key,
                             prompt: "Describe this security camera view in two sentences. Note anything a person watching for trouble would want flagged. Be specific and factual; do not speculate about intent.") { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let text):
                self.latest = text
                TextBus.shared.add(text, source: "vision model")
            case .failure(let error):
                self.failure = error.localizedDescription
            }
        }
        return nil
    }

    private func jpegData(from buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        // 896 on the long edge is plenty for a description and keeps the upload small.
        let scale = min(1, 896 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
    }
}

/// Open-vocabulary search: look for whatever is typed in Settings, in plain words,
/// with no class list. Asks the model which ninth of the frame the thing is in,
/// because a model asked for precise pixel boxes will invent them.
final class GroundingLayer: VideoAILayer {
    let id = "vlm.grounding"
    let title = "Find anything"
    let detail = "Looks for whatever you describe in words — \"a red bag\", \"an open gate\"."
    let group = LayerGroup.multimodal
    let modality = LayerModality.video
    var availability: LayerAvailability {
        guard KeyStore.hasModelKey else { return .needsSetup("Paste an Anthropic API key in Settings first") }
        return Settings.shared.groundingQuery.trimmingCharacters(in: .whitespaces).isEmpty
            ? .needsSetup("Type what to look for in Settings")
            : .needsNetwork("Sends a still image to Anthropic's API each time it runs")
    }
    let preferredInterval = 30
    let warmAtLaunch = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastCall = Date.distantPast
    private var inFlight = false
    private var answer: (found: Bool, cell: Int, note: String)?

    func cool() { answer = nil }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var out = LayerOutput()
        if let answer {
            self.answer = nil
            out.badge = answer.found ? "found" : "not found"
            out.lines = [answer.note]
            if answer.found, answer.cell >= 0, answer.cell < 9 {
                // Ninths, numbered left to right then top to bottom.
                let col = answer.cell % 3, row = answer.cell / 3
                let rect = CGRect(x: CGFloat(col) / 3.0,
                                  y: CGFloat(2 - row) / 3.0,
                                  width: 1.0 / 3.0, height: 1.0 / 3.0)
                out.shapes = [.box(rect, label: Settings.shared.groundingQuery, tint: .alert)]
            }
            return out
        }

        let query = Settings.shared.groundingQuery.trimmingCharacters(in: .whitespaces)
        let interval = max(10, Settings.shared.modelCallInterval)
        guard !query.isEmpty, !inFlight, Date().timeIntervalSince(lastCall) > interval,
              let key = KeyStore.get("anthropic"),
              let jpeg = jpeg(from: ctx.pixelBuffer) else { return nil }

        lastCall = Date()
        inFlight = true
        let prompt = """
        Is there \(query) visible in this image? Answer with exactly one line in this format and nothing else:
        FOUND|<cell 0-8, numbered left to right then top to bottom in a 3x3 grid>|<short reason>
        or
        ABSENT|-1|<short reason>
        """
        ModelClient.describe(image: jpeg, key: key, prompt: prompt) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let text):
                let parts = text.split(separator: "|", maxSplits: 2).map(String.init)
                let found = parts.first?.uppercased().contains("FOUND") ?? false
                let cell = parts.count > 1 ? (Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? -1) : -1
                let note = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : text
                self.answer = (found, cell, note)
            case .failure(let error):
                self.answer = (false, -1, error.localizedDescription)
            }
        }
        return nil
    }

    private func jpeg(from buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 896 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
    }
}

// MARK: - Model client

enum ModelClient {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func describe(image: Data, key: String, prompt: String,
                         completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(.failure(Failure(message: "bad url"))); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-haiku-5-5",
            "max_tokens": 300,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg",
                                "data": image.base64EncodedString()]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(Failure(message: "could not encode request"))); return
        }
        request.httpBody = data

        let job = EventLog.job("vlm.call")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                job.fail(error)
                completion(.failure(error)); return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                job.fail(Failure(message: "empty response"))
                completion(.failure(Failure(message: "empty response"))); return
            }
            guard code == 200 else {
                // Surface the API's own message; "400" alone tells nobody anything.
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
                    ?? String(data: data, encoding: .utf8)?.prefix(160).description
                    ?? "no detail"
                let f = Failure(message: "HTTP \(code): \(detail)")
                job.fail(f)
                completion(.failure(f)); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let text = content.compactMap({ $0["text"] as? String }).first else {
                let f = Failure(message: "unexpected response shape")
                job.fail(f)
                completion(.failure(f)); return
            }
            job.end(["chars": text.count])
            completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }
}

// MARK: - Declared unavailable

enum MultimodalGaps {
    static func all() -> [AILayer] {
        [
            UnavailableLayer(
                id: "fusion.retrieval", title: "Cross-modal retrieval",
                detail: "Searching saved clips by description — \"find the clip with the white van\".",
                group: .multimodal,
                availability: .noPublicAPI("Needs an embedding index over every saved clip, built as clips are written. The pieces are here — feature prints and the clip library — but nothing indexes them yet."))
        ]
    }
}

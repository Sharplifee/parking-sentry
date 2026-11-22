import Foundation
import CoreML
import CoreVideo
import CoreImage
import CoreGraphics

/// MobileCLIP: images and words in one shared space.
///
/// This is what makes open-vocabulary search possible without a network. CLIP puts
/// a picture and a phrase into the same 512-dimensional space, so "a white van" can
/// be compared directly against what the camera is looking at, with no class list
/// and no cloud call. Two capabilities come out of it: finding something described
/// in words, and searching back through what the camera has already seen.
final class CLIPEngine {

    static let shared = CLIPEngine()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var scaler: PixelScaler?
    /// Query embeddings are cached: the text tower is the expensive half and the
    /// query changes far less often than the frame.
    private var textCache: [String: [Float]] = [:]
    private let lock = NSLock()

    private init() {}

    var imageReady: Bool { ModelStore.shared.isReady("clip.image") }
    var textReady: Bool { ModelStore.shared.isReady("clip.text") }

    func prepare() {
        CLIPTokenizer.shared.load()
        if scaler == nil {
            // The image tower takes 256x256 RGB.
            scaler = PixelScaler(width: 256, height: 256, format: kCVPixelFormatType_32BGRA)
        }
    }

    func release() {
        scaler = nil
        lock.lock(); textCache.removeAll(); lock.unlock()
    }

    /// 512-d unit vector for a frame, or for a crop of one.
    func embed(image buffer: CVPixelBuffer) -> [Float]? {
        guard let model = ModelStore.shared.model("clip.image") else { return nil }
        if scaler == nil { prepare() }
        guard let scaler, let input = scaler.scaled(buffer) else { return nil }
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
            let out = try model.prediction(from: provider)
            guard let array = out.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
            return CLIPEngine.normalize(array)
        } catch {
            EventLog.error(error, name: "clip.image.failed")
            return nil
        }
    }

    func embed(crop region: CGRect, of buffer: CVPixelBuffer) -> [Float]? {
        let image = CIImage(cvPixelBuffer: buffer)
        let e = image.extent
        // Pad a little: CLIP reads context, and a box cropped tight to a person
        // loses what they are standing next to.
        let padded = region.insetBy(dx: -region.width * 0.12, dy: -region.height * 0.12)
        let rect = CGRect(x: padded.minX * e.width, y: padded.minY * e.height,
                          width: padded.width * e.width, height: padded.height * e.height)
            .intersection(e)
        guard rect.width > 24, rect.height > 24 else { return nil }
        guard let cg = ciContext.createCGImage(image, from: rect) else { return nil }

        // Round-trip through a pixel buffer because the model's input is an image
        // feature, which Core ML wants as a CVPixelBuffer at the exact size.
        guard let out = CLIPEngine.pixelBuffer(from: cg, width: 256, height: 256) else { return nil }
        guard let model = ModelStore.shared.model("clip.image") else { return nil }
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: out)])
            let prediction = try model.prediction(from: provider)
            guard let array = prediction.featureValue(for: "final_emb_1")?.multiArrayValue
            else { return nil }
            return CLIPEngine.normalize(array)
        } catch {
            return nil
        }
    }

    /// 512-d unit vector for a phrase. Cached, since this is the slow tower.
    func embed(text: String) -> [Float]? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        lock.lock()
        if let hit = textCache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let model = ModelStore.shared.model("clip.text"),
              let tokens = CLIPTokenizer.shared.encode(key) else { return nil }
        do {
            let array = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)],
                                         dataType: .int32)
            for (i, t) in tokens.enumerated() {
                array[i] = NSNumber(value: t)
            }
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["text": MLFeatureValue(multiArray: array)])
            let out = try model.prediction(from: provider)
            guard let result = out.featureValue(for: "final_emb_1")?.multiArrayValue,
                  let vector = CLIPEngine.normalize(result) else { return nil }
            lock.lock()
            textCache[key] = vector
            if textCache.count > 64 { textCache.removeAll() }
            lock.unlock()
            return vector
        } catch {
            EventLog.error(error, name: "clip.text.failed")
            return nil
        }
    }

    /// Both vectors are unit length, so the dot product IS the cosine similarity.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var total: Float = 0
        for i in a.indices { total += a[i] * b[i] }
        return total
    }

    private static func normalize(_ array: MLMultiArray) -> [Float]? {
        let count = array.count
        guard count > 0 else { return nil }
        var vector = [Float](repeating: 0, count: count)
        // The fast path reinterprets the backing store as Float32, which is only
        // valid if that is what it holds. A model converted at float16 precision
        // can declare a float16 output, and reading those bytes as Float32 does
        // not fail — it returns plausible-looking nonsense, which here means a
        // confident embedding for something nobody asked about. So the dtype is
        // checked, with a slower but always-correct path behind it.
        if array.dataType == .float32 {
            array.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                for i in 0..<count { vector[i] = base[i] }
            }
        } else {
            for i in 0..<count { vector[i] = array[i].floatValue }
        }
        var norm: Float = 0
        for v in vector { norm += v * v }
        norm = max(1e-6, norm.squareRoot())
        for i in vector.indices { vector[i] /= norm }
        return vector
    }

    static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

// MARK: - Open-vocabulary search, on device

/// "Find a red bag." No class list, no cloud call.
///
/// Each thing the detector found is embedded and scored against the phrase, so the
/// answer comes with a box around the actual object rather than a guess at which
/// ninth of the frame it is in — which is what the cloud version had to settle for,
/// because a language model asked for pixel coordinates invents them.
///
/// The threshold is the honest part. CLIP always returns a best match, so without a
/// floor this layer would confidently point at something for any phrase at all. The
/// score is shown next to the verdict so the operator can see how sure it is.
final class OpenVocabularyLayer: ModelBackedLayer, VideoAILayer {
    let id = "clip.find"
    let title = "Find anything (on-device)"
    let detail = "Looks for whatever you describe in words. No class list, nothing leaves the device."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    var availability: LayerAvailability {
        guard Settings.shared.live.groundingQuery.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            return .needsSetup("Type what to look for in Settings")
        }
        // Both towers are needed: one for the phrase, one for the picture.
        let image = ModelStore.shared.state("clip.image")
        let text = ModelStore.shared.state("clip.text")
        if case .ready = image, case .ready = text {
            return CLIPTokenizer.shared.ready
                ? .available
                : .modelMissing("The CLIP vocabulary did not load from the app bundle")
        }
        let mb = ((ModelStore.manifest["clip.image"]?.totalBytes ?? 0)
                  + (ModelStore.manifest["clip.text"]?.totalBytes ?? 0)) / 1_000_000
        if case .downloading(let f) = image {
            return .needsDownload(String(format: "Downloading image model… %.0f%%", f * 100))
        }
        if case .downloading(let f) = text {
            return .needsDownload(String(format: "Downloading text model… %.0f%%", f * 100))
        }
        if case .compiling = image { return .needsDownload("Compiling on device…") }
        if case .compiling = text { return .needsDownload("Compiling on device…") }
        if case .failed(let why) = image { return .modelMissing("Download failed: \(why)") }
        if case .failed(let why) = text { return .modelMissing("Download failed: \(why)") }
        return .needsDownload("Needs \(mb) MB of models — switch on to download once")
    }
    let preferredInterval = 12
    let warmAtLaunch = false

    /// Below this, CLIP is matching noise. Chosen to under-report rather than
    /// point confidently at the wrong thing.
    private let floor: Float = 0.22

    init() { super.init(modelID: "clip.image") }

    override func ensureModel() {
        for id in ["clip.image", "clip.text"] {
            if case .ready = ModelStore.shared.state(id) { continue }
            ModelStore.shared.fetch(id)
        }
    }

    func warm() {
        ensureModel()
        CLIPEngine.shared.prepare()
    }

    func cool() { CLIPEngine.shared.release() }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        let query = Settings.shared.live.groundingQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        guard CLIPEngine.shared.imageReady, CLIPEngine.shared.textReady else {
            ensureModel()
            return nil
        }
        guard let target = CLIPEngine.shared.embed(text: query) else { return nil }

        var out = LayerOutput()
        var best: (CGRect?, Float) = (nil, -1)

        // Score each detected object, which is both cheaper and more precise than
        // sliding a window over the frame.
        for subject in ctx.subjects {
            guard let vector = CLIPEngine.shared.embed(crop: subject.boundingBox,
                                                       of: ctx.pixelBuffer) else { continue }
            let score = CLIPEngine.similarity(target, vector)
            if score > best.1 { best = (subject.boundingBox, score) }
        }

        // Nothing detected, or nothing scored: fall back to the whole frame, which
        // answers presence without location.
        if best.1 < 0, let whole = CLIPEngine.shared.embed(image: ctx.pixelBuffer) {
            best = (nil, CLIPEngine.similarity(target, whole))
        }
        guard best.1 > -1 else { return nil }

        out.badge = best.1 >= floor ? String(format: "found %.2f", best.1)
                                    : String(format: "%.2f", best.1)
        if best.1 >= floor {
            if let box = best.0 {
                out.shapes = [.box(box, label: String(format: "%@ %.2f", query, best.1),
                                   tint: .alert)]
            }
            // Announced on the transition into "found" and then at most every
            // twenty seconds, rather than on every run. At interval 12 this layer
            // runs two or three times a second, so an unfiltered line meant the
            // output feed filled with the same sentence and nothing else in it was
            // readable.
            let now = Date()
            if !wasFound || now.timeIntervalSince(lastAnnounced) > 20 {
                lastAnnounced = now
                out.lines = best.0 != nil
                    ? [String(format: "\"%@\" found, score %.2f", query, best.1)]
                    : [String(format: "\"%@\" may be in frame, score %.2f (no box — nothing was detected to attach it to)", query, best.1)]
            }
            wasFound = true
        } else {
            wasFound = false
        }
        return out
    }

    private var wasFound = false
    private var lastAnnounced = Date.distantPast
}

// MARK: - Cross-modal retrieval

/// Search back through what the camera has already seen, by description.
///
/// While active it embeds a frame every few seconds and keeps the vector with its
/// timestamp, persisted so the index survives a relaunch. A phrase typed in
/// Settings then ranks those moments, and the timestamps line up with the clip
/// library — which is what turns "find the clip with the white van" into something
/// the app can actually answer.
///
/// Only the 512 numbers and a date are stored, never the frame, so the index is
/// about 2 KB per minute of watching and reveals nothing on its own.
final class CrossModalRetrievalLayer: ModelBackedLayer, VideoAILayer {
    let id = "fusion.retrieval"
    let title = "Search what it saw"
    let detail = "Indexes moments so you can find them later by describing them in words."
    let group = LayerGroup.multimodal
    let modality = LayerModality.video
    var availability: LayerAvailability {
        let image = ModelStore.shared.state("clip.image")
        let text = ModelStore.shared.state("clip.text")
        if case .ready = image, case .ready = text { return .available }
        let mb = ((ModelStore.manifest["clip.image"]?.totalBytes ?? 0)
                  + (ModelStore.manifest["clip.text"]?.totalBytes ?? 0)) / 1_000_000
        return .needsDownload("Needs \(mb) MB of models — switch on to download once")
    }
    let preferredInterval = 30
    let warmAtLaunch = false

    private struct Moment: Codable {
        let at: Date
        let vector: [Float]
    }

    private var index: [Moment] = []
    private var lastSample = Date.distantPast
    private var lastQuery = ""
    private var loaded = false

    init() { super.init(modelID: "clip.image") }

    override func ensureModel() {
        for id in ["clip.image", "clip.text"] {
            if case .ready = ModelStore.shared.state(id) { continue }
            ModelStore.shared.fetch(id)
        }
    }

    func warm() {
        ensureModel()
        CLIPEngine.shared.prepare()
        loadIndex()
    }

    func cool() { saveIndex() }

    private var indexURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
        return base.appendingPathComponent("retrieval-index.json")
    }

    private func loadIndex() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Moment].self, from: data) else { return }
        index = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL)
    }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard CLIPEngine.shared.imageReady else { ensureModel(); return nil }
        loadIndex()

        var out = LayerOutput()

        // Sample the view every few seconds rather than every run.
        if Date().timeIntervalSince(lastSample) > 5,
           let vector = CLIPEngine.shared.embed(image: ctx.pixelBuffer) {
            lastSample = Date()
            index.append(Moment(at: Date(), vector: vector))
            // Roughly a day of continuous watching; beyond that the oldest go.
            if index.count > 17_280 { index.removeFirst(index.count - 17_280) }
            if index.count % 40 == 0 { saveIndex() }
        }
        out.badge = "\(index.count) moments"

        // Answer the search when the phrase changes.
        let query = Settings.shared.live.retrievalQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, query != lastQuery, CLIPEngine.shared.textReady,
              index.count > 3 else { return out }
        lastQuery = query
        guard let target = CLIPEngine.shared.embed(text: query) else { return out }

        let ranked = index
            .map { (moment: $0, score: CLIPEngine.similarity(target, $0.vector)) }
            .sorted { $0.score > $1.score }
            .prefix(5)
            .filter { $0.score > 0.18 }

        let formatter = DateFormatter()
        // 12-hour, which is this app's format everywhere.
        formatter.dateFormat = "MMM d, h:mm:ss a"

        if ranked.isEmpty {
            out.lines = ["\"\(query)\" — nothing in the index resembles that"]
        } else {
            out.lines = ["\"\(query)\" best matches:"] + ranked.map {
                String(format: "  %@  (%.2f)", formatter.string(from: $0.moment.at), $0.score)
            }
        }
        return out
    }

    func clearIndex() {
        index.removeAll()
        try? FileManager.default.removeItem(at: indexURL)
    }
}

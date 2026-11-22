import Foundation
import Vision
import CoreML
import CoreImage
import CoreVideo
import CoreGraphics

/// Face identity and expression, from models converted to Core ML for this app.
///
/// Apple provides neither: Vision finds faces and their landmarks but has no
/// faceprint and no attribute request, and Photos' People album uses private
/// internals. So the embedding comes from SFace (OpenCV Zoo) and the expression
/// from FER+, both converted from ONNX here. The conversion was checked against
/// the original ONNX run under onnxruntime — cosine 1.0000000 on both — so what
/// runs on the phone is the same function the authors published.

/// Shared face work: find faces, align them, and cut them to a model's input.
enum FaceCrop {

    /// Aligning on the eyes is what makes a face embedding comparable between two
    /// sightings. SFace was trained on faces rotated so the eyes are level and
    /// scaled to a standard separation; feeding it a head tilted forty degrees
    /// produces an embedding that mostly encodes the tilt, and the same person
    /// then fails to match themselves.
    static func aligned(face: VNFaceObservation, in buffer: CVPixelBuffer,
                        context: CIContext, side: Int) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent

        let box = CGRect(x: face.boundingBox.minX * extent.width,
                         y: face.boundingBox.minY * extent.height,
                         width: face.boundingBox.width * extent.width,
                         height: face.boundingBox.height * extent.height)

        var working = image
        // Rotate about the face centre so the eye line is horizontal.
        if let left = face.landmarks?.leftPupil?.normalizedPoints.first,
           let right = face.landmarks?.rightPupil?.normalizedPoints.first {
            // Landmarks are normalized to the face box, not the image.
            let lp = CGPoint(x: box.minX + CGFloat(left.x) * box.width,
                             y: box.minY + CGFloat(left.y) * box.height)
            let rp = CGPoint(x: box.minX + CGFloat(right.x) * box.width,
                             y: box.minY + CGFloat(right.y) * box.height)
            let angle = atan2(rp.y - lp.y, rp.x - lp.x)
            if abs(angle) > 0.03 {
                let centre = CGPoint(x: box.midX, y: box.midY)
                let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
                    .rotated(by: -angle)
                    .translatedBy(x: -centre.x, y: -centre.y)
                working = image.transformed(by: transform)
            }
        }

        // A little margin: these models were trained on crops that include the
        // chin and hairline, not on a box tight to the features.
        let padded = box.insetBy(dx: -box.width * 0.12, dy: -box.height * 0.12)
            .intersection(working.extent)
        guard padded.width > 24, padded.height > 24 else { return nil }
        guard let cropped = context.createCGImage(working, from: padded) else { return nil }

        // Square it off at the model's input size.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    /// Core ML's grayscale image input wants a one-component buffer. Building it
    /// by hand rather than asking CoreImage to render into one, because that
    /// render path is not reliable across formats and a silently wrong conversion
    /// here would look like a bad model.
    static func grayBuffer(from image: CGImage, side: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                  kCVPixelFormatType_OneComponent8, nil,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let ctx = CGContext(data: base, width: side, height: side,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}

// MARK: - Face identity

/// Recognising a face as one seen before.
///
/// No names and no enrolment screen: faces get a stable number, and a face seen
/// repeatedly becomes "familiar". That makes the useful alert possible — an
/// unfamiliar face at the door — without a contacts list, and it means the app
/// never holds anyone's name against their face.
///
/// What is stored is a 128-number vector per face, never an image. Nobody can be
/// reconstructed or looked up from it, and it stays on the device.
final class FaceIdentityLayer: ModelBackedLayer, VideoAILayer {
    let id = "faces.identity"
    let title = "Face recognition"
    let detail = "Recognises a face as one seen before, and flags one that has not been. No names stored."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    var availability: LayerAvailability { modelAvailability }
    let preferredInterval = 10
    let warmAtLaunch = false

    private struct Known: Codable {
        var label: Int
        var vector: [Float]
        var sightings: Int
        var firstSeen: Date
        var lastSeen: Date
    }

    private let request: VNDetectFaceLandmarksRequest = {
        // Landmarks rather than plain rectangles: the eyes are what the alignment
        // needs, and alignment is most of the accuracy.
        VNDetectFaceLandmarksRequest()
    }()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var gallery: [Known] = []
    private var nextLabel = 1
    private var loaded = false
    private var lastAlert = Date.distantPast

    /// SFace embeddings are compared by cosine. Same person typically lands above
    /// 0.4 and different people below 0.3; 0.363 is the threshold OpenCV ships
    /// with the model, so it is the one used here rather than one I invented.
    private let matchThreshold: Float = 0.363
    /// Seen this many times before it counts as familiar.
    private let familiarAfter = 4

    init() { super.init(modelID: "faces.identity") }

    func warm() {
        ensureModel()
        loadGallery()
    }

    func cool() { saveGallery() }

    private var galleryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("face-gallery.json")
    }

    private func loadGallery() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: galleryURL),
              let decoded = try? JSONDecoder().decode([Known].self, from: data) else { return }
        gallery = decoded
        nextLabel = (gallery.map(\.label).max() ?? 0) + 1
    }

    private func saveGallery() {
        guard let data = try? JSONEncoder().encode(gallery) else { return }
        try? data.write(to: galleryURL)
    }

    func clearGallery() {
        gallery.removeAll()
        nextLabel = 1
        try? FileManager.default.removeItem(at: galleryURL)
        EventLog.action("faces.gallery.cleared", [:])
    }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let model = ModelStore.shared.model(modelID) else { ensureModel(); return nil }
        loadGallery()

        try ctx.handler.perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }

        var out = LayerOutput()
        var notes: [String] = []
        let now = Date()

        for face in faces {
            guard face.boundingBox.width > 0.04,
                  let crop = FaceCrop.aligned(face: face, in: ctx.pixelBuffer,
                                              context: ciContext, side: 112),
                  let buffer = CLIPEngine.pixelBuffer(from: crop, width: 112, height: 112)
            else { continue }

            guard let vector = embed(buffer, with: model) else { continue }

            var best: (index: Int, score: Float)?
            for (i, known) in gallery.enumerated() {
                let score = cosine(vector, known.vector)
                if best == nil || score > best!.score { best = (i, score) }
            }

            if let best, best.score >= matchThreshold {
                gallery[best.index].sightings += 1
                gallery[best.index].lastSeen = now
                // Nudge the stored vector toward the new sighting so the entry
                // tracks lighting and angle instead of drifting out of match.
                for i in gallery[best.index].vector.indices {
                    gallery[best.index].vector[i] =
                        gallery[best.index].vector[i] * 0.9 + vector[i] * 0.1
                }
                let entry = gallery[best.index]
                let familiar = entry.sightings >= familiarAfter
                out.shapes.append(.box(face.boundingBox,
                                       label: familiar
                                           ? "#\(entry.label) familiar"
                                           : "#\(entry.label) seen \(entry.sightings)x",
                                       tint: familiar ? .person : .face))
            } else {
                let label = nextLabel
                nextLabel += 1
                gallery.append(Known(label: label, vector: vector, sightings: 1,
                                     firstSeen: now, lastSeen: now))
                out.shapes.append(.box(face.boundingBox, label: "#\(label) new", tint: .alert))
                notes.append("a face not seen before (#\(label))")
                if now.timeIntervalSince(lastAlert) > 60 {
                    lastAlert = now
                    out.alert = "Unfamiliar face"
                }
            }
        }

        // Forget faces not seen for a fortnight, so the gallery does not grow
        // until everything matches something.
        gallery.removeAll { now.timeIntervalSince($0.lastSeen) > 14 * 86_400 }
        if gallery.count > 300 { gallery.removeFirst(gallery.count - 300) }
        if Int(now.timeIntervalSince1970) % 30 == 0 { saveGallery() }

        out.badge = "\(gallery.count) known"
        out.lines = notes
        return out.isEmpty ? nil : out
    }

    private func embed(_ buffer: CVPixelBuffer, with model: MLModel) -> [Float]? {
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["face": MLFeatureValue(pixelBuffer: buffer)])
            let out = try model.prediction(from: provider)
            guard let array = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
            var vector = [Float](repeating: 0, count: array.count)
            array.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                for i in 0..<array.count { vector[i] = base[i] }
            }
            var norm: Float = 0
            for v in vector { norm += v * v }
            norm = max(1e-6, norm.squareRoot())
            for i in vector.indices { vector[i] /= norm }
            return vector
        } catch {
            EventLog.error(error, name: "faces.embed.failed")
            return nil
        }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var total: Float = 0
        for i in a.indices { total += a[i] * b[i] }
        return total
    }
}

// MARK: - Face attributes

/// Expression and head pose per face.
///
/// Expression comes from FER+, which scores eight: neutral, happy, surprised,
/// sad, angry, disgusted, afraid, contemptuous. Head pose comes from Vision for
/// free, and is often the more useful of the two for a camera watching a doorway —
/// where someone is looking matters more than how they feel about it.
///
/// Age and gender are deliberately absent. Models for both exist and would have
/// been no harder to add than this one; they are also wrong often enough that
/// acting on their output is a bad idea, and a sentry camera labelling people by
/// age and gender is a feature worth not building.
final class FaceAttributesLayer: ModelBackedLayer, VideoAILayer {
    let id = "faces.attributes"
    let title = "Face attributes"
    let detail = "Expression and head pose per face. No age or gender — see the note."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    var availability: LayerAvailability { modelAvailability }
    let preferredInterval = 12
    let warmAtLaunch = false

    /// FER+ output order, as published with the model.
    private static let emotions = ["neutral", "happy", "surprised", "sad",
                                   "angry", "disgusted", "afraid", "contemptuous"]

    private let request = VNDetectFaceLandmarksRequest()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastReported = ""

    init() { super.init(modelID: "faces.emotion") }

    func warm() { ensureModel() }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let model = ModelStore.shared.model(modelID) else { ensureModel(); return nil }

        try ctx.handler.perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }

        var out = LayerOutput()
        var headline: String?

        for face in faces {
            var parts: [String] = []

            if face.boundingBox.width > 0.05,
               let crop = FaceCrop.aligned(face: face, in: ctx.pixelBuffer,
                                           context: ciContext, side: 64),
               let buffer = FaceCrop.grayBuffer(from: crop, side: 64),
               let (label, confidence) = classify(buffer, with: model) {
                parts.append(String(format: "%@ %.0f%%", label, confidence * 100))
                if confidence > 0.6 { headline = label }
            }

            // Free from Vision, and these are NSNumber? rather than Float.
            if let yaw = face.yaw?.doubleValue {
                let degrees = yaw * 180 / .pi
                if abs(degrees) > 20 {
                    parts.append(degrees > 0 ? "looking right" : "looking left")
                } else {
                    parts.append("facing camera")
                }
            }
            if let quality = face.faceCaptureQuality, quality < 0.3 {
                parts.append("poor view")
            }

            out.shapes.append(.box(face.boundingBox,
                                   label: parts.isEmpty ? nil : parts.joined(separator: " · "),
                                   tint: .face))
        }

        out.badge = headline ?? "\(faces.count) face\(faces.count == 1 ? "" : "s")"
        if let headline, headline != lastReported, headline != "neutral" {
            lastReported = headline
            out.lines = ["expression: \(headline)"]
        }
        return out.isEmpty ? nil : out
    }

    private func classify(_ buffer: CVPixelBuffer, with model: MLModel) -> (String, Float)? {
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["face": MLFeatureValue(pixelBuffer: buffer)])
            let out = try model.prediction(from: provider)
            guard let array = out.featureValue(for: "emotion_logits")?.multiArrayValue,
                  array.count >= 8 else { return nil }

            var logits = [Float](repeating: 0, count: 8)
            array.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                for i in 0..<8 { logits[i] = base[i] }
            }
            // The model emits logits, so a softmax is needed before any of these
            // numbers can be read as a confidence.
            let peak = logits.max() ?? 0
            var exps = logits.map { expf($0 - peak) }
            let sum = max(1e-6, exps.reduce(0, +))
            for i in exps.indices { exps[i] /= sum }

            var bestIndex = 0
            for i in exps.indices where exps[i] > exps[bestIndex] { bestIndex = i }
            return (FaceAttributesLayer.emotions[bestIndex], exps[bestIndex])
        } catch {
            EventLog.error(error, name: "faces.emotion.failed")
            return nil
        }
    }
}

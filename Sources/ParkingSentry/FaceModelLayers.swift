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
            var angle = atan2(rp.y - lp.y, rp.x - lp.x)
            // Which pupil Vision calls "left" is the image's left in some
            // orientations and the subject's in others. Taken literally, the wrong
            // one gives an angle near π and rotates the face through 180° — the
            // crop then looks upside down to the model and the embedding is
            // meaningless, silently. Folding the eye vector onto the rightward
            // half-plane makes the levelling correct either way.
            if angle > .pi / 2 { angle -= .pi }
            if angle < -.pi / 2 { angle += .pi }
            if abs(angle) > 0.03 {
                let centre = CGPoint(x: box.midX, y: box.midY)
                let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
                    .rotated(by: -angle)
                    .translatedBy(x: -centre.x, y: -centre.y)
                working = image.transformed(by: transform)
            }
        }

        // A square crop around the face, not the face box stretched to a square.
        //
        // Vision's face boxes are noticeably taller than they are wide. Drawing one
        // into a square context squashed every face horizontally by about a fifth
        // before the model ever saw it — which both models read as a different face
        // shape, and it is the sort of error that leaves recognition merely
        // mediocre rather than visibly broken.
        //
        // The margin is because these models were trained on crops that include the
        // chin and hairline, not on a box tight to the features. `clampedToExtent`
        // means a face near the edge of the frame still yields a square crop
        // instead of a clipped, and therefore distorted, one.
        let cropSide = max(box.width, box.height) * 1.24
        let square = CGRect(x: box.midX - cropSide / 2, y: box.midY - cropSide / 2,
                            width: cropSide, height: cropSide)
        guard square.width > 24, square.height > 24 else { return nil }
        guard let cropped = context.createCGImage(working.clampedToExtent(),
                                                  from: square) else { return nil }

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
        // Gamma-encoded gray, not linear. `linearGray` always resolves, so the
        // fallback in the old `??` chain was dead code and every crop was handed to
        // the model in linear light — roughly a stop and a half darker in the
        // midtones than the gamma-encoded images FER+ was trained on, which skews
        // the expression it picks without ever looking like a failure.
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
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
    let title = "Seen this face before"
    let detail = "Tells you whether a face has been here before, and flags one that has not. No names and no photos are kept."
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

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var gallery: [Known] = []
    private var nextLabel = 1
    private var loaded = false
    private var lastAlert = Date.distantPast
    private var lastSaved = Date.distantPast

    /// A face that matched nothing, held back until it turns up again.
    ///
    /// Enrolling on a single sighting was the whole problem. One bad crop — a
    /// profile, a moment of backlight, someone half out of frame — produces an
    /// embedding that matches nothing, and the layer minted a new identity for it,
    /// announced "a face not seen before", and did it again on the next run. One
    /// person standing at a door became a dozen strangers in a minute, and the
    /// toggle's own count said so.
    private struct Provisional {
        var vector: [Float]
        var sightings: Int
        var at: Date
    }
    private var provisional: [Provisional] = []
    /// Unmatched faces have to agree with each other this many times before they
    /// are accepted as a genuinely new person.
    private let enrolAfter = 3

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

        let faces = try ctx.shared.faceLandmarks()
        guard !faces.isEmpty else { return nil }

        var out = LayerOutput()
        var notes: [String] = []
        var familiarNow = 0
        var strangersNow = 0
        let now = Date()
        // A provisional sighting that is not reinforced within a few seconds was a
        // bad crop, not a person.
        provisional.removeAll { now.timeIntervalSince($0.at) > 8 }

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
                if familiar { familiarNow += 1 } else { strangersNow += 1 }
                out.shapes.append(.box(face.boundingBox,
                                       label: familiar
                                           ? "#\(entry.label) familiar"
                                           : "#\(entry.label) seen \(entry.sightings)x",
                                       tint: familiar ? .person : .face))
            } else if let i = provisional.firstIndex(where: {
                cosine(vector, $0.vector) >= matchThreshold
            }) {
                // Seen this unknown face before, recently. Average the vectors so
                // the entry that eventually enrols is not one unlucky frame.
                provisional[i].sightings += 1
                provisional[i].at = now
                for k in provisional[i].vector.indices {
                    provisional[i].vector[k] = provisional[i].vector[k] * 0.6 + vector[k] * 0.4
                }
                strangersNow += 1

                if provisional[i].sightings >= enrolAfter {
                    let label = nextLabel
                    nextLabel += 1
                    gallery.append(Known(label: label, vector: provisional[i].vector,
                                         sightings: provisional[i].sightings,
                                         firstSeen: now, lastSeen: now))
                    provisional.remove(at: i)
                    out.shapes.append(.box(face.boundingBox, label: "#\(label) new",
                                           tint: .alert))
                    notes.append("a face not seen before (#\(label))")
                    if now.timeIntervalSince(lastAlert) > 60 {
                        lastAlert = now
                        out.alert = "Unfamiliar face"
                    }
                } else {
                    out.shapes.append(.box(face.boundingBox, label: "…", tint: .face))
                }
            } else {
                provisional.append(Provisional(vector: vector, sightings: 1, at: now))
                strangersNow += 1
                out.shapes.append(.box(face.boundingBox, label: "…", tint: .face))
            }
        }

        // Forget faces not seen for a fortnight, so the gallery does not grow
        // until everything matches something.
        gallery.removeAll { now.timeIntervalSince($0.lastSeen) > 14 * 86_400 }
        if gallery.count > 300 { gallery.removeFirst(gallery.count - 300) }
        // Elapsed time, not a modulo of the wall clock. The old test only saved on
        // the handful of runs that happened to land on an exact multiple of thirty
        // seconds, so whether the gallery survived the app being killed came down
        // to timing luck.
        if now.timeIntervalSince(lastSaved) > 30 {
            lastSaved = now
            saveGallery()
        }

        // Live: who is in front of the camera. Total: how big the stored gallery
        // is. These used to be one number — the gallery size — so the toggle read
        // "37 known" with nobody in the room, which is a true statement about the
        // database and a false one about the scene.
        if familiarNow > 0 && strangersNow > 0 {
            out.badge = "\(familiarNow) known · \(strangersNow) not"
        } else if familiarNow > 0 {
            out.badge = "\(familiarNow) familiar"
        } else if strangersNow > 0 {
            out.badge = "\(strangersNow) unrecognised"
        } else {
            out.badge = "\(faces.count) face\(faces.count == 1 ? "" : "s")"
        }
        out.total = gallery.isEmpty ? nil : "\(gallery.count) on file"
        out.lines = notes
        return out.isEmpty ? nil : out
    }

    private func embed(_ buffer: CVPixelBuffer, with model: MLModel) -> [Float]? {
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["face": MLFeatureValue(pixelBuffer: buffer)])
            let out = try model.prediction(from: provider)
            guard let array = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
            // Dtype checked before reinterpreting the backing store: a float16
            // output read as float32 does not fail, it returns plausible nonsense.
            var vector = [Float](repeating: 0, count: array.count)
            if array.dataType == .float32 {
                array.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                    for i in 0..<array.count { vector[i] = base[i] }
                }
            } else {
                for i in 0..<array.count { vector[i] = array[i].floatValue }
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
/// Age and gender live in their own layer rather than here, so they can be left
/// off independently of expression.
final class FaceAttributesLayer: ModelBackedLayer, VideoAILayer {
    let id = "faces.attributes"
    let title = "Expression and head turn"
    let detail = "Reads the expression on each face and which way the head is turned."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    var availability: LayerAvailability { modelAvailability }
    let preferredInterval = 12
    let warmAtLaunch = false

    /// FER+ output order, as published with the model.
    private static let emotions = ["neutral", "happy", "surprised", "sad",
                                   "angry", "disgusted", "afraid", "contemptuous"]

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastReported = ""

    init() { super.init(modelID: "faces.emotion") }

    func warm() { ensureModel() }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let model = ModelStore.shared.model(modelID) else { ensureModel(); return nil }

        let faces = try ctx.shared.faceLandmarks()
        guard !faces.isEmpty else { return nil }

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
            //
            // Reported as a magnitude rather than as "looking left" or "looking
            // right". Vision does not document which way positive yaw points, and
            // the two readings are opposites — getting it backwards would be an
            // assertion about where someone was looking that happened to be exactly
            // wrong, every time, with nothing on screen to suggest it. The angle
            // itself is unambiguous and answers the same question.
            if let yaw = face.yaw?.doubleValue {
                let degrees = abs(yaw * 180 / .pi)
                parts.append(degrees > 20
                             ? String(format: "turned %.0f°", degrees)
                             : "facing camera")
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

            // Dtype checked before reinterpreting the backing store: a float16
            // output read as float32 does not fail, it returns plausible nonsense.
            var logits = [Float](repeating: 0, count: 8)
            if array.dataType == .float32 {
                array.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                    for i in 0..<8 { logits[i] = base[i] }
                }
            } else {
                for i in 0..<8 { logits[i] = array[i].floatValue }
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

// MARK: - Age and gender

/// An age bracket and a gender guess per face.
///
/// Two Levi-Hassner GoogleNets from the ONNX model zoo, trained on Adience and
/// converted here. Age is eight coarse brackets rather than a number, because
/// brackets are what the model actually predicts — anything reported to the year
/// would be arithmetic dressed up as measurement.
///
/// What this is worth, measured rather than assumed. Run over labelled faces during
/// the conversion, gender came out 9 for 9 and age was plainly rough: a toddler of
/// about two landed in "4–6", a bearded man in his thirties in "15–20", someone in
/// their early thirties in "60–100" at 81% confidence. So gender is reported when
/// the model is confident, age is always shown as the bracket with its confidence,
/// and neither is ever stated as fact. Both are off by default and switch off
/// independently of expression.
///
/// The channel order is worth recording because it is the kind of mistake that
/// leaves a model merely mediocre instead of visibly broken. The zoo's README says
/// BGR; the zoo's own example script converts to RGB. Running both ways over the
/// labelled faces settled it — BGR scored 9/9 with 0.998 mean confidence, RGB
/// scored 8/9 and called a bearded man female at 0.99 — so the model is fed BGR and
/// the example script is simply wrong.
final class AgeGenderLayer: VideoAILayer {
    let id = "faces.ageGender"
    let title = "Rough age and gender"
    let detail = "A rough age range and a gender guess for each face. It is often wrong, so it always shows how sure it is."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let preferredInterval = 12
    let warmAtLaunch = false

    private static let ageModel = "faces.age"
    private static let genderModel = "faces.gender"
    private static let brackets = ["0–2", "4–6", "8–12", "15–20",
                                   "25–32", "38–43", "48–53", "60+"]
    private static let genders = ["male", "female"]

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Smoothed probabilities per face, matched between runs by overlap.
    ///
    /// A single frame's answer jumps between neighbouring brackets, and a caption
    /// that flips twice a second reads as a broken feature rather than an uncertain
    /// one. Averaging over the last few runs of the same face costs nothing and is
    /// also simply a better estimate than any one of them.
    private struct Smoothed {
        var box: CGRect
        var age: [Float]
        var gender: [Float]
        var runs: Int
        var at: Date
    }
    private var tracked: [Smoothed] = []

    var availability: LayerAvailability {
        let states = [ModelStore.shared.state(AgeGenderLayer.ageModel),
                      ModelStore.shared.state(AgeGenderLayer.genderModel)]
        if states.allSatisfy({ if case .ready = $0 { return true }; return false }) {
            return .available
        }
        for state in states {
            if case .failed(let why) = state { return .modelMissing("Download failed: \(why)") }
        }
        for state in states {
            if case .downloading(let f) = state {
                return .needsDownload(String(format: "Downloading… %.0f%%", f * 100))
            }
            if case .compiling = state { return .needsDownload("Compiling on device…") }
        }
        let mb = ((ModelStore.manifest[AgeGenderLayer.ageModel]?.totalBytes ?? 0)
                  + (ModelStore.manifest[AgeGenderLayer.genderModel]?.totalBytes ?? 0)) / 1_000_000
        return .needsDownload("Needs \(mb) MB of models — switch on to download them once")
    }

    func warm() {
        for id in [AgeGenderLayer.ageModel, AgeGenderLayer.genderModel] {
            if case .ready = ModelStore.shared.state(id) { continue }
            ModelStore.shared.fetch(id)
        }
    }

    func cool() { tracked.removeAll() }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let ageModel = ModelStore.shared.model(AgeGenderLayer.ageModel),
              let genderModel = ModelStore.shared.model(AgeGenderLayer.genderModel) else {
            warm()
            return nil
        }

        let faces = try ctx.shared.faceLandmarks()
        guard !faces.isEmpty else { tracked.removeAll(); return nil }

        let now = Date()
        tracked.removeAll { now.timeIntervalSince($0.at) > 3 }

        var out = LayerOutput()
        var described = 0

        for face in faces {
            // Below this the crop is mostly interpolation and the answer is noise.
            guard face.boundingBox.width > 0.05,
                  let crop = FaceCrop.aligned(face: face, in: ctx.pixelBuffer,
                                              context: ciContext, side: 224),
                  let buffer = CLIPEngine.pixelBuffer(from: crop, width: 224, height: 224)
            else { continue }

            guard let ages = probabilities(buffer, model: ageModel,
                                           output: "age_probs", count: 8),
                  let genders = probabilities(buffer, model: genderModel,
                                              output: "gender_probs", count: 2)
            else { continue }

            // Match to a face from the previous run by overlap, and average.
            let box = face.boundingBox
            var smoothed: Smoothed
            if let i = tracked.firstIndex(where: { iou($0.box, box) > 0.3 }) {
                var existing = tracked[i]
                let w = Float(min(0.5, 1.0 / Double(existing.runs + 1)))
                for k in 0..<8 { existing.age[k] = existing.age[k] * (1 - w) + ages[k] * w }
                for k in 0..<2 { existing.gender[k] = existing.gender[k] * (1 - w) + genders[k] * w }
                existing.box = box
                existing.runs += 1
                existing.at = now
                tracked[i] = existing
                smoothed = existing
            } else {
                smoothed = Smoothed(box: box, age: ages, gender: genders, runs: 1, at: now)
                tracked.append(smoothed)
            }

            var parts: [String] = []
            let gi = smoothed.gender.indices.max(by: { smoothed.gender[$0] < smoothed.gender[$1] }) ?? 0
            // Gender is only stated when the model is actually confident. Below
            // this it is a coin toss and saying so is worse than saying nothing.
            if smoothed.gender[gi] > 0.75 {
                parts.append(String(format: "%@ %.0f%%",
                                    AgeGenderLayer.genders[gi], smoothed.gender[gi] * 100))
            }
            let ai = smoothed.age.indices.max(by: { smoothed.age[$0] < smoothed.age[$1] }) ?? 0
            parts.append(String(format: "%@ %.0f%%",
                                AgeGenderLayer.brackets[ai], smoothed.age[ai] * 100))

            described += 1
            out.shapes.append(.box(box, label: parts.joined(separator: " · "), tint: .face))
        }

        guard described > 0 else { return nil }
        out.badge = "\(described) estimated"
        return out
    }

    private func probabilities(_ buffer: CVPixelBuffer, model: MLModel,
                               output: String, count: Int) -> [Float]? {
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["face": MLFeatureValue(pixelBuffer: buffer)])
            let result = try model.prediction(from: provider)
            guard let array = result.featureValue(for: output)?.multiArrayValue,
                  array.count >= count else { return nil }
            // Both graphs end in a Softmax, so these are already probabilities and
            // applying another one here would flatten them towards uniform.
            //
            // Dtype checked before reinterpreting the store: these were converted
            // at float16 precision, and although the declared output is float32,
            // reading float16 bytes as float32 would not fail — it would return
            // plausible numbers that happen to be wrong.
            var values = [Float](repeating: 0, count: count)
            if array.dataType == .float32 {
                array.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                    for i in 0..<count { values[i] = base[i] }
                }
            } else {
                for i in 0..<count { values[i] = array[i].floatValue }
            }
            return values
        } catch {
            EventLog.error(error, name: "faces.ageGender.failed")
            return nil
        }
    }
}

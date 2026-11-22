import Vision
import CoreGraphics
import CoreVideo
import Foundation

/// Vision-framework layers: detection, recognition and reading.
///
/// Every request here is Apple's own, running on the Neural Engine, with no bundled
/// model and no network. The few capabilities that sound like they belong in this
/// list but have no public API at all are declared at the bottom of this file with
/// the reason, because a layer that quietly does not exist is worse than one that
/// says what it cannot do.

// MARK: - Object labels (reads the main detector, costs nothing)

final class ObjectLabelLayer: DerivedAILayer {
    let id = "objects"
    let title = "Object labels"
    let detail = "Class and confidence for everything the detector names this frame."
    let group = LayerGroup.vision
    let modality = LayerModality.derived
    let availability = LayerAvailability.available

    func process(_ ctx: FrameContext) -> LayerOutput? {
        guard !ctx.subjects.isEmpty else { return nil }
        var out = LayerOutput()
        out.shapes = ctx.subjects.map { s in
            .box(s.boundingBox,
                 label: String(format: "%@ %.0f%%", s.label, s.confidence * 100),
                 tint: tint(for: s.category))
        }
        out.badge = "\(ctx.subjects.count)"
        return out
    }

    private func tint(for c: SubjectCategory) -> LayerTint {
        switch c {
        case .person:  return .person
        case .vehicle: return .vehicle
        case .animal:  return .animal
        default:       return .primary
        }
    }
}

// MARK: - Tracking

final class TrackingLayer: DerivedAILayer {
    let id = "tracking"
    let title = "Track IDs & trails"
    let detail = "Persistent ID per thing, with the path it has taken."
    let group = LayerGroup.vision
    let modality = LayerModality.derived
    let availability = LayerAvailability.available

    func process(_ ctx: FrameContext) -> LayerOutput? {
        let live = ctx.tracks.filter { $0.misses <= 2 }
        guard !live.isEmpty else { return nil }
        var out = LayerOutput()
        for t in live {
            out.shapes.append(.box(t.box, label: "#\(t.id) \(t.label)", tint: .primary))
            let trail = t.samples.suffix(40).map(\.centre)
            if trail.count > 2 { out.shapes.append(.polyline(Array(trail), tint: .flow)) }
        }
        out.badge = "\(live.count)"
        return out
    }
}

// MARK: - Pose

final class BodyPoseLayer: VideoAILayer {
    let id = "pose.body"
    let title = "Body pose"
    let detail = "Skeleton joints for every person in frame."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 2

    private let request = VNDetectHumanBodyPoseRequest()

    /// Joint pairs that make a readable skeleton. Vision returns points, not bones.
    private static let bones: [(VNHumanBodyPoseObservation.JointName,
                                VNHumanBodyPoseObservation.JointName)] = [
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root), (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.nose, .neck)
    ]

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let people = request.results, !people.isEmpty else { return nil }

        var out = LayerOutput()
        for person in people {
            var pairs: [(CGPoint, CGPoint)] = []
            for (a, b) in BodyPoseLayer.bones {
                guard let pa = try? person.recognizedPoint(a),
                      let pb = try? person.recognizedPoint(b),
                      pa.confidence > 0.25, pb.confidence > 0.25 else { continue }
                pairs.append((pa.location, pb.location))
            }
            if !pairs.isEmpty { out.shapes.append(.bones(pairs, tint: .person)) }
        }
        out.badge = "\(people.count)"
        return out
    }
}

final class HandPoseLayer: VideoAILayer {
    let id = "pose.hand"
    let title = "Hand pose"
    let detail = "Finger joints, up to four hands."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 2

    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 4
        return r
    }()

    private static let chains: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let hands = request.results, !hands.isEmpty else { return nil }

        var out = LayerOutput()
        for hand in hands {
            var pairs: [(CGPoint, CGPoint)] = []
            for chain in HandPoseLayer.chains {
                var previous: CGPoint?
                for joint in chain {
                    guard let p = try? hand.recognizedPoint(joint), p.confidence > 0.3 else {
                        previous = nil
                        continue
                    }
                    if let previous { pairs.append((previous, p.location)) }
                    previous = p.location
                }
            }
            if !pairs.isEmpty { out.shapes.append(.bones(pairs, tint: .hand)) }
        }
        out.badge = "\(hands.count)"
        return out
    }
}

// MARK: - Faces

final class FaceLayer: VideoAILayer {
    let id = "faces"
    let title = "Face detection"
    let detail = "Face boxes with head angle and capture quality."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        // Shared with every other face layer: one detection per frame, not one per
        // layer. With the face group switched on this used to run five times.
        let faces = try ctx.shared.faceRects()
        guard !faces.isEmpty else { return nil }

        var out = LayerOutput()
        for face in faces {
            // These three are NSNumber?, not Float — Vision's own declaration.
            var bits: [String] = []
            if let yaw = face.yaw?.doubleValue {
                bits.append(String(format: "yaw %.0f°", yaw * 180 / .pi))
            }
            if let pitch = face.pitch?.doubleValue {
                bits.append(String(format: "pitch %.0f°", pitch * 180 / .pi))
            }
            if let q = face.faceCaptureQuality {
                bits.append(String(format: "q %.2f", q))
            }
            out.shapes.append(.box(face.boundingBox,
                                   label: bits.isEmpty ? nil : bits.joined(separator: " "),
                                   tint: .face))
        }
        out.badge = "\(faces.count)"
        return out
    }
}

final class FaceLandmarkLayer: VideoAILayer {
    let id = "faces.landmarks"
    let title = "Face landmarks"
    let detail = "Eyes, brows, nose, lips and jaw contour per face."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 2

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        let faces = try ctx.shared.faceLandmarks()
        guard !faces.isEmpty else { return nil }

        var out = LayerOutput()
        for face in faces {
            guard let marks = face.landmarks else { continue }
            let box = face.boundingBox
            let regions = [marks.faceContour, marks.leftEye, marks.rightEye,
                           marks.leftEyebrow, marks.rightEyebrow, marks.nose,
                           marks.noseCrest, marks.outerLips, marks.innerLips,
                           marks.medianLine]
            for region in regions.compactMap({ $0 }) {
                // Landmark points are normalized to the FACE BOX, origin at its
                // lower-left — not to the image. Mapping them as if they were
                // image coordinates is the classic way to get a face drawn in the
                // corner of the frame.
                let pts = region.normalizedPoints.map { p in
                    CGPoint(x: box.minX + CGFloat(p.x) * box.width,
                            y: box.minY + CGFloat(p.y) * box.height)
                }
                guard pts.count > 1 else { continue }
                out.shapes.append(.polyline(pts, tint: .face))
            }
        }
        out.badge = "\(faces.count)"
        return out
    }
}

// MARK: - Text

final class SceneTextLayer: VideoAILayer {
    let id = "ocr"
    let title = "Scene text (OCR)"
    let detail = "Reads any text in frame — signs, labels, screens."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    /// Accurate recognition is the expensive one in this whole set; three times a
    /// second is plenty for text that is not going anywhere.
    let preferredInterval = 10

    private let request: VNRecognizeTextRequest = {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        return r
    }()

    private var lastSeen = Set<String>()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let found = request.results, !found.isEmpty else { return nil }

        var out = LayerOutput()
        var strings: [String] = []
        for obs in found {
            guard let top = obs.topCandidates(1).first, top.confidence > 0.3 else { continue }
            // VNRecognizedTextObservation inherits VNRectangleObservation, so the
            // corners come free and the quad follows text at an angle.
            out.shapes.append(.quad([obs.bottomLeft, obs.bottomRight,
                                     obs.topRight, obs.topLeft],
                                    label: top.string, tint: .text))
            strings.append(top.string)
        }
        // Only report text that is new, or the feed fills with the same sign.
        // `lastSeen` is this frame's strings and nothing else, so it is bounded by
        // what is in view and needs no separate cap — the line that used to be here
        // reassigned it to the value it had just been given, which did nothing.
        let fresh = strings.filter { !lastSeen.contains($0) }
        lastSeen = Set(strings)
        out.lines = fresh
        out.badge = strings.isEmpty ? nil : "\(strings.count)"
        return out
    }
}

/// Plate reading, built on the same text recogniser but filtered hard.
///
/// This is honest ANPR rather than a plate model: Vision reads the characters, and
/// the filtering below decides whether what it read is plate-shaped. That catches
/// clean, reasonably square-on plates and will miss sharply angled or dirty ones.
final class PlateLayer: VideoAILayer {
    let id = "anpr"
    let title = "License plates"
    let detail = "Plate-shaped text only, character-filtered. Needs a fairly square-on view."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 8

    private let request: VNRecognizeTextRequest = {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        // Language correction turns plate strings into words; it has to be off.
        r.usesLanguageCorrection = false
        r.minimumTextHeight = 0.015
        return r
    }()

    /// Plate => how many frames it has been read on. A plate confirmed across
    /// several frames is worth reporting; a single frame of it is a guess.
    private var seen: [String: Int] = [:]
    private var reported = Set<String>()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let found = request.results else { return nil }

        var out = LayerOutput()
        var hits: [String] = []
        var inFrame = 0

        for obs in found {
            guard let top = obs.topCandidates(3).first(where: { PlateLayer.looksLikePlate($0.string) })
            else { continue }
            let box = obs.boundingBox
            let aspect = box.width / max(box.height, 0.0001)
            // US plates are about 2:1; Vision's box usually crops tight to the
            // characters, so the usable window is wide.
            guard aspect > 1.6, aspect < 7.5 else { continue }

            let plate = PlateLayer.normalize(top.string)
            seen[plate, default: 0] += 1
            inFrame += 1
            out.shapes.append(.box(box, label: plate, tint: .text))
            if seen[plate] ?? 0 >= 3, !reported.contains(plate) {
                reported.insert(plate)
                hits.append("plate \(plate)")
            }
        }

        // Evicting the least-confirmed entries rather than wiping the table: the
        // previous `removeAll` threw away every partial confirmation at once, so a
        // plate that had been read twice started again from zero and a busy lot
        // could keep resetting plates that were one frame from being reported.
        if seen.count > 400 {
            let keep = seen.sorted { $0.value > $1.value }.prefix(200)
            seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        out.lines = hits
        // Live: how many plate-shaped strings are on screen. Total: how many
        // distinct plates have been confirmed this session. These used to be the
        // same number, so an empty driveway still showed the night's running tally.
        out.badge = inFrame > 0 ? "\(inFrame)" : nil
        out.total = reported.isEmpty ? nil : "\(reported.count) seen"
        return out.isEmpty ? nil : out
    }

    static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Plate-shaped: 5 to 8 characters, letters and digits only, and not a word.
    /// The mixed-case and punctuation rejections are what keep street signs out.
    static func looksLikePlate(_ raw: String) -> Bool {
        let s = normalize(raw)
        guard s.count >= 5, s.count <= 8 else { return false }
        let digits = s.filter(\.isNumber).count
        let letters = s.filter(\.isLetter).count
        // Every real plate format mixes the two, or is all digits. Pure letters of
        // this length is a word.
        guard digits > 0 else { return false }
        guard letters > 0 || digits >= 5 else { return false }
        return true
    }
}

final class BarcodeLayer: VideoAILayer {
    let id = "barcodes"
    let title = "Barcodes & QR"
    let detail = "Every symbology Vision supports, with the decoded payload."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 5

    private let request = VNDetectBarcodesRequest()
    private var reported = Set<String>()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let codes = request.results, !codes.isEmpty else { return nil }

        var out = LayerOutput()
        var fresh: [String] = []
        for code in codes {
            let payload = code.payloadStringValue ?? "(binary)"
            out.shapes.append(.box(code.boundingBox,
                                   label: code.symbology.rawValue, tint: .text))
            if !reported.contains(payload) {
                reported.insert(payload)
                fresh.append("\(code.symbology.rawValue): \(payload)")
            }
        }
        // Bounded: this is a dedupe set, not a log, and a camera pointed at a shelf
        // of barcodes would otherwise grow it without limit for the whole session.
        if reported.count > 500 { reported.removeAll() }
        out.lines = fresh
        out.badge = "\(codes.count)"
        out.total = reported.count > codes.count ? "\(reported.count) seen" : nil
        return out
    }
}

// MARK: - Scene

/// Vision's own image classifier — over a thousand scene and object labels, fully
/// on-device. This is the honest stand-in for "scene description": it names what is
/// in the picture without a language model or a network call.
final class SceneClassifyLayer: VideoAILayer {
    let id = "scene"
    let title = "Scene classification"
    let detail = "Names the scene and its contents from Vision's own classifier, on-device."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 15

    private let request = VNClassifyImageRequest()
    private var lastTop = ""

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let results = request.results else { return nil }
        let top = results
            .filter { $0.confidence > 0.12 }
            .prefix(5)
            .map { String(format: "%@ %.0f%%", $0.identifier, $0.confidence * 100) }
        guard !top.isEmpty else { return nil }

        var out = LayerOutput()
        out.badge = results.first.map { $0.identifier } ?? nil
        if let first = results.first?.identifier, first != lastTop {
            lastTop = first
            out.lines = [top.joined(separator: ", ")]
        }
        return out
    }
}

final class AnimalLayer: VideoAILayer {
    let id = "animals"
    let title = "Animal recognition"
    let detail = "Vision's dedicated cat and dog detector, more sensitive than the general one."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 3

    private let request = VNRecognizeAnimalsRequest()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let animals = request.results, !animals.isEmpty else { return nil }

        var out = LayerOutput()
        for a in animals {
            // Confidences inside `labels` sum to 1, so they are scaled by the
            // observation's own confidence to mean anything.
            guard let best = a.labels.first else { continue }
            let score = best.confidence * a.confidence
            out.shapes.append(.box(a.boundingBox,
                                   label: String(format: "%@ %.0f%%", best.identifier, score * 100),
                                   tint: .animal))
        }
        out.badge = "\(animals.count)"
        return out
    }
}

final class HorizonLayer: VideoAILayer {
    let id = "horizon"
    let title = "Horizon"
    let detail = "Finds the horizon in the image, for levelling the camera."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 20

    private let request = VNDetectHorizonRequest()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let h = request.results?.first else { return nil }
        let angle = Double(h.angle)
        var out = LayerOutput()
        out.shapes = [.polyline(ctx.levelLine(angle: angle), tint: .neutral)]
        out.badge = String(format: "%.1f°", angle * 180 / .pi)
        return out
    }
}

final class OrientedBoxLayer: VideoAILayer {
    let id = "rects"
    let title = "Oriented rectangles"
    let detail = "Four-corner quads for rectangular things at any angle — signs, plates, doors."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 6

    private let request: VNDetectRectanglesRequest = {
        let r = VNDetectRectanglesRequest()
        r.minimumAspectRatio = 0.2
        r.maximumAspectRatio = 1.0
        r.minimumConfidence = 0.6
        r.maximumObservations = 12
        r.minimumSize = 0.05
        return r
    }()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let rects = request.results, !rects.isEmpty else { return nil }
        var out = LayerOutput()
        out.shapes = rects.map {
            .quad([$0.bottomLeft, $0.bottomRight, $0.topRight, $0.topLeft],
                  label: nil, tint: .primary)
        }
        out.badge = "\(rects.count)"
        return out
    }
}

// MARK: - Attributes

/// Dominant colour of each detected thing. Not a trained attribute classifier —
/// Apple ships none — but a measured modal colour, which is what "white sedan" or
/// "red jacket" actually needs and is reliable in daylight.
final class ColourAttributeLayer: DerivedAILayer {
    let id = "attributes.colour"
    let title = "Colour attributes"
    let detail = "Dominant colour per detection, measured from the pixels. Unreliable under sodium light."
    let group = LayerGroup.vision
    let modality = LayerModality.derived
    let availability = LayerAvailability.available

    func process(_ ctx: FrameContext) -> LayerOutput? {
        guard !ctx.subjects.isEmpty else { return nil }
        CVPixelBufferLockBaseAddress(ctx.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(ctx.pixelBuffer, .readOnly) }

        var out = LayerOutput()
        for s in ctx.subjects {
            guard let name = dominantColourName(in: s.boundingBox, ctx: ctx) else { continue }
            // A label, not another box. The object layer has already outlined this
            // exact subject, and two layers stroking the same rectangle produced a
            // doubled outline and two captions fighting for the same corner.
            out.shapes.append(.label("\(name) \(s.label)",
                                     at: CGPoint(x: s.boundingBox.midX,
                                                 y: s.boundingBox.minY - 0.012),
                                     tint: .primary))
        }
        out.badge = out.shapes.isEmpty ? nil : "\(out.shapes.count)"
        return out
    }

    /// Samples the middle of the box in YUV — the capture format — and converts a
    /// mean chroma to a colour name. Sampling the whole box drags in background.
    private func dominantColourName(in box: CGRect, ctx: FrameContext) -> String? {
        let pb = ctx.pixelBuffer
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }

        let yW = CVPixelBufferGetWidthOfPlane(pb, 0)
        let yH = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yBPR = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let cW = CVPixelBufferGetWidthOfPlane(pb, 1)
        let cH = CVPixelBufferGetHeightOfPlane(pb, 1)
        let cBPR = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let y = yBase.assumingMemoryBound(to: UInt8.self)
        let c = cBase.assumingMemoryBound(to: UInt8.self)

        // Middle half of the box, converted from bottom-left to top-left origin.
        let inset = box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25)
        let x0 = max(0, Int(inset.minX * CGFloat(yW)))
        let x1 = min(yW - 1, Int(inset.maxX * CGFloat(yW)))
        let ry0 = max(0, Int((1 - inset.maxY) * CGFloat(yH)))
        let ry1 = min(yH - 1, Int((1 - inset.minY) * CGFloat(yH)))
        guard x1 > x0 + 2, ry1 > ry0 + 2 else { return nil }

        var lumaSum = 0, n = 0
        var cbSum = 0, crSum = 0, cn = 0
        let stepX = max(1, (x1 - x0) / 12), stepY = max(1, (ry1 - ry0) / 12)
        var row = ry0
        while row <= ry1 {
            var col = x0
            while col <= x1 {
                lumaSum += Int(y[row * yBPR + col]); n += 1
                let cx = min(cW - 1, col / 2), cy = min(cH - 1, row / 2)
                let o = cy * cBPR + cx * 2
                cbSum += Int(c[o]); crSum += Int(c[o + 1]); cn += 1
                col += stepX
            }
            row += stepY
        }
        guard n > 0, cn > 0 else { return nil }

        let luma = Double(lumaSum) / Double(n)
        let cb = Double(cbSum) / Double(cn) - 128
        let cr = Double(crSum) / Double(cn) - 128
        let chroma = sqrt(cb * cb + cr * cr)

        if chroma < 14 {
            if luma > 190 { return "white" }
            if luma < 55  { return "black" }
            return luma > 120 ? "silver" : "grey"
        }
        // Hue from the chroma vector, in the Cb/Cr plane.
        var hue = atan2(cr, cb) * 180 / .pi
        if hue < 0 { hue += 360 }

        // Boundaries are the midpoints between the measured hue angles of the pure
        // colours under BT.601, which is the matrix the capture hardware uses:
        //
        //   magenta 51.6   red 108.6   orange 139.1   yellow 170.8
        //   green 231.6    teal 288.6  blue 350.8
        //
        // The previous table was rotated by roughly a quadrant and got every single
        // name wrong — red came back "purple", blue came back "teal", green came
        // back "brown" and yellow came back "red". It reads like it was written
        // against atan2(cb, cr) rather than atan2(cr, cb).
        // Brown and navy are the *muted* dark ends of orange and blue, so both
        // tests need chroma as well as luma. Pure saturated blue has a luma of
        // only 29 in this format, so darkness alone would have called every blue
        // car navy; its chroma is 129 against navy's 38.
        let muted = chroma < 70
        switch hue {
        case 21..<80:            return luma > 150 ? "pink" : "purple"
        case 80..<124:           return "red"
        case 124..<155:          return (luma < 110 && muted) ? "brown" : "orange"
        case 155..<201:          return "yellow"
        case 201..<260:          return "green"
        case 260..<320:          return "teal"
        default:                 return (luma < 70 && muted) ? "navy" : "blue"
        }
    }
}

// MARK: - Declared unavailable, with the reason

/// A layer that exists in the list so the question "was this built?" has a visible
/// answer, but cannot be switched on. The reason says what it would take.
///
/// Nothing in the vision group uses this any more — age and gender estimation was
/// the last entry and is now a real layer backed by converted models. The type
/// stays because it is the honest way to list a capability this device cannot do,
/// and inventing it again under pressure would be worse than keeping it.
final class UnavailableLayer: AILayer {
    let id: String
    let title: String
    let detail: String
    let group: LayerGroup
    let modality: LayerModality
    let availability: LayerAvailability

    init(id: String, title: String, detail: String,
         group: LayerGroup, modality: LayerModality = .video,
         availability: LayerAvailability) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.modality = modality
        self.availability = availability
    }

}

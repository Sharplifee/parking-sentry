import Vision
import CoreVideo
import CoreGraphics
import CoreImage
import Foundation

/// Segmentation, flow, saliency, trajectories and appearance matching.
///
/// Every one of these produces a full-resolution buffer that would be pointless to
/// draw pixel for pixel over a preview, so each is downsampled into the renderer's
/// grid shape. One drawing path, and the overlay stays legible instead of being a
/// wall of colour.

/// Reduces any single- or two-component mask buffer to a grid of 0–1 intensities.
/// Vision hands back several pixel formats depending on the request and the OS, so
/// the format is read at runtime rather than assumed — guessing it is how you get a
/// garbage overlay that looks like a bug in the model.
enum MaskGrid {

    /// Reduces a mask to a grid by *averaging* each cell, not by sampling a pixel
    /// from it.
    ///
    /// The previous version read one pixel per cell. Over a 1920-wide mask on a
    /// 48-wide grid that is one pixel in every twelve hundred, which made every
    /// coverage figure these layers report a coin flip and let a person standing
    /// side-on disappear from the segmentation overlay entirely between frames. A
    /// bounded number of taps per cell costs a few hundred microseconds and makes
    /// the percentages mean what they say.
    static func sample(_ buffer: CVPixelBuffer, cols: Int, rows: Int,
                       magnitude: Bool = false, normalize: Bool = true) -> [Double]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard w > 0, h > 0 else { return nil }

        var out = [Double](repeating: 0, count: cols * rows)
        var peak = 0.0

        /// At most this many taps along each axis of a cell. Four by four is enough
        /// to stop a thin subject vanishing and is independent of mask resolution.
        let taps = 4

        func value(_ sx: Int, _ sy: Int) -> Double? {
            switch format {
            case kCVPixelFormatType_OneComponent8:
                let p = base.assumingMemoryBound(to: UInt8.self)
                return Double(p[sy * bpr + sx]) / 255.0
            case kCVPixelFormatType_OneComponent16Half:
                // The depth model outputs a grayscale float16 image.
                let p = base.assumingMemoryBound(to: Float16.self)
                return Double(p[sy * (bpr / 2) + sx])
            case kCVPixelFormatType_OneComponent32Float:
                let p = base.assumingMemoryBound(to: Float.self)
                return Double(p[sy * (bpr / 4) + sx])
            case kCVPixelFormatType_TwoComponent32Float:
                let p = base.assumingMemoryBound(to: Float.self)
                let i = sy * (bpr / 4) + sx * 2
                let dx = Double(p[i]), dy = Double(p[i + 1])
                return magnitude ? (dx * dx + dy * dy).squareRoot() : dx
            case kCVPixelFormatType_TwoComponent16Half:
                // 16-bit half floats need no manual decode on Apple silicon:
                // Float16 is a real type here.
                let p = base.assumingMemoryBound(to: Float16.self)
                let i = sy * (bpr / 2) + sx * 2
                let dx = Double(p[i]), dy = Double(p[i + 1])
                return magnitude ? (dx * dx + dy * dy).squareRoot() : dx
            default:
                return nil
            }
        }

        // Probe the format once rather than per pixel.
        guard value(0, 0) != nil else { return nil }

        for gy in 0..<rows {
            // Grid is bottom-left origin; every Vision buffer is top-left.
            let y0 = ((rows - 1 - gy) * h) / rows
            let y1 = max(y0 + 1, ((rows - gy) * h) / rows)
            for gx in 0..<cols {
                let x0 = (gx * w) / cols
                let x1 = max(x0 + 1, ((gx + 1) * w) / cols)
                let stepY = max(1, (y1 - y0) / taps)
                let stepX = max(1, (x1 - x0) / taps)

                var sum = 0.0
                var n = 0
                var sy = y0
                while sy < y1 && sy < h {
                    var sx = x0
                    while sx < x1 && sx < w {
                        if let v = value(sx, sy), v.isFinite { sum += v; n += 1 }
                        sx += stepX
                    }
                    sy += stepY
                }
                guard n > 0 else { continue }
                let v = sum / Double(n)
                out[gy * cols + gx] = v
                peak = max(peak, abs(v))
            }
        }
        // Flow magnitudes are in pixels and saliency is already 0–1, so normalize
        // only when the data runs past 1 — and only when the caller wants a
        // relative picture at all.
        if normalize, peak > 1.0001 {
            for i in out.indices { out[i] = abs(out[i]) / peak }
        }
        return out
    }
}

// MARK: - Person segmentation

final class PersonSegmentationLayer: VideoAILayer {
    let id = "segmentation.person"
    let title = "Cut out people"
    let detail = "Traces the exact outline of a person instead of a box around them."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 3

    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        // Balanced is the only sensible choice for live video: accurate is built
        // for stills and fast is too ragged to read.
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let mask = request.results?.first?.pixelBuffer,
              let grid = MaskGrid.sample(mask, cols: 48, rows: 36) else { return nil }
        let covered = grid.filter { $0 > 0.5 }.count
        guard covered > 0 else { return nil }

        var out = LayerOutput()
        out.shapes = [.grid(values: grid, cols: 48, rows: 36, tint: .person)]
        out.badge = String(format: "%.0f%%", Double(covered) / Double(grid.count) * 100)
        return out
    }
}

// MARK: - Instance segmentation

final class InstanceMaskLayer: VideoAILayer {
    let id = "segmentation.instances"
    let title = "Cut out each thing"
    let detail = "Traces the exact outline of every separate thing in front, people or not."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 4

    private let request = VNGenerateForegroundInstanceMaskRequest()

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let obs = request.results?.first else { return nil }
        // allInstances excludes the background, so an empty set means an empty scene.
        guard !obs.allInstances.isEmpty else { return nil }

        // The low-resolution combined mask is the right one here: instance indices
        // are what gets drawn, and the upscaled variants cost far more for an
        // overlay that is 48 cells wide.
        guard let grid = MaskGrid.sample(obs.instanceMask, cols: 48, rows: 36) else { return nil }
        // Values are instance indices rather than coverage, so anything non-zero is
        // foreground. Scaling them by index would just tint instances differently,
        // which reads as noise.
        let binary = grid.map { $0 > 0.001 ? 0.8 : 0.0 }

        var out = LayerOutput()
        out.shapes = [.grid(values: binary, cols: 48, rows: 36, tint: .mask)]
        out.badge = "\(obs.allInstances.count)"
        return out
    }
}

// MARK: - Optical flow

final class OpticalFlowLayer: VideoAILayer {
    let id = "flow"
    let title = "Motion map"
    let detail = "Shows which way every part of the picture is moving. Heavy work, so it runs only a few times a second."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    /// Apple's own documentation calls this request resource-intensive and says to
    /// hold one at a time. Six frames apart at 15–30 fps is as hard as it is worth
    /// pushing on a phone that is also running a capture session.
    let preferredInterval = 6
    let warmAtLaunch = false

    /// Flow is computed between two frames, so the previous one has to be kept.
    /// It is a scaled-down copy rather than the capture buffer itself: holding a
    /// buffer from the capture pool starves the pool and stalls the session.
    private var previous: CVPixelBuffer?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var pool: CVPixelBufferPool?
    private let targetWidth = 384

    func cool() {
        previous = nil
        pool = nil
    }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let small = scaledCopy(of: ctx.pixelBuffer) else { return nil }
        defer { previous = small }
        guard let previous else { return nil }

        // The request targets the OLD frame and is performed against the NEW one,
        // which yields motion from previous to current.
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: previous,
                                                   options: [:])
        request.computationAccuracy = .low
        let handler = VNImageRequestHandler(cvPixelBuffer: small, options: [:])
        try handler.perform([request])

        // Unnormalized: these are displacements in pixels, and they need to stay
        // that way. Normalising per frame divided every cell by the frame's own
        // peak, so a motionless scene had its sensor noise scaled up to 1.0 and the
        // layer cheerfully reported a third of the view in motion while nothing
        // moved at all. A fixed threshold in pixels is the only honest reading.
        guard let flow = request.results?.first?.pixelBuffer,
              let raw = MaskGrid.sample(flow, cols: 40, rows: 30,
                                        magnitude: true, normalize: false)
        else { return nil }

        /// Displacement, in pixels of the 384-wide working image, below which a cell
        /// is noise rather than movement.
        let floor = 0.75
        /// Displacement that counts as fully lit on the overlay.
        let ceiling = 12.0

        let moving = raw.filter { $0 >= floor }.count
        let shaded = raw.map { v -> Double in
            guard v >= floor else { return 0 }
            return min(1.0, (v - floor) / (ceiling - floor))
        }

        var out = LayerOutput()
        out.shapes = [.grid(values: shaded, cols: 40, rows: 30, tint: .flow)]
        let fraction = Double(moving) / Double(raw.count) * 100
        out.badge = moving == 0 ? "still" : String(format: "%.0f%% moving", fraction)
        return out
    }

    private func scaledCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = Double(targetWidth) / Double(srcW)
        let w = targetWidth
        let h = max(1, Int(Double(srcH) * scale))

        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &created)
            pool = created
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out else { return nil }

        let image = CIImage(cvPixelBuffer: source)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciContext.render(image, to: out)
        return out
    }
}

// MARK: - Saliency

final class SaliencyLayer: VideoAILayer {
    let id: String
    let title: String
    let detail: String
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 4

    private let attention: Bool
    private let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    private let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

    /// Two flavours of the same idea, and the difference matters in practice:
    /// attention predicts where a person would look (usually one spot), objectness
    /// finds coherent things (usually several).
    init(attention: Bool) {
        self.attention = attention
        if attention {
            id = "saliency.attention"
            title = "Saliency (attention)"
            detail = "Where a person would look in this frame."
        } else {
            id = "saliency.objectness"
            title = "Saliency (objectness)"
            detail = "Finds solid things without naming them — it catches what the named detectors miss."
        }
    }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        let request: VNImageBasedRequest = attention ? attentionRequest : objectnessRequest
        try ctx.handler.perform([request])
        let obs = attention ? attentionRequest.results?.first
                            : objectnessRequest.results?.first
        guard let obs else { return nil }

        var out = LayerOutput()
        // The heat map is only 64x64 to begin with, so a 32x24 grid loses nothing.
        if let grid = MaskGrid.sample(obs.pixelBuffer, cols: 32, rows: 24) {
            out.shapes.append(.grid(values: grid, cols: 32, rows: 24, tint: .heat))
        }
        if let objects = obs.salientObjects {
            for o in objects {
                out.shapes.append(.box(o.boundingBox,
                                       label: String(format: "%.0f%%", o.confidence * 100),
                                       tint: .primary))
            }
            out.badge = "\(objects.count)"
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Trajectories

/// Parabolic trajectories — thrown and falling objects. Vision fits a curve, which
/// is why this finds a thrown rock that no detector would ever classify.
final class TrajectoryLayer: VideoAILayer {
    let id = "trajectories"
    let title = "Thrown or falling things"
    let detail = "Spots an arcing path — something thrown or dropped — that an ordinary detector would miss."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let warmAtLaunch = false

    /// trajectoryLength must be at least 5; this request is stateful across frames,
    /// so it is rebuilt on activation rather than per frame.
    private var request: VNDetectTrajectoriesRequest?
    private var reported = 0

    func warm() {
        guard request == nil else { return }
        let r = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 8)
        r.objectMinimumNormalizedRadius = 0.006
        r.objectMaximumNormalizedRadius = 0.2
        request = r
    }

    func cool() { request = nil; reported = 0 }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let request else { return nil }
        try ctx.handler.perform([request])
        guard let paths = request.results, !paths.isEmpty else { return nil }

        var out = LayerOutput()
        var notes: [String] = []
        for path in paths {
            let detected = path.detectedPoints.map(\.location)
            let projected = path.projectedPoints.map(\.location)
            if detected.count > 1 { out.shapes.append(.polyline(detected, tint: .alert)) }
            if projected.count > 1 { out.shapes.append(.polyline(projected, tint: .warn)) }

            // Curvature cannot tell thrown from dropped. In a y-up system gravity
            // opens every ballistic parabola downward, so `a` is negative for both
            // and the old test — a < 0 means thrown, a > 0 means falling — could
            // only ever report "thrown", because a > 0 would mean the object was
            // accelerating upward. What separates the two is the vertical
            // direction at the start: thrown rises first, dropped only descends.
            let a = path.equationCoefficients[0]
            guard abs(a) > 0.05, detected.count >= 5 else { continue }
            let rose = zip(detected, detected.dropFirst()).prefix(3)
                .contains { $1.y > $0.y + 0.002 }
            notes.append(rose ? "object thrown" : "object falling")
        }
        reported += notes.count
        out.lines = notes
        out.badge = "\(paths.count)"
        out.total = reported > 0 ? "\(reported) this session" : nil
        return out
    }
}

// MARK: - Re-identification

/// Appearance matching across a session. Not face recognition — Apple provides no
/// face-identity API — but a feature print of the whole person crop, compared
/// against the ones already seen. This answers "has that person been here before
/// today", which is the question a sentry camera actually raises. It matches on
/// overall appearance, so it holds up across a parking lot and fails the moment
/// someone changes their jacket. Stated because a re-ID that silently means
/// "similar clothes" would otherwise look like a broken face recogniser.
final class ReIdentificationLayer: VideoAILayer {
    let id = "reid"
    let title = "Same person again"
    let detail = "Matches someone against people seen earlier by their overall look and clothing, not their face."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 8
    let warmAtLaunch = false

    private let request = VNGenerateImageFeaturePrintRequest()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var gallery: [(label: Int, print: VNFeaturePrintObservation, last: Date)] = []
    private var nextLabel = 1

    /// What the tracker already knows is one person, so appearance does not have to
    /// rediscover it. A track is the strongest possible evidence that two crops are
    /// the same person, and tying identity to it is what stopped this layer
    /// inventing a new stranger every few frames.
    private struct Pending {
        var print: VNFeaturePrintObservation
        var frames: Int
        var label: Int?
    }
    private var byTrack: [Int: Pending] = [:]

    /// Distances between two prints of the *same* track, which is the only
    /// ground truth available on-device for what "same person" costs in this
    /// metric. VNFeaturePrintObservation distances are unbounded and their scale
    /// depends on the revision and the crop, so a hardcoded threshold is a guess;
    /// this measures the scale instead. Until enough samples exist the layer
    /// refuses to claim a match rather than claiming a wrong one.
    private var withinTrack: [Float] = []
    private var threshold: Float?
    /// Confirmed on this many consecutive runs before entering the gallery.
    private let confirmAfter = 3

    func cool() {
        gallery.removeAll(); byTrack.removeAll()
        withinTrack.removeAll(); threshold = nil
    }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        let people = ctx.tracks.filter { $0.category == .person && $0.misses == 0 }
        guard !people.isEmpty else { return nil }

        var out = LayerOutput()
        var notes: [String] = []
        var matchedNow = 0
        let now = Date()

        for track in people {
            let box = track.box
            guard box.width > 0.04, box.height > 0.08,
                  let crop = cropped(ctx.pixelBuffer, to: box) else { continue }

            let handler = VNImageRequestHandler(cgImage: crop, options: [:])
            try handler.perform([request])
            guard let fingerprint = request.results?.first else { continue }

            // Same track, consecutive runs: this is a same-person pair by
            // construction, so it calibrates the scale of the metric.
            if var pending = byTrack[track.id] {
                var d = Float(0)
                if (try? fingerprint.computeDistance(&d, to: pending.print)) != nil, d.isFinite {
                    withinTrack.append(d)
                    if withinTrack.count > 200 { withinTrack.removeFirst() }
                    recalibrate()
                }
                pending.print = fingerprint
                pending.frames += 1
                byTrack[track.id] = pending
            } else {
                byTrack[track.id] = Pending(print: fingerprint, frames: 1, label: nil)
            }

            guard var pending = byTrack[track.id] else { continue }

            // A track keeps whatever label it was given; identity is not re-decided
            // every frame, which is what used to make the count climb.
            if let label = pending.label {
                if let i = gallery.firstIndex(where: { $0.label == label }) {
                    gallery[i].last = now
                    gallery[i].print = fingerprint
                }
                out.shapes.append(.box(box, label: "#\(label)", tint: .warn))
                matchedNow += 1
                continue
            }

            guard pending.frames >= confirmAfter, let limit = threshold else {
                out.shapes.append(.box(box, label: "…", tint: .neutral))
                continue
            }

            var best: (label: Int, distance: Float)?
            for entry in gallery {
                var d = Float(0)
                guard (try? fingerprint.computeDistance(&d, to: entry.print)) != nil,
                      d.isFinite else { continue }
                if best == nil || d < best!.distance { best = (entry.label, d) }
            }

            if let best, best.distance < limit {
                pending.label = best.label
                byTrack[track.id] = pending
                if let i = gallery.firstIndex(where: { $0.label == best.label }) {
                    gallery[i].last = now
                }
                out.shapes.append(.box(box, label: "#\(best.label) seen before", tint: .warn))
                notes.append("appearance match #\(best.label)")
                matchedNow += 1
            } else {
                let label = nextLabel
                nextLabel += 1
                pending.label = label
                byTrack[track.id] = pending
                gallery.append((label, fingerprint, now))
                out.shapes.append(.box(box, label: "#\(label) new", tint: .person))
            }
        }

        // Forget tracks the tracker has dropped and anyone not seen for twenty
        // minutes, or the gallery grows until every new arrival matches something.
        let live = Set(ctx.tracks.map(\.id))
        byTrack = byTrack.filter { live.contains($0.key) }
        gallery.removeAll { now.timeIntervalSince($0.last) > 1200 }
        if gallery.count > 60 { gallery.removeFirst(gallery.count - 60) }

        out.lines = notes
        // Live: people being matched in this frame. Total: how many distinct
        // appearances are being held. The badge used to be the gallery size, so an
        // empty scene still read as a crowd.
        out.badge = matchedNow > 0 ? "\(matchedNow) matched" : "\(people.count) in view"
        out.total = gallery.isEmpty ? nil : "\(gallery.count) known"
        return out.isEmpty ? nil : out
    }

    /// Threshold sits above almost every same-person distance seen so far, so a
    /// match has to be at least as close as this person is to themselves.
    private func recalibrate() {
        guard withinTrack.count >= 12 else { return }
        let mean = withinTrack.reduce(0, +) / Float(withinTrack.count)
        let variance = withinTrack.reduce(0) { $0 + pow($1 - mean, 2) } / Float(withinTrack.count)
        threshold = mean + 2 * max(0.01, variance.squareRoot())
    }

    private func cropped(_ buffer: CVPixelBuffer, to box: CGRect) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let e = image.extent
        let rect = CGRect(x: box.minX * e.width, y: box.minY * e.height,
                          width: box.width * e.width, height: box.height * e.height)
            .intersection(e)
        guard rect.width > 8, rect.height > 8 else { return nil }
        return ciContext.createCGImage(image, from: rect)
    }
}

// MARK: - Scene anomaly

/// Novelty detection on the scene as a whole. The first few minutes build a picture
/// of what this view normally looks like; after that, a frame far from all of them
/// is flagged. Catches the thing no detector has a class for — a gate that is now
/// open, a vehicle where there is never a vehicle — and it is honest about needing
/// a quiet learning period first, because a baseline learned during activity learns
/// the activity.
final class SceneAnomalyLayer: VideoAILayer {
    let id = "anomaly"
    let title = "Something looks different"
    let detail = "Learns what this view normally looks like, then tells you when something does not fit."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 20
    let warmAtLaunch = false

    private let request = VNGenerateImageFeaturePrintRequest()
    private var baseline: [VNFeaturePrintObservation] = []
    private var distances: [Float] = []
    private var lastFlag = Date.distantPast
    private let baselineTarget = 24

    func cool() { baseline.removeAll(); distances.removeAll() }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        try ctx.handler.perform([request])
        guard let fingerprint = request.results?.first else { return nil }

        var out = LayerOutput()

        guard baseline.count >= baselineTarget else {
            baseline.append(fingerprint)
            out.badge = "learning \(baseline.count)/\(baselineTarget)"
            return out
        }

        var nearest = Float.greatestFiniteMagnitude
        for entry in baseline {
            var d = Float(0)
            guard (try? fingerprint.computeDistance(&d, to: entry)) != nil else { continue }
            nearest = min(nearest, d)
        }
        guard nearest < .greatestFiniteMagnitude else { return nil }

        distances.append(nearest)
        if distances.count > 200 { distances.removeFirst() }

        // Threshold from the distribution rather than a constant: what counts as
        // far depends on how varied this particular view is.
        let mean = distances.reduce(0, +) / Float(distances.count)
        let variance = distances.reduce(0) { $0 + pow($1 - mean, 2) } / Float(distances.count)
        let sd = max(0.01, variance.squareRoot())
        let z = (nearest - mean) / sd

        out.badge = String(format: "%.1fσ", z)
        if z > 3.2, Date().timeIntervalSince(lastFlag) > 60 {
            lastFlag = Date()
            out.lines = [String(format: "scene differs from normal by %.1f standard deviations", z)]
            out.alert = "Scene anomaly"
        } else if z < 1.5 {
            // Quiet and typical: fold it into the baseline so slow changes like
            // the sun moving do not become permanent anomalies.
            baseline.append(fingerprint)
            if baseline.count > 48 { baseline.removeFirst() }
        }
        return out
    }
}

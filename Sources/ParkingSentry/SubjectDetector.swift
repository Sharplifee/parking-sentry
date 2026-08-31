import Vision
import CoreML
import CoreVideo
import CoreGraphics

/// Stage 2: work out what the moving thing actually is.
///
/// Three detectors run against the same crop and their results are merged:
///
///  1. A bundled Core ML object detector (Apple's Vision-native YOLOv3-Tiny, 80 COCO
///     classes) — this is what gives cars, trucks, bicycles, birds, backpacks and the
///     rest an actual name.
///  2. Vision's dedicated human-rectangle detector, which is noticeably more sensitive
///     to small, distant people than the general detector is, so it catches figures at
///     the far end of a lot that YOLO drops.
///  3. Objectness saliency, class-agnostic, as a last resort: it answers "something
///     coherent is there" for anything the other two cannot name.
///
/// Shadows still lose at this stage — none of the three fire on a patch of dimmed
/// asphalt, because a shadow has no object boundary, no torso and no salient mass
/// distinct from the ground it lies on.
final class SubjectDetector {

    private let humanRequest = VNDetectHumanRectanglesRequest()
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private var coreMLRequest: VNCoreMLRequest?
    private let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

    /// Nil when the bundled model failed to load; the app still works on the Vision detectors alone.
    private(set) var modelLoaded = false
    private(set) var modelLoadError: String?

    init() {
        humanRequest.upperBodyOnly = false
        loadModel()
    }

    private func loadModel() {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            guard let url = Bundle.main.url(forResource: "YOLOv3Tiny", withExtension: "mlmodelc") else {
                modelLoadError = "YOLOv3Tiny.mlmodelc not in bundle"
                return
            }
            let ml = try MLModel(contentsOf: url, configuration: config)
            let vn = try VNCoreMLModel(for: ml)
            let req = VNCoreMLRequest(model: vn)
            req.imageCropAndScaleOption = .scaleFill
            coreMLRequest = req
            modelLoaded = true
        } catch {
            modelLoadError = String(describing: error)
        }
    }

    /// - Parameter roi: normalized region to search, origin bottom-left. Nil searches the whole frame.
    func detect(in pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation,
                roi: CGRect?,
                minConfidence: Float,
                wantUnknownObjects: Bool) -> [DetectedSubject] {

        let region = roi.map { clampAndPad($0, pad: 0.12) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        humanRequest.regionOfInterest = region
        poseRequest.regionOfInterest = region
        coreMLRequest?.regionOfInterest = region
        saliencyRequest.regionOfInterest = region

        var requests: [VNRequest] = [humanRequest, poseRequest]
        if let r = coreMLRequest { requests.append(r) }
        if wantUnknownObjects { requests.append(saliencyRequest) }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation,
                                            options: [:])
        do { try handler.perform(requests) } catch { return [] }

        var out: [DetectedSubject] = []

        // --- 1. named objects from the Core ML detector ---
        for obs in (coreMLRequest?.results as? [VNRecognizedObjectObservation] ?? []) {
            guard let top = obs.labels.first, top.confidence >= minConfidence else { continue }
            out.append(DetectedSubject(boundingBox: obs.boundingBox,
                                       confidence: top.confidence,
                                       label: top.identifier,
                                       category: COCOClass.category(for: top.identifier),
                                       jointCount: 0))
        }

        // --- 2. people, including ones the general detector missed ---
        var skeletons: [(box: CGRect, count: Int)] = []
        for pose in (poseRequest.results ?? []) {
            guard let pts = try? pose.recognizedPoints(.all) else { continue }
            let good = pts.values.filter { $0.confidence > 0.3 }
            guard let minX = good.map({ $0.location.x }).min(),
                  let maxX = good.map({ $0.location.x }).max(),
                  let minY = good.map({ $0.location.y }).min(),
                  let maxY = good.map({ $0.location.y }).max() else { continue }
            skeletons.append((CGRect(x: minX, y: minY,
                                     width: maxX - minX, height: maxY - minY), good.count))
        }

        for obs in (humanRequest.results ?? []) {
            guard obs.confidence >= minConfidence else { continue }
            var joints = 0
            for s in skeletons {
                let centre = CGPoint(x: s.box.midX, y: s.box.midY)
                if iou(s.box, obs.boundingBox) > 0.2 || obs.boundingBox.contains(centre) {
                    joints = max(joints, s.count)
                }
            }
            // If the Core ML pass already called this a person, keep the richer entry
            // and just fold the joint count in rather than double-reporting one figure.
            if let i = out.firstIndex(where: { $0.category == .person && iou($0.boundingBox, obs.boundingBox) > 0.35 }) {
                let e = out[i]
                out[i] = DetectedSubject(boundingBox: e.boundingBox,
                                         confidence: max(e.confidence, obs.confidence),
                                         label: e.label, category: .person, jointCount: joints)
            } else {
                out.append(DetectedSubject(boundingBox: obs.boundingBox,
                                           confidence: obs.confidence,
                                           label: "person", category: .person,
                                           jointCount: joints))
            }
        }

        // --- 3. anything coherent that nothing above could name ---
        if wantUnknownObjects,
           let sal = saliencyRequest.results?.first as? VNSaliencyImageObservation,
           let objects = sal.salientObjects {
            for o in objects where o.confidence >= max(0.4, minConfidence * 0.7) {
                let box = o.boundingBox
                guard box.width > 0.01, box.height > 0.01 else { continue }
                if out.contains(where: { iou($0.boundingBox, box) > 0.3 }) { continue }
                out.append(DetectedSubject(boundingBox: box,
                                           confidence: o.confidence,
                                           label: "movement",
                                           category: .unknown,
                                           jointCount: 0))
            }
        }

        return dedupe(out)
    }

    /// Two detectors framing the same thing should produce one subject, not two boxes.
    private func dedupe(_ subjects: [DetectedSubject]) -> [DetectedSubject] {
        var kept: [DetectedSubject] = []
        for s in subjects.sorted(by: { $0.confidence > $1.confidence }) {
            if kept.contains(where: { iou($0.boundingBox, s.boundingBox) > 0.55 }) { continue }
            kept.append(s)
        }
        return kept
    }

    private func clampAndPad(_ r: CGRect, pad: CGFloat) -> CGRect {
        let x = max(0, r.minX - pad)
        let y = max(0, r.minY - pad)
        let w = min(1 - x, r.width + pad * 2)
        let h = min(1 - y, r.height + pad * 2)
        guard w > 0.02, h > 0.02 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
    let i = inter.width * inter.height
    return i / (a.width * a.height + b.width * b.height - i)
}

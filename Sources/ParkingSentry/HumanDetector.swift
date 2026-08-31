import Vision
import CoreVideo
import CoreGraphics

/// Stage 2: confirm that whatever moved is actually a person.
///
/// This is the part that makes the app immune to shadows, blowing trash, tree
/// branches, headlight sweeps and rain. A shadow has no torso, so
/// `VNDetectHumanRectanglesRequest` will not fire on it at any confidence.
struct DetectedSubject {
    let boundingBox: CGRect      // normalized, origin bottom-left
    let confidence: Float
    let isAnimal: Bool
    let animalLabel: String?
    /// Number of body joints Vision could locate. Higher = more certainly a real person.
    let jointCount: Int
}

final class HumanDetector {
    private let humanRequest = VNDetectHumanRectanglesRequest()
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let animalRequest = VNRecognizeAnimalsRequest()

    init() {
        humanRequest.upperBodyOnly = false
        animalRequest.revision = VNRecognizeAnimalsRequestRevision2
    }

    /// - Parameters:
    ///   - roi: normalized region to search, origin bottom-left. Nil searches the whole frame.
    func detect(in pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation,
                roi: CGRect?,
                minConfidence: Float,
                checkAnimals: Bool) -> [DetectedSubject] {

        let region = roi.map { clampAndPad($0, pad: 0.12) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        humanRequest.regionOfInterest = region
        poseRequest.regionOfInterest = region
        animalRequest.regionOfInterest = region

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation,
                                            options: [:])

        var requests: [VNRequest] = [humanRequest, poseRequest]
        if checkAnimals { requests.append(animalRequest) }

        do {
            try handler.perform(requests)
        } catch {
            return []
        }

        let poses = (poseRequest.results ?? [])
        let animals = (animalRequest.results ?? [])

        var out: [DetectedSubject] = []

        for obs in (humanRequest.results ?? []) {
            guard obs.confidence >= minConfidence else { continue }

            // Count recognized joints from any pose whose box overlaps this human box.
            var joints = 0
            for pose in poses where iou(pose.boundingBox, obs.boundingBox) > 0.2 {
                if let pts = try? pose.recognizedPoints(.all) {
                    joints = max(joints, pts.values.filter { $0.confidence > 0.3 }.count)
                }
            }

            // If an animal box covers the same area with higher confidence, tag it.
            var animalLabel: String?
            for a in animals where iou(a.boundingBox, obs.boundingBox) > 0.5 {
                if a.confidence > obs.confidence,
                   let top = a.labels.first {
                    animalLabel = top.identifier
                }
            }

            out.append(DetectedSubject(boundingBox: obs.boundingBox,
                                       confidence: obs.confidence,
                                       isAnimal: animalLabel != nil,
                                       animalLabel: animalLabel,
                                       jointCount: joints))
        }

        // An animal seen with no matching human box is still worth logging as "not a person".
        if out.isEmpty, checkAnimals {
            for a in animals where a.confidence > 0.7 {
                out.append(DetectedSubject(boundingBox: a.boundingBox,
                                           confidence: a.confidence,
                                           isAnimal: true,
                                           animalLabel: a.labels.first?.identifier,
                                           jointCount: 0))
            }
        }

        return out
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

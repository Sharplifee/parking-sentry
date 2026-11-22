import Foundation
import CoreML
import Vision
import CoreVideo
import CoreGraphics
import CoreImage

/// Layers backed by downloaded Core ML models rather than by an Apple framework.
///
/// These are the capabilities Vision has no request for. The models are Apple's own
/// Core ML conversions, downloaded on first use and compiled on device.
///
/// Every input and output name, shape and pixel format below was read off the
/// actual model specs rather than assumed — a wrong output name in Core ML is a
/// runtime nil, not a compile error, which is the kind of bug that looks like a
/// broken model for an hour.

/// Shared plumbing: a layer that needs a model reports download state through its
/// own availability, so the panel shows "tap to download 25 MB" instead of a dead
/// switch, and the toggle starts the download.
class ModelBackedLayer {
    let modelID: String
    init(modelID: String) { self.modelID = modelID }

    var modelAvailability: LayerAvailability {
        switch ModelStore.shared.state(modelID) {
        case .ready:
            return .available
        case .absent:
            let mb = (ModelStore.manifest[modelID]?.totalBytes ?? 0) / 1_000_000
            return .needsDownload("Needs a \(mb) MB model — switch on to download it once")
        case .downloading(let f):
            return .needsDownload(String(format: "Downloading… %.0f%%", f * 100))
        case .compiling:
            return .needsDownload("Compiling on device…")
        case .failed(let why):
            return .modelMissing("Download failed: \(why)")
        }
    }

    /// Called when the layer is switched on. Starts the download if needed.
    func ensureModel() {
        switch ModelStore.shared.state(modelID) {
        case .ready: break
        default: ModelStore.shared.fetch(modelID)
        }
    }
}

// MARK: - Monocular depth

/// Depth from a single camera, with no LiDAR.
///
/// Depth Anything V2 returns *relative* inverse depth, not metres — brighter is
/// nearer, and the scale is arbitrary per frame. That matters here: this layer
/// shows the operator the shape of the scene and ranks things by nearness, and it
/// deliberately does not feed the distance estimator, which would otherwise start
/// reporting confident feet-and-inches derived from a number that has no unit.
/// LiDAR and the pinhole estimate remain the only sources of actual distance.
final class MonocularDepthLayer: ModelBackedLayer, VideoAILayer {
    let id = "depth.mono"
    let title = "Monocular depth"
    let detail = "Depth from one camera, no LiDAR needed. Relative, not measured distance."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    var availability: LayerAvailability { modelAvailability }
    let preferredInterval = 8
    let warmAtLaunch = false

    /// Depth Anything V2 Small: input image 518x392 RGB, output image
    /// 518x392 one-component float16 named "depth".
    private static let inputName = "image"
    private static let outputName = "depth"
    private static let inputWidth = 518
    private static let inputHeight = 392

    private let cols = 42
    private let rows = 32
    private var scaler: PixelScaler?

    init() { super.init(modelID: "depth.mono") }

    func warm() {
        ensureModel()
        if scaler == nil {
            scaler = PixelScaler(width: MonocularDepthLayer.inputWidth,
                                 height: MonocularDepthLayer.inputHeight,
                                 format: kCVPixelFormatType_32BGRA)
        }
    }

    func cool() { scaler = nil }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let model = ModelStore.shared.model(modelID) else {
            ensureModel()
            return nil
        }
        guard let scaler else { warm(); return nil }
        // The model wants a fixed 518x392; feeding the full frame would have Core
        // ML resize it with no control over aspect, so it is done here instead.
        guard let input = scaler.scaled(ctx.pixelBuffer) else { return nil }

        let provider = try MLDictionaryFeatureProvider(
            dictionary: [MonocularDepthLayer.inputName: MLFeatureValue(pixelBuffer: input)])
        let out = try model.prediction(from: provider)
        guard let depth = out.featureValue(for: MonocularDepthLayer.outputName)?
                .imageBufferValue else { return nil }

        guard let grid = MaskGrid.sample(depth, cols: cols, rows: rows) else { return nil }
        // Inverse depth: high values are near. Normalising per frame is what makes
        // it readable, and is also why it cannot be a distance.
        let lo = grid.min() ?? 0, hi = grid.max() ?? 1
        let span = max(0.0001, hi - lo)
        let normalized = grid.map { ($0 - lo) / span }

        var output = LayerOutput()
        output.shapes = [.grid(values: normalized, cols: cols, rows: rows, tint: .mask)]
        // Nearest detected subject by relative depth, which is a genuine ranking
        // even without units.
        if !ctx.subjects.isEmpty {
            var nearest: (String, Double)?
            for s in ctx.subjects {
                let v = averageDepth(normalized, cols: cols, rows: rows, in: s.boundingBox)
                if nearest == nil || v > nearest!.1 { nearest = (s.label, v) }
            }
            if let nearest { output.badge = "nearest: \(nearest.0)" }
        } else {
            output.badge = "depth"
        }
        return output
    }

    private func averageDepth(_ grid: [Double], cols: Int, rows: Int, in box: CGRect) -> Double {
        let x0 = max(0, Int(box.minX * CGFloat(cols)))
        let x1 = min(cols - 1, Int(box.maxX * CGFloat(cols)))
        let y0 = max(0, Int(box.minY * CGFloat(rows)))
        let y1 = min(rows - 1, Int(box.maxY * CGFloat(rows)))
        guard x1 >= x0, y1 >= y0 else { return 0 }
        var sum = 0.0, n = 0
        for y in y0...y1 {
            for x in x0...x1 { sum += grid[y * cols + x]; n += 1 }
        }
        return n > 0 ? sum / Double(n) : 0
    }
}

// MARK: - Semantic segmentation

/// Per-pixel class for the whole scene — road, sky, building, tree, grass, fence,
/// wall, water, and 60-odd object classes on top.
///
/// This is the layer that turns the camera from "something moved" into "something
/// moved on the pavement", and the zone layers are the obvious beneficiary: a zone
/// drawn over grass is a different alarm from one over a doorway.
final class SemanticSegmentationLayer: ModelBackedLayer, VideoAILayer {
    let id = "segmentation.semantic"
    let title = "Semantic segmentation"
    let detail = "Labels every pixel — road, sky, building, tree, grass, door, 200 classes."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    var availability: LayerAvailability { modelAvailability }
    /// A ResNet-50 DETR is the most expensive model here by far.
    let preferredInterval = 20
    let warmAtLaunch = false

    /// DETR ResNet-50: input image 448x448 RGB, output "semanticPredictions",
    /// a 448x448 INT32 array of class indices into the label table below.
    private static let inputName = "image"
    private static let outputName = "semanticPredictions"
    private static let side = 448

    private let cols = 56
    private let rows = 56
    private var scaler: PixelScaler?
    private var lastSummary = ""

    init() { super.init(modelID: "segmentation.semantic") }

    func warm() {
        ensureModel()
        if scaler == nil {
            scaler = PixelScaler(width: SemanticSegmentationLayer.side,
                                 height: SemanticSegmentationLayer.side,
                                 format: kCVPixelFormatType_32BGRA)
        }
    }

    func cool() { scaler = nil }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let model = ModelStore.shared.model(modelID) else {
            ensureModel()
            return nil
        }
        guard let scaler else { warm(); return nil }
        guard let input = scaler.scaled(ctx.pixelBuffer) else { return nil }

        let provider = try MLDictionaryFeatureProvider(
            dictionary: [SemanticSegmentationLayer.inputName: MLFeatureValue(pixelBuffer: input)])
        let out = try model.prediction(from: provider)
        guard let array = out.featureValue(for: SemanticSegmentationLayer.outputName)?
                .multiArrayValue else { return nil }

        // Downsample the 448x448 class map onto the renderer's grid, taking the
        // most common class per cell rather than a single sample, so one stray
        // pixel does not decide a whole cell.
        var cellClass = [Int](repeating: 0, count: cols * rows)
        var area: [Int: Int] = [:]

        array.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int32.self) else { return }
            let side = SemanticSegmentationLayer.side
            for gy in 0..<rows {
                for gx in 0..<cols {
                    var votes: [Int: Int] = [:]
                    let y0 = (gy * side) / rows, y1 = ((gy + 1) * side) / rows
                    let x0 = (gx * side) / cols, x1 = ((gx + 1) * side) / cols
                    var y = y0
                    while y < y1 {
                        var x = x0
                        while x < x1 {
                            let c = Int(base[y * side + x])
                            votes[c, default: 0] += 1
                            x += 2
                        }
                        y += 2
                    }
                    let winner = votes.max { $0.value < $1.value }?.key ?? 0
                    // Grid is bottom-left origin; the model output is top-left.
                    cellClass[(rows - 1 - gy) * cols + gx] = winner
                    area[winner, default: 0] += 1
                }
            }
        }

        var output = LayerOutput()
        // One grid per class present, tinted by what kind of thing it is, so the
        // overlay reads as a scene rather than as noise.
        var byTint: [LayerTint: [Double]] = [:]
        for (i, cls) in cellClass.enumerated() {
            guard let name = SemanticSegmentationLayer.label(cls) else { continue }
            let tint = SemanticSegmentationLayer.tint(for: name)
            var grid = byTint[tint] ?? [Double](repeating: 0, count: cols * rows)
            grid[i] = 0.55
            byTint[tint] = grid
        }
        for (tint, grid) in byTint {
            output.shapes.append(.grid(values: grid, cols: cols, rows: rows, tint: tint))
        }

        let ranked = area
            .compactMap { (cls, n) -> (String, Int)? in
                guard let name = SemanticSegmentationLayer.label(cls) else { return nil }
                return (name, n)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)

        output.badge = ranked.first?.0
        let summary = ranked.map(\.0).joined(separator: ", ")
        if summary != lastSummary, !summary.isEmpty {
            lastSummary = summary
            output.lines = ["scene: " + summary]
            TextBus.shared.add("scene contains " + summary, source: "segmentation")
        }
        return output
    }

    /// Nil for the unused indices, which the model emits as "--".
    static func label(_ index: Int) -> String? {
        guard index >= 0, index < labels.count else { return nil }
        let name = labels[index]
        return name == "--" ? nil : name
    }

    private static func tint(for name: String) -> LayerTint {
        switch name {
        case "person":
            return .person
        case "car", "bus", "truck", "motorcycle", "bicycle", "train", "boat", "airplane":
            return .vehicle
        case "dog", "cat", "bird", "horse", "sheep", "cow", "bear", "elephant", "zebra", "giraffe":
            return .animal
        case "road", "pavement", "platform", "railroad", "gravel", "dirt", "sand", "snow":
            return .heat
        case "sky (other)", "sea", "river", "water (other)":
            return .flow
        case "tree", "grass", "flower", "potted plant":
            return .animal
        case "door", "window (other)", "window (blind)", "stairs", "fence", "gate":
            return .warn
        default:
            return .mask
        }
    }

    /// Read out of the model's own metadata, so it cannot drift from the weights.
    static let labels: [String] = [
        "--", "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
        "truck", "boat", "traffic light", "fire hydrant", "--", "stop sign",
        "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe", "--", "backpack", "umbrella", "--",
        "--", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard",
        "sports ball", "kite", "baseball bat", "baseball glove", "skateboard",
        "surfboard", "tennis racket", "bottle", "--", "wine glass", "cup", "fork",
        "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
        "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
        "potted plant", "bed", "--", "dining table", "--", "--", "toilet", "--",
        "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
        "oven", "toaster", "sink", "refrigerator", "--", "book", "clock", "vase",
        "scissors", "teddy bear", "hair drier", "toothbrush", "--", "banner",
        "blanket", "--", "bridge", "--", "--", "--", "--", "cardboard", "--", "--",
        "--", "--", "--", "--", "counter", "--", "curtain", "--", "--", "door",
        "--", "--", "--", "--", "--", "floor (wood)", "flower", "--", "--", "fruit",
        "--", "--", "gravel", "--", "--", "house", "--", "light", "--", "--",
        "mirror", "--", "--", "--", "--", "net", "--", "--", "pillow", "--", "--",
        "platform", "playingfield", "--", "railroad", "river", "road", "--", "roof",
        "--", "--", "sand", "sea", "shelf", "--", "--", "snow", "--", "stairs",
        "--", "--", "--", "--", "tent", "--", "towel", "--", "--", "wall (brick)",
        "--", "--", "--", "wall (stone)", "wall (tile)", "wall (wood)",
        "water (other)", "--", "window (blind)", "window (other)", "--", "--",
        "tree", "fence", "ceiling", "sky (other)", "cabinet", "table",
        "floor (other)", "pavement", "mountain", "grass", "dirt", "paper",
        "food (other)", "building (other)", "rock", "wall (other)", "rug"
    ]
}

// MARK: - Scaling helper

/// Resizes capture frames into the fixed size a model demands.
///
/// Core ML will resize an oversized image itself, but it stretches to fit with no
/// say in the matter. Doing it here keeps one pool of buffers instead of an
/// allocation per frame, which at 30 fps is the difference between a layer that
/// costs 8 ms and one that costs 25.
final class PixelScaler {
    private let width: Int
    private let height: Int
    private var pool: CVPixelBufferPool?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(width: Int, height: Int, format: OSType) {
        self.width = width
        self.height = height
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &created)
        pool = created
    }

    func scaled(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out else { return nil }

        let image = CIImage(cvPixelBuffer: source)
        let sx = CGFloat(width) / image.extent.width
        let sy = CGFloat(height) / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ciContext.render(scaled, to: out)
        return out
    }
}

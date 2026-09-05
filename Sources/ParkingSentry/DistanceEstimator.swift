import AVFoundation
import CoreVideo
import CoreGraphics
import simd

enum RangeSource: String {
    case lidar = "LiDAR"
    case pinhole = "optical"
    case unavailable = "—"
}

struct RangeEstimate {
    let meters: Double?
    let source: RangeSource
    /// True when the subject is clipped by a frame edge, which makes the optical estimate unreliable.
    let truncated: Bool
}

/// Real-world size of the subject, in metres.
///
/// Only reported when the range it is derived from came from somewhere OTHER
/// than that same dimension — otherwise the answer is just the assumption fed
/// back out. A person ranged by assumed height cannot then have their height
/// "measured"; a person ranged by LiDAR can, and so can a car ranged by its
/// width. Nil means "not independently knowable right now", which is the honest
/// answer and better than echoing the input.
struct SizeEstimate {
    let heightMeters: Double?
    let widthMeters: Double?
    let derivedFrom: RangeSource
}

/// Two independent ways to answer "how far away is that".
///
/// LiDAR is a real measurement but tops out around 5 m, so it is only useful for
/// close-in confirmation. Beyond that the app falls back to a pinhole projection
/// using the camera's own intrinsic matrix, which is accurate to roughly ±10-15%
/// as long as the subject is standing and fully inside the frame.
final class DistanceEstimator {

    /// Focal length in pixels on the Y axis, pulled from the sample buffer each frame.
    var focalYPixels: Double?
    var bufferHeightPixels: Double = 1080
    var bufferWidthPixels: Double = 1920
    /// Horizontal field of view of the active capture format, used when intrinsics are withheld.
    var horizontalFOVDegrees: Double?

    func updateIntrinsics(from sampleBuffer: CMSampleBuffer, bufferWidth: Int, bufferHeight: Int) {
        bufferHeightPixels = Double(bufferHeight)
        bufferWidthPixels = Double(bufferWidth)

        if let raw = CMGetAttachment(sampleBuffer,
                                     key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                     attachmentModeOut: nil) as? Data {
            raw.withUnsafeBytes { buf in
                guard let m = buf.baseAddress?.assumingMemoryBound(to: matrix_float3x3.self) else { return }
                // column-major: columns.1.y is fy
                let fy = Double(m.pointee.columns.1.y)
                if fy > 1 { focalYPixels = fy }
            }
            if focalYPixels != nil { return }
        }

        // Pixels are square on Apple sensors, so fy computed from the horizontal FOV is valid.
        if focalYPixels == nil, let fov = horizontalFOVDegrees, fov > 1, fov < 179 {
            let half = (fov * .pi / 180) / 2
            // Buffers arrive rotated upright, so the sensor's long axis may now be vertical.
            let sensorLongAxisPixels = max(bufferWidthPixels, bufferHeightPixels)
            focalYPixels = (sensorLongAxisPixels / 2) / tan(half)
        }
    }

    /// Median depth inside the subject box, in meters. Nil when there is no depth stream
    /// or the subject is beyond LiDAR range.
    func lidarRange(depthData: AVDepthData?, box: CGRect) -> Double? {
        guard let depthData else { return nil }
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }

        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let bpr = CVPixelBufferGetBytesPerRow(map)
        let ptr = base.assumingMemoryBound(to: Float32.self)

        // Vision box is bottom-left origin; the depth map is top-left origin.
        let x0 = Int((box.minX * CGFloat(w)).rounded())
        let x1 = Int((box.maxX * CGFloat(w)).rounded())
        let y0 = Int(((1 - box.maxY) * CGFloat(h)).rounded())
        let y1 = Int(((1 - box.minY) * CGFloat(h)).rounded())
        guard x1 > x0, y1 > y0 else { return nil }

        // Sample the middle third of the box — the torso — to dodge background bleed at the edges.
        let sx0 = max(0, x0 + (x1 - x0) / 3), sx1 = min(w - 1, x1 - (x1 - x0) / 3)
        let sy0 = max(0, y0 + (y1 - y0) / 3), sy1 = min(h - 1, y1 - (y1 - y0) / 3)
        guard sx1 > sx0, sy1 > sy0 else { return nil }

        var samples: [Float] = []
        samples.reserveCapacity(256)
        let strideX = max(1, (sx1 - sx0) / 16)
        let strideY = max(1, (sy1 - sy0) / 16)
        var y = sy0
        while y <= sy1 {
            let row = ptr.advanced(by: y * bpr / MemoryLayout<Float32>.size)
            var x = sx0
            while x <= sx1 {
                let v = row[x]
                if v.isFinite, v > 0.1, v < 10.0 { samples.append(v) }
                x += strideX
            }
            y += strideY
        }
        guard samples.count >= 8 else { return nil }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    /// Range from apparent size. distance = (real size x focal length) / pixel size.
    /// Height is used for upright subjects, width for vehicles, because a vehicle's
    /// apparent height swings wildly with viewing angle while its width barely moves.
    func opticalRange(box: CGRect, metrics: SubjectMetrics) -> RangeEstimate {
        let truncated = box.minY < 0.015 || box.maxY > 0.985 || box.minX < 0.01 || box.maxX > 0.99
        guard let fy = focalYPixels, fy > 0 else {
            return RangeEstimate(meters: nil, source: .unavailable, truncated: truncated)
        }

        var d: Double?
        if let h = metrics.heightMeters {
            if truncated { return RangeEstimate(meters: nil, source: .unavailable, truncated: true) }
            let pixels = Double(box.height) * bufferHeightPixels
            if pixels > 8 { d = (h * fy) / pixels }
        } else if let w = metrics.widthMeters {
            let pixels = Double(box.width) * bufferWidthPixels
            if pixels > 8 { d = (w * fy) / pixels }
        } else {
            // No trustworthy real-world size for this class - say so rather than guess.
            return RangeEstimate(meters: nil, source: .unavailable, truncated: truncated)
        }

        guard let dist = d, dist.isFinite, dist > 0.3, dist < 400 else {
            return RangeEstimate(meters: nil, source: .unavailable, truncated: truncated)
        }
        return RangeEstimate(meters: dist, source: .pinhole, truncated: false)
    }

    /// Turn an apparent box plus a known range into real dimensions.
    /// `rangeIsIndependent` is false when the range itself was computed from one
    /// of these dimensions, in which case that dimension is suppressed.
    func size(box: CGRect, rangeMeters: Double, source: RangeSource,
              metrics: SubjectMetrics, truncated: Bool) -> SizeEstimate {
        guard let fy = focalYPixels, fy > 0, rangeMeters > 0 else {
            return SizeEstimate(heightMeters: nil, widthMeters: nil, derivedFrom: .unavailable)
        }

        // Height is meaningless when the subject runs off the top or bottom edge.
        var h: Double?
        if !truncated {
            let px = Double(box.height) * bufferHeightPixels
            if px > 8 { h = (px * rangeMeters) / fy }
        }
        var w: Double?
        let pxW = Double(box.width) * bufferWidthPixels
        if pxW > 8 { w = (pxW * rangeMeters) / fy }

        // Suppress whichever dimension the range was itself derived from.
        if source == .pinhole {
            if metrics.heightMeters != nil { h = nil }
            if metrics.widthMeters != nil { w = nil }
        }

        // Sanity bounds: anything outside these is a bad box, not a real object.
        if let hv = h, hv <= 0.05 || hv > 12 { h = nil }
        if let wv = w, wv <= 0.05 || wv > 20 { w = nil }
        return SizeEstimate(heightMeters: h, widthMeters: w, derivedFrom: source)
    }

    func estimate(box: CGRect, depthData: AVDepthData?, metrics: SubjectMetrics) -> RangeEstimate {
        if let close = lidarRange(depthData: depthData, box: box) {
            return RangeEstimate(meters: close, source: .lidar, truncated: false)
        }
        return opticalRange(box: box, metrics: metrics)
    }
}

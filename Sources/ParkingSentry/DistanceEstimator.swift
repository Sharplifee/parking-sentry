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

    /// Range from apparent height. distance = (real height x focal length) / pixel height.
    func pinholeRange(box: CGRect, subjectHeightMeters: Double) -> RangeEstimate {
        let truncated = box.minY < 0.015 || box.maxY > 0.985
        guard let fy = focalYPixels, fy > 0 else {
            return RangeEstimate(meters: nil, source: .unavailable, truncated: truncated)
        }
        let pixelHeight = Double(box.height) * bufferHeightPixels
        guard pixelHeight > 8 else {
            return RangeEstimate(meters: nil, source: .unavailable, truncated: truncated)
        }
        if truncated {
            // Feet or head cut off — the height cue is meaningless, refuse to guess.
            return RangeEstimate(meters: nil, source: .unavailable, truncated: true)
        }
        let d = (subjectHeightMeters * fy) / pixelHeight
        guard d.isFinite, d > 0.3, d < 300 else {
            return RangeEstimate(meters: nil, source: .unavailable, truncated: truncated)
        }
        return RangeEstimate(meters: d, source: .pinhole, truncated: false)
    }

    func estimate(box: CGRect, depthData: AVDepthData?, subjectHeightMeters: Double) -> RangeEstimate {
        if let close = lidarRange(depthData: depthData, box: box) {
            return RangeEstimate(meters: close, source: .lidar, truncated: false)
        }
        return pinholeRange(box: box, subjectHeightMeters: subjectHeightMeters)
    }
}

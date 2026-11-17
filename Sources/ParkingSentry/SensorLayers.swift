import Foundation
import CoreMotion
import CoreGraphics
import AVFoundation
import CoreVideo

/// Device sensors as layers. These are the cheapest of all — the hardware is already
/// sampling, so reading it costs nothing per frame.

// MARK: - IMU

/// Accelerometer and gyro. The genuinely useful thing here is not the numbers but
/// what they tell you about the footage: a camera that is being moved cannot be
/// trusted to report motion in the scene, because every pixel is moving. This layer
/// flags that condition explicitly.
final class MotionSensorLayer: VideoAILayer {
    let id = "imu"
    let title = "Device motion"
    let detail = "Accelerometer and gyro, and a warning when the camera itself is moving."
    let group = LayerGroup.sensors
    let modality = LayerModality.sensor
    var availability: LayerAvailability {
        manager.isDeviceMotionAvailable ? .available
                                        : .needsHardware("No device-motion sensor")
    }
    let preferredInterval = 3

    private let manager = CMMotionManager()
    private var running = false

    func warm() {
        guard !running, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates()
        running = true
    }

    func cool() {
        guard running else { return }
        manager.stopDeviceMotionUpdates()
        running = false
    }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let m = manager.deviceMotion else { return nil }
        let rot = m.rotationRate
        let acc = m.userAcceleration
        let spin = sqrt(rot.x * rot.x + rot.y * rot.y + rot.z * rot.z)
        let shove = sqrt(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z)

        var out = LayerOutput()
        // A horizon line derived from gravity, which is also a quick way to see the
        // device is not level on its tripod.
        let roll = atan2(m.gravity.x, -m.gravity.y)
        let halfSpan = 0.45
        let dy = CGFloat(tan(roll)) * CGFloat(halfSpan)
        out.shapes.append(.polyline([CGPoint(x: 0.5 - halfSpan, y: 0.5 - dy),
                                     CGPoint(x: 0.5 + halfSpan, y: 0.5 + dy)],
                                    tint: .neutral))

        out.badge = String(format: "%.2f rad/s", spin)
        if spin > 0.35 || shove > 0.3 {
            out.lines = ["camera is moving — scene motion readings are unreliable while it does"]
            out.shapes.append(.label("CAMERA MOVING", at: CGPoint(x: 0.5, y: 0.93), tint: .alert))
        }
        return out
    }
}

// MARK: - Depth

/// LiDAR depth as a visible layer rather than just a number feeding the ranger.
/// Only the Pro phones and recent iPads have the sensor; on everything else this
/// says so instead of substituting a guess.
final class DepthLayer: VideoAILayer {
    let id = "depth"
    let title = "Depth (LiDAR)"
    let detail = "True distance per pixel from the LiDAR scanner, nearest in red."
    let group = LayerGroup.sensors
    let modality = LayerModality.sensor
    var availability: LayerAvailability {
        DepthLayer.deviceHasDepth
            ? .available
            : .needsHardware("This camera has no depth sensor")
    }
    let preferredInterval = 2

    /// Checked once against the actual capture devices rather than against a model
    /// name table, which goes stale with every new phone.
    static let deviceHasDepth: Bool = {
        let types: [AVCaptureDevice.DeviceType] = [.builtInLiDARDepthCamera,
                                                   .builtInTrueDepthCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: .video,
                                                         position: .unspecified)
        return !discovery.devices.isEmpty
    }()

    private let cols = 24
    private let rows = 18

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard let depth = ctx.depth else { return nil }
        let converted = depth.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depth
            : depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let bpr = CVPixelBufferGetBytesPerRow(map)
        let ptr = base.assumingMemoryBound(to: Float32.self)

        var values = [Double](repeating: 0, count: cols * rows)
        var nearest = Double.greatestFiniteMagnitude
        // 5 m is the honest working ceiling for the scanner; beyond it the readings
        // are noise, so the scale stops there rather than pretending to range further.
        let ceiling = 5.0

        for gy in 0..<rows {
            for gx in 0..<cols {
                let sx = min(w - 1, (gx * w) / cols)
                // Depth map is top-left origin; the grid is bottom-left.
                let sy = min(h - 1, ((rows - 1 - gy) * h) / rows)
                let v = Double(ptr[sy * bpr / MemoryLayout<Float32>.size + sx])
                guard v.isFinite, v > 0.05, v < 20 else { continue }
                nearest = min(nearest, v)
                values[gy * cols + gx] = max(0, 1 - min(1, v / ceiling))
            }
        }

        var out = LayerOutput()
        out.shapes = [.grid(values: values, cols: cols, rows: rows, tint: .mask)]
        if nearest < .greatestFiniteMagnitude {
            out.badge = Units.distanceShort(nearest)
        }
        return out
    }
}

// MARK: - Thermal

/// No iPhone has a thermal imager and no external one speaks to a stock app without
/// its vendor's SDK, so this layer exists to say that rather than to leave the
/// question hanging. The device's own thermal state is genuinely available, and is
/// what the governor reacts to, so that is what it reports.
final class ThermalLayer: VideoAILayer {
    let id = "thermal"
    let title = "Thermal camera"
    let detail = "No thermal imager on any iPhone or iPad; shows device thermal state instead."
    let group = LayerGroup.sensors
    let modality = LayerModality.sensor
    let availability = LayerAvailability.needsHardware(
        "No iPhone or iPad has a thermal imager. An external one needs its vendor's SDK.")
    let preferredInterval = 30

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var out = LayerOutput()
        out.badge = ThermalLayer.stateName(ProcessInfo.processInfo.thermalState)
        return out
    }

    static func stateName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

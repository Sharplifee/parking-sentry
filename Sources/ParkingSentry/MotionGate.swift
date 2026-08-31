import CoreVideo
import CoreGraphics
import Foundation

/// Stage 1 of the pipeline: a cheap, always-on change detector on a 64x48 luma grid.
///
/// Its only job is to decide "is anything happening, and roughly where" so the
/// expensive Vision pass runs on a small crop instead of the whole 4K frame.
///
/// Shadow rejection happens here. A cast shadow scales a pixel's brightness by a
/// roughly constant factor while leaving its neighbourhood structure intact, so a
/// darkened pixel whose ratio to the learned background sits inside the shadow band
/// is discarded before it can contribute to the motion score. A real object usually
/// replaces the pixel outright and lands outside that band.
final class MotionGate {
    private let gw = 64
    private let gh = 48

    private var background: [Float]
    private var seeded = false

    /// Pixels dimmer than this fraction of background are too dark to be a shadow (real occlusion).
    private let shadowLow: Float = 0.38
    /// Pixels between shadowLow and shadowHigh of background are treated as shadow and ignored.
    private let shadowHigh: Float = 0.93
    /// Absolute luma delta below this is sensor noise.
    private let noiseFloor: Float = 9.0

    private let bgAlphaStatic: Float = 0.04   // learn empty scene quickly
    private let bgAlphaMoving: Float = 0.0015 // barely learn where something is moving

    struct Result {
        let score: Float                 // fraction of grid cells that genuinely changed
        let region: CGRect?              // normalized, origin bottom-left (Vision convention)
        let shadowFraction: Float        // diagnostic: how much of the change was rejected as shadow
    }

    init() {
        background = [Float](repeating: 0, count: gw * gh)
    }

    func reset() {
        seeded = false
        background = [Float](repeating: 0, count: gw * gh)
    }

    func process(pixelBuffer: CVPixelBuffer) -> Result {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return Result(score: 0, region: nil, shadowFraction: 0)
        }
        let srcW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        // Box-average downsample into the coarse grid.
        var cur = [Float](repeating: 0, count: gw * gh)
        let cellW = max(1, srcW / gw)
        let cellH = max(1, srcH / gh)
        for gy in 0..<gh {
            let y0 = (gy * srcH) / gh
            for gx in 0..<gw {
                let x0 = (gx * srcW) / gw
                var sum: Int = 0
                var n = 0
                var y = y0
                while y < min(y0 + cellH, srcH) {
                    let row = luma + y * bpr
                    var x = x0
                    while x < min(x0 + cellW, srcW) {
                        sum += Int(row[x]); n += 1
                        x += 2                      // stride 2, plenty for a gate
                    }
                    y += 2
                }
                cur[gy * gw + gx] = n > 0 ? Float(sum) / Float(n) : 0
            }
        }

        if !seeded {
            background = cur
            seeded = true
            return Result(score: 0, region: nil, shadowFraction: 0)
        }

        var changed = 0
        var shadowed = 0
        var minX = gw, maxX = -1, minY = gh, maxY = -1

        for i in 0..<(gw * gh) {
            let bg = max(background[i], 1)
            let c = cur[i]
            let delta = abs(c - bg)
            var isReal = false

            if delta > noiseFloor {
                let ratio = c / bg
                if ratio < 1.0 {
                    // Darker. Shadow if it dimmed proportionally; real if it went much darker.
                    isReal = ratio < shadowLow
                    if !isReal { shadowed += 1 }
                } else {
                    // Brighter. Headlights also do this, but Vision downstream will reject them.
                    isReal = true
                }
            }

            if isReal {
                changed += 1
                let gx = i % gw, gy = i / gw
                if gx < minX { minX = gx }
                if gx > maxX { maxX = gx }
                if gy < minY { minY = gy }
                if gy > maxY { maxY = gy }
                background[i] += (c - background[i]) * bgAlphaMoving
            } else {
                background[i] += (c - background[i]) * bgAlphaStatic
            }
        }

        let total = Float(gw * gh)
        var region: CGRect?
        if maxX >= minX && maxY >= minY {
            // Grid rows run top-down; Vision's normalized space runs bottom-up, so flip Y.
            let x = Double(minX) / Double(gw)
            let w = Double(maxX - minX + 1) / Double(gw)
            let yTop = Double(minY) / Double(gh)
            let h = Double(maxY - minY + 1) / Double(gh)
            region = CGRect(x: x, y: 1.0 - yTop - h, width: w, height: h)
        }

        return Result(score: Float(changed) / total,
                      region: region,
                      shadowFraction: changed + shadowed > 0 ? Float(shadowed) / Float(changed + shadowed) : 0)
    }

    /// Nudge the background toward the current frame wholesale — used after a lighting step change.
    func relearn() { seeded = false }

    // Unused but kept: shadowHigh documents the upper edge of the rejection band.
    var shadowBand: ClosedRange<Float> { shadowLow...shadowHigh }
}

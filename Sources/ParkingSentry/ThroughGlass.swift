import CoreVideo
import CoreGraphics
import AVFoundation
import Foundation

/// Detecting whether anyone is inside a heavily tinted vehicle.
///
/// Why this is a separate pipeline from the normal detector:
///
/// There is no infrared path. Apple puts an IR-cut filter in front of every
/// iPhone and iPad camera, so the sensor cannot see near-IR even in principle —
/// and modern ceramic window films reject 85–98% of near-IR anyway, so an IR
/// camera would be defeated by the tint even if one existed here. LiDAR is also
/// out: glass returns the beam from its own surface. Anyone promising
/// "see through tint with IR" on a stock iPhone is wrong on two counts.
///
/// What IS available: 5% VLT limo tint still passes 5% of visible light. The
/// interior is not invisible, it is roughly 20x darker than the scene the
/// camera is metering for. So the job is signal recovery, not sensing:
///
///  1. Stop the camera metering for the bright exterior — lock a long exposure
///     and high ISO so the dark side of the glass is properly exposed, which
///     blows out the surroundings and nobody cares.
///  2. Stretch what comes back. After exposure, the interior occupies a narrow
///     band of the histogram; rescaling that band to full range is what makes
///     a shape readable. That is `enhancedImage`, drawn on screen.
///  3. Amplify movement rather than trying to recognise a person. Vision will
///     not classify a torso through 5% tint, and it does not need to — the
///     question is "is anyone in there", and a person who is alive moves.
///     Tiny luminance changes inside the glass are amplified against a rolling
///     temporal baseline, which is sensitive to motion far below what the eye
///     or a classifier can see.
///
/// The enemy is reflection, not darkness. A window is a mirror of whatever is
/// brighter than its interior, and a moving reflection looks exactly like a
/// moving occupant. Two defences below: reflections move coherently across the
/// whole region while an occupant moves locally, and glare events spike the
/// whole ROI at once.
final class ThroughGlassAnalyzer {

    /// Normalized region the operator drew over the window, origin bottom-left.
    /// Moving it invalidates the learned baseline, so it resets on change.
    var region = CGRect(x: 0.22, y: 0.3, width: 0.56, height: 0.4) {
        didSet { if region != oldValue { reset() } }
    }

    /// How hard to push. Higher finds smaller movement and more false alarms.
    var gain: Double = 28

    private let gw = 48
    private let gh = 32

    /// Rolling per-cell baseline of what this window looks like when still.
    private var baseline: [Double] = []
    private var variance: [Double] = []
    private var lastZ: [Double] = []
    private var seeded = false
    private var history: [Double] = []

    /// Histogram band the interior actually occupies, refreshed every analysed
    /// frame and reused by the renderer so the picture and the numbers agree.
    private var lowBound: Double = 0
    private var highBound: Double = 255

    struct Reading {
        /// 0–1. Amplified local movement energy inside the window.
        let activity: Double
        /// True when this frame's change was one coherent shift across the
        /// whole region — a reflection sweeping past, not someone inside.
        let glare: Bool
        /// Mean brightness of the region; tells the operator whether the
        /// exposure lock is actually working on the glass.
        let exposureLevel: Double
        /// Sustained activity over several seconds, which is what should
        /// actually raise "occupied".
        let sustained: Double
        /// How many frames of history the sustained figure rests on, so the
        /// UI can say "learning" instead of "empty" on the first second.
        let samples: Int
        /// Spread of the interior's histogram band, 0–1. A band this narrow is
        /// what the stretch is working with; near zero means the exposure lock
        /// has not opened up the glass at all.
        let contrast: Double
    }

    func reset() {
        seeded = false
        baseline.removeAll()
        variance.removeAll()
        lastZ.removeAll()
        history.removeAll()
        lowBound = 0
        highBound = 255
    }

    /// Pixel bounds of the drawn window. Vision-style coords are bottom-left
    /// origin; the buffer is top-left.
    private func pixelBounds(width: Int, height: Int) -> (Int, Int, Int, Int) {
        let x0 = max(0, min(width - 1, Int(region.minX * CGFloat(width))))
        let x1 = max(x0 + 1, min(width, Int(region.maxX * CGFloat(width))))
        let y0 = max(0, min(height - 1, Int((1 - region.maxY) * CGFloat(height))))
        let y1 = max(y0 + 1, min(height, Int((1 - region.minY) * CGFloat(height))))
        return (x0, x1, y0, y1)
    }

    func analyze(pixelBuffer: CVPixelBuffer) -> Reading? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        let srcW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let (x0, x1, y0, y1) = pixelBounds(width: srcW, height: srcH)
        guard x1 - x0 > gw, y1 - y0 > gh else { return nil }

        // Sample the region into a coarse grid, averaging generously — the
        // signal here is far below the sensor noise of any single pixel, and
        // averaging is what pulls it back above the floor.
        var cur = [Double](repeating: 0, count: gw * gh)
        var total = 0.0
        for gy in 0..<gh {
            let ya = y0 + (gy * (y1 - y0)) / gh
            let yb = max(ya + 1, y0 + ((gy + 1) * (y1 - y0)) / gh)
            for gx in 0..<gw {
                let xa = x0 + (gx * (x1 - x0)) / gw
                let xb = max(xa + 1, x0 + ((gx + 1) * (x1 - x0)) / gw)
                var sum = 0, n = 0
                var y = ya
                while y < yb {
                    let row = luma + y * bpr
                    var x = xa
                    while x < xb { sum += Int(row[x]); n += 1; x += 1 }
                    y += 1
                }
                let v = n > 0 ? Double(sum) / Double(n) : 0
                cur[gy * gw + gx] = v
                total += v
            }
        }
        let mean = total / Double(gw * gh)

        // The band the interior occupies. Trimmed percentiles rather than
        // min/max so one specular highlight does not flatten the stretch.
        let sorted = cur.sorted()
        let lo = sorted[Int(Double(sorted.count) * 0.03)]
        let hi = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.97))]
        lowBound = lo
        highBound = max(lo + 2, hi)
        let contrast = (highBound - lowBound) / 255

        if !seeded {
            baseline = cur
            variance = [Double](repeating: 1, count: gw * gh)
            lastZ = [Double](repeating: 0, count: gw * gh)
            seeded = true
            return Reading(activity: 0, glare: false, exposureLevel: mean / 255,
                           sustained: 0, samples: 0, contrast: contrast)
        }

        // Per-cell deviation from baseline, normalised by that cell's own
        // noise. A cell that always flickers (a leaf, a highlight) earns a
        // high variance and stops counting; a cell that is normally dead still
        // and suddenly moves dominates. This is what lets a sub-1% luminance
        // change register as real.
        var energy = 0.0
        var signedSum = 0.0
        for i in 0..<(gw * gh) {
            let d = cur[i] - baseline[i]
            let sd = max(0.8, variance[i].squareRoot())
            let z = d / sd
            lastZ[i] = z
            energy += min(abs(z), 12)
            signedSum += z
            // Slow baseline, slower variance — the window itself barely changes.
            baseline[i] += d * 0.02
            variance[i] += (d * d - variance[i]) * 0.01
        }
        let cells = Double(gw * gh)
        let meanAbsZ = energy / cells
        let meanSignedZ = abs(signedSum) / cells

        // A reflection sweeping the glass shifts nearly every cell the same
        // direction at once. An occupant shifting in a seat moves a minority of
        // cells in both directions. The ratio separates them.
        let coherence = meanAbsZ > 0.01 ? meanSignedZ / meanAbsZ : 0
        let glare = coherence > 0.72 && meanAbsZ > 1.2

        let activity = glare ? 0 : min(1, (meanAbsZ * gain) / 100)

        history.append(activity)
        if history.count > 120 { history.removeFirst() }
        // Occupancy is a sustained story, not a frame: a person breathing and
        // shifting produces repeated small hits, while a passing shadow is one.
        let hits = history.filter { $0 > 0.15 }.count
        // Divided by a floor of sixty frames, not by however much history exists
        // yet. With two frames recorded and one of them a hit, dividing by the
        // actual count gave a sustained figure of 0.5 — over the occupancy
        // threshold — so the very first flicker after the region was drawn could
        // read as "someone is in there". Treating the frames not yet gathered as
        // non-hits means the figure climbs into the threshold over about two
        // seconds of real evidence instead.
        let window = Double(max(60, history.count))
        let sustained = Double(hits) / window

        return Reading(activity: activity, glare: glare,
                       exposureLevel: mean / 255, sustained: sustained,
                       samples: history.count, contrast: contrast)
    }

    /// The window, brightness-stretched into the visible range, with the cells
    /// that are moving tinted red. This is the picture the operator reads:
    /// a number says "activity 0.4", this shows that the activity is a shape in
    /// the driver's seat rather than a reflection crossing the whole pane.
    func enhancedImage(pixelBuffer: CVPixelBuffer, maxWidth: Int = 420) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        let srcW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let (x0, x1, y0, y1) = pixelBounds(width: srcW, height: srcH)
        let rw = x1 - x0, rh = y1 - y0
        guard rw > 16, rh > 16 else { return nil }

        let outW = min(maxWidth, rw)
        let outH = max(1, rh * outW / rw)
        let span = max(2.0, highBound - lowBound)
        let scale = 255.0 / span
        let haveHeat = lastZ.count == gw * gh

        var out = [UInt8](repeating: 255, count: outW * outH * 4)
        for oy in 0..<outH {
            let sy = y0 + (oy * rh) / outH
            let row = luma + sy * bpr
            let gy = min(gh - 1, (oy * gh) / outH)
            for ox in 0..<outW {
                let sx = x0 + (ox * rw) / outW
                let stretched = (Double(row[sx]) - lowBound) * scale
                let g = max(0, min(255, stretched))

                var heat = 0.0
                if haveHeat {
                    let gx = min(gw - 1, (ox * gw) / outW)
                    heat = max(0, min(1, (abs(lastZ[gy * gw + gx]) - 2.0) / 6.0))
                }

                let i = (oy * outW + ox) * 4
                let hot = min(255, max(0, g + heat * (255 - g)))
                let cool = min(255, max(0, g * (1 - heat * 0.65)))
                out[i]     = UInt8(hot)   // R
                out[i + 1] = UInt8(cool)  // G
                out[i + 2] = UInt8(cool)  // B
                out[i + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: outW, height: outH,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: outW * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Lock the camera to expose for the dark side of the glass instead of the
    /// bright scene around it. Auto-exposure is the single biggest reason a
    /// tinted window reads as a black rectangle — it meters the sunlit car body
    /// and crushes the interior to nothing.
    ///
    /// `frameDuration` matters: iOS clamps exposure to the active frame
    /// duration, so a 30 fps lock silently caps exposure at 1/30 s no matter
    /// what is asked for here. The caller sets the slower frame rate first and
    /// passes it in so the two agree.
    static func configureCameraForGlass(_ device: AVCaptureDevice,
                                        enabled: Bool,
                                        frameDuration: CMTime? = nil) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if enabled {
                let format = device.activeFormat
                // Long enough to collect light, short enough that a breeze on a
                // tripod does not smear the whole frame.
                var target = CMTime(value: 1, timescale: 20)
                if let fd = frameDuration, CMTimeCompare(fd, target) < 0 { target = fd }
                let duration = CMTimeMinimum(CMTimeMaximum(target, format.minExposureDuration),
                                             format.maxExposureDuration)
                let iso = min(format.maxISO, max(format.minISO, format.maxISO * 0.9))

                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    // No custom control (some front cameras): bias exposure as
                    // far toward the shadows as the device allows instead.
                    device.exposureMode = .continuousAutoExposure
                    device.setExposureTargetBias(device.maxExposureTargetBias, completionHandler: nil)
                }
                // Autofocus hunts badly on a flat dark pane; keep it continuous
                // but let the operator's framing drive it.
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = true
                }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    device.setExposureTargetBias(0, completionHandler: nil)
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        } catch {
            print("through-glass exposure lock failed: \(error.localizedDescription)")
        }
    }
}

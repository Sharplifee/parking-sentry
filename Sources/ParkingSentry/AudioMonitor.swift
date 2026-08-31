import AVFoundation
import Accelerate

/// Continuous sound-level metering, running alongside the camera.
///
/// Two jobs: report a live level so the operator can see how loud a scene is, and
/// act as a second trigger. A car door, breaking glass or a raised voice happens
/// before anything walks into frame, so a sharp transient wakes the vision pass
/// even when the picture has not changed at all.
///
/// Apple gives no calibrated SPL, only dBFS relative to full scale. The offset
/// below maps that onto an approximate dB SPL for iPhone-class mics; treat the
/// number as a good relative meter, not a certified sound-level reading.
final class AudioMonitor {

    private let engine = AVAudioEngine()
    private var running = false

    /// dBFS -> approximate dB SPL. Apple's mics clip around 120 dB SPL.
    private let splOffset: Float = 120.0

    /// Rolling background level, so "loud" means loud *for this place*.
    private var ambient: Float = 45
    private let ambientAlpha: Float = 0.02

    private(set) var currentDB: Float = 0
    private(set) var peakDB: Float = 0
    /// Set true for a moment when a transient well above ambient lands.
    private(set) var transient = false
    private var transientUntil = Date.distantPast

    /// How far above the learned ambient level counts as an event.
    var transientMarginDB: Float = 14

    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        transient = false
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = vDSP_Length(buffer.frameLength)
        guard n > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, n)
        var peak: Float = 0
        vDSP_maxmgv(ch, 1, &peak, n)

        let dbfs = 20 * log10(max(rms, 1e-7))
        let peakfs = 20 * log10(max(peak, 1e-7))
        let spl = max(0, dbfs + splOffset)
        let peakSPL = max(0, peakfs + splOffset)

        currentDB = spl
        peakDB = peakSPL

        if spl > ambient + transientMarginDB {
            transientUntil = Date().addingTimeInterval(1.5)
            // Do not let the spike itself drag the ambient estimate up.
        } else {
            ambient += (spl - ambient) * ambientAlpha
        }
        transient = Date() < transientUntil
    }

    var ambientDB: Float { ambient }
}

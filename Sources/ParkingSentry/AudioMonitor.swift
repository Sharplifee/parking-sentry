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
    ///
    /// Seeded from the first buffer rather than from a constant. Starting at a
    /// fixed 45 dB meant that anywhere genuinely louder than that — a road, a
    /// plant room, a busy shop — sat permanently above the transient margin, and
    /// because a transient deliberately suppresses learning, the estimate could
    /// never climb out of it. The trigger latched on, the Vision pass was woken on
    /// every single frame, and the battery went with it.
    private var ambient: Float?
    private let ambientAlpha: Float = 0.02
    /// Ambient still creeps during a sustained transient, far more slowly. Without
    /// this the suppression above is a trap: anything loud enough to trigger also
    /// prevents the estimate from ever catching up to it.
    private let ambientAlphaDuringTransient: Float = 0.0015

    private(set) var currentDB: Float = 0
    private(set) var peakDB: Float = 0
    /// Set true for a moment when a transient well above ambient lands.
    private(set) var transient = false
    private var transientUntil = Date.distantPast

    /// How far above the learned ambient level counts as an event.
    var transientMarginDB: Float = 14

    var isRunning: Bool { running }

    func start() throws {
        guard !running else { return }
        // The session is owned centrally; configuring it here used to clobber
        // the intercom's voice-chat mode and vice versa.
        Task { @MainActor in AudioSessionCoordinator.shared.beginMetering() }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
            self?.process(buffer)
            // The audio layers see the same buffers from the same single tap.
            // Each layer opening its own tap on the input node is not allowed by
            // AVAudioEngine anyway, and would fight this one for the session.
            LayerRegistry.shared.runAudio(buffer: buffer, at: when)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        // Guard first. Releasing the shared audio session on a stop() that was a
        // no-op could tear metering out from under whatever still had it.
        guard running else { return }
        Task { @MainActor in AudioSessionCoordinator.shared.endMetering() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        transient = false
        // Relearn on the next start: the device may have been moved somewhere
        // with a completely different noise floor.
        ambient = nil
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

        guard let current = ambient else {
            ambient = spl
            return
        }

        if spl > current + transientMarginDB {
            transientUntil = Date().addingTimeInterval(1.5)
            // The spike must not drag the estimate up at the normal rate, but it
            // cannot be allowed to freeze it either.
            ambient = current + (spl - current) * ambientAlphaDuringTransient
        } else {
            ambient = current + (spl - current) * ambientAlpha
        }
        transient = Date() < transientUntil
    }

    var ambientDB: Float { ambient ?? 0 }
}

import AVFoundation

/// One owner for the shared audio session.
///
/// Three separate files were each calling `setCategory` with different modes —
/// sound metering wanted `.measurement`, the intercom wanted `.voiceChat`, the
/// siren wanted `.playback` — and whichever ran last silently reconfigured the
/// other two. `.measurement` in particular disables the processing the intercom
/// needs, and `.playback` drops the mic entirely, so arming the detector could
/// kill push-to-talk and firing an alert could kill metering.
///
/// Everything now asks here, and the category is resolved from what is actually
/// in use rather than from whoever spoke last.
@MainActor
final class AudioSessionCoordinator {

    static let shared = AudioSessionCoordinator()

    private(set) var meteringActive = false
    private(set) var intercomActive = false

    private init() {}

    func beginMetering() { meteringActive = true; apply() }
    func endMetering() { meteringActive = false; apply() }
    func beginIntercom() { intercomActive = true; apply() }
    func endIntercom() { intercomActive = false; apply() }

    /// Alerts are transient; they play over whatever is configured rather than
    /// reconfiguring the session, so a siren can never cost us the microphone.
    func prepareForAlertPlayback() { apply() }

    private func apply() {
        let session = AVAudioSession.sharedInstance()
        do {
            if intercomActive {
                // Voice chat gets echo cancellation, which matters when the
                // watching device's speaker is near its own mic.
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetooth,
                                                  .mixWithOthers])
            } else if meteringActive {
                // Metering wants the rawest signal available, but must remain
                // playback-capable so alerts and incoming intercom still sound.
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetooth,
                                                  .mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default,
                                        options: [.mixWithOthers])
            }
            try session.setActive(true, options: [])
        } catch {
            print("audio session: \(error.localizedDescription)")
        }
    }
}

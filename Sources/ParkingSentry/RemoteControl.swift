import SwiftUI
import UIKit

/// State a peer can drive on this device.
///
/// Remote arming deliberately does NOT wake or brighten the screen. The whole
/// scenario is a device propped facing a door, screen dark, armed from a phone
/// in another room — if arming lit the display it would defeat the purpose.
@MainActor
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()

    /// Driven either by the local stealth button or by a peer command.
    @Published var stealth = false {
        didSet {
            guard stealth != oldValue else { return }
            if stealth {
                // Remember a sane value: if the screen is already at zero from a
                // previous blackout, restoring to zero later looks like a hang.
                let current = UIScreen.main.brightness
                priorBrightness = current > 0.05 ? current : 0.6
                UIScreen.main.brightness = 0
                UIApplication.shared.isIdleTimerDisabled = true
            } else {
                UIScreen.main.brightness = priorBrightness
            }
        }
    }

    private var priorBrightness: CGFloat = 0.6

    private init() {}

    func armSilently() {
        // Screen stays exactly as dark as it already was.
        DetectionEngine.shared?.start()
    }
}

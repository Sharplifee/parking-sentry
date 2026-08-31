import Foundation
import Combine

// Free functions rather than nested ones: a nested func inside init() captures
// self implicitly, which Swift rejects before all stored properties are set.
private let store = UserDefaults.standard
private func dbl(_ k: String, _ v: Double) -> Double { store.object(forKey: k) == nil ? v : store.double(forKey: k) }
private func int(_ k: String, _ v: Int) -> Int { store.object(forKey: k) == nil ? v : store.integer(forKey: k) }
private func bool(_ k: String, _ v: Bool) -> Bool { store.object(forKey: k) == nil ? v : store.bool(forKey: k) }

/// All tunables live here and persist to UserDefaults.
/// Defaults are chosen for an outdoor parking lot at dusk-to-dark, camera on a tripod.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // MARK: Camera
    @Published var useFrontCamera: Bool { didSet { d.set(useFrontCamera, forKey: "useFrontCamera") } }
    /// 1.0 = no zoom. Digital zoom above the lens's optical factor costs detection accuracy.
    @Published var zoomFactor: Double { didSet { d.set(zoomFactor, forKey: "zoomFactor") } }
    /// Capture at 4K instead of 1080p. Roughly doubles usable detection range, costs battery.
    @Published var longRangeMode: Bool { didSet { d.set(longRangeMode, forKey: "longRangeMode") } }

    // MARK: Detection
    /// Minimum Vision confidence for a human rectangle to count at all.
    @Published var personConfidence: Double { didSet { d.set(personConfidence, forKey: "personConfidence") } }
    /// Fraction of the coarse grid that must change before Vision is even woken up. Lower = twitchier.
    @Published var motionSensitivity: Double { didSet { d.set(motionSensitivity, forKey: "motionSensitivity") } }
    /// How many separate frames a track must be confirmed on before it can alert.
    @Published var confirmHits: Int { didSet { d.set(confirmHits, forKey: "confirmHits") } }
    /// Reject anything estimated farther than this. 0 = no distance filter.
    @Published var alertDistanceMeters: Double { didSet { d.set(alertDistanceMeters, forKey: "alertDistanceMeters") } }
    /// Assumed standing height of a person, used by the pinhole range estimate.
    @Published var subjectHeightMeters: Double { didSet { d.set(subjectHeightMeters, forKey: "subjectHeightMeters") } }
    /// Suppress alerts when Vision classifies the mover as a cat or dog.
    @Published var ignoreAnimals: Bool { didSet { d.set(ignoreAnimals, forKey: "ignoreAnimals") } }
    /// Also require the subject to be getting closer, not just present.
    @Published var requireApproach: Bool { didSet { d.set(requireApproach, forKey: "requireApproach") } }

    // MARK: Alerting
    @Published var sirenEnabled: Bool { didSet { d.set(sirenEnabled, forKey: "sirenEnabled") } }
    @Published var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    /// e.g. https://ntfy.sh/your-private-topic  — POSTed so a phone in your pocket buzzes.
    @Published var webhookURL: String { didSet { d.set(webhookURL, forKey: "webhookURL") } }
    @Published var cooldownSeconds: Double { didSet { d.set(cooldownSeconds, forKey: "cooldownSeconds") } }
    /// Grace period after arming so you can walk out of frame.
    @Published var armDelaySeconds: Double { didSet { d.set(armDelaySeconds, forKey: "armDelaySeconds") } }

    private init() {
        useFrontCamera       = bool("useFrontCamera", false)
        zoomFactor           = dbl("zoomFactor", 1.0)
        longRangeMode        = bool("longRangeMode", true)
        personConfidence     = dbl("personConfidence", 0.55)
        motionSensitivity    = dbl("motionSensitivity", 0.004)
        confirmHits          = int("confirmHits", 3)
        alertDistanceMeters  = dbl("alertDistanceMeters", 30.0)
        subjectHeightMeters  = dbl("subjectHeightMeters", 1.72)
        ignoreAnimals        = bool("ignoreAnimals", true)
        requireApproach      = bool("requireApproach", false)
        sirenEnabled         = bool("sirenEnabled", false)
        notificationsEnabled = bool("notificationsEnabled", true)
        webhookURL           = store.string(forKey: "webhookURL") ?? ""
        cooldownSeconds      = dbl("cooldownSeconds", 20.0)
        armDelaySeconds      = dbl("armDelaySeconds", 15.0)
    }
}

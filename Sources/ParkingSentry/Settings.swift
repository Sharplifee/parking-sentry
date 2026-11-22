import Foundation
import Combine
import CoreGraphics

// Free functions rather than nested ones: a nested func inside init() captures
// self implicitly, which Swift rejects before all stored properties are set.
private let store = UserDefaults.standard
private func dbl(_ k: String, _ v: Double) -> Double { store.object(forKey: k) == nil ? v : store.double(forKey: k) }
private func int(_ k: String, _ v: Int) -> Int { store.object(forKey: k) == nil ? v : store.integer(forKey: k) }
private func bool(_ k: String, _ v: Bool) -> Bool { store.object(forKey: k) == nil ? v : store.bool(forKey: k) }
private func str(_ k: String, _ v: String) -> String { store.string(forKey: k) ?? v }

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
    /// Show the depth sensor's view instead of the colour image. Works in the
    /// dark; short range only. iOS exposes no raw infrared image on any device,
    /// so this is the closest thing that genuinely exists.
    @Published var nightView: Bool { didSet { d.set(nightView, forKey: "nightView") } }

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
    /// Which kinds of subject are allowed to raise an alert.
    @Published var alertCategories: Set<SubjectCategory> {
        didSet { d.set(alertCategories.map(\.rawValue), forKey: "alertCategories") }
    }
    /// Let a sharp sound wake the detector even when the picture has not changed.
    @Published var soundTrigger: Bool { didSet { d.set(soundTrigger, forKey: "soundTrigger") } }
    /// Also require the subject to be getting closer, not just present.
    @Published var requireApproach: Bool { didSet { d.set(requireApproach, forKey: "requireApproach") } }

    // MARK: Alerting
    @Published var sirenEnabled: Bool { didSet { d.set(sirenEnabled, forKey: "sirenEnabled") } }
    @Published var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    /// e.g. https://ntfy.sh/your-private-topic  — POSTed so a phone in your pocket buzzes.
    @Published var webhookURL: String { didSet { d.set(webhookURL, forKey: "webhookURL") } }
    @Published var cooldownSeconds: Double { didSet { d.set(cooldownSeconds, forKey: "cooldownSeconds") } }
    // MARK: Recording
    /// Save a clip on every confirmed detection.
    @Published var recordClips: Bool { didSet { d.set(recordClips, forKey: "recordClips") } }
    /// Seconds kept from BEFORE the trigger. This is the part that shows the
    /// approach, so it matters more than the tail.
    @Published var clipPreRoll: Double { didSet { d.set(clipPreRoll, forKey: "clipPreRoll") } }
    /// Seconds recorded after the trigger.
    @Published var clipPostRoll: Double { didSet { d.set(clipPostRoll, forKey: "clipPostRoll") } }
    /// How many clips to keep before the oldest are deleted.
    @Published var clipRetention: Int { didSet { d.set(clipRetention, forKey: "clipRetention") } }

    // MARK: Layers
    /// Comma-separated words the keyword layer watches for.
    @Published var watchKeywords: String { didSet { d.set(watchKeywords, forKey: "watchKeywords") } }
    /// What the open-vocabulary layer looks for, in plain words.
    @Published var groundingQuery: String { didSet { d.set(groundingQuery, forKey: "groundingQuery") } }
    /// Seconds between model calls for the layers that use one. Each call costs
    /// money and bandwidth, so this is deliberately slow by default.
    @Published var modelCallInterval: Double { didSet { d.set(modelCallInterval, forKey: "modelCallInterval") } }

    // MARK: On-device model layers
    /// The question the answering layer asks about what the camera has seen.
    @Published var llmQuestion: String { didSet { d.set(llmQuestion, forKey: "llmQuestion") } }
    /// Comma-separated categories for zero-shot text classification.
    @Published var textCategories: String { didSet { d.set(textCategories, forKey: "textCategories") } }
    /// Phrase used to search back through indexed moments.
    @Published var retrievalQuery: String { didSet { d.set(retrievalQuery, forKey: "retrievalQuery") } }
    /// Target language code for on-device translation, empty for off.
    @Published var translationTarget: String {
        didSet { d.set(translationTarget, forKey: "translationTarget") }
    }

    // MARK: Privacy layers
    /// "faces", "people" or "both" — what the blur layer covers.
    @Published var privacyBlurTarget: String {
        didSet { d.set(privacyBlurTarget, forKey: "privacyBlurTarget") }
    }
    /// Carry the redaction into recordings and the peer stream, not just the
    /// preview, so a blurred face never leaves the device.
    @Published var blurRecordings: Bool { didSet { d.set(blurRecordings, forKey: "blurRecordings") } }
    /// Fixed areas blanked out regardless of what is in them.
    @Published var redactionRegions: [CGRect] {
        didSet {
            if let data = try? JSONEncoder().encode(redactionRegions) {
                d.set(data, forKey: "redactionRegions")
            }
        }
    }

    // MARK: Through-glass occupancy
    /// Look inside a heavily tinted vehicle instead of watching the scene.
    /// Replaces the person/vehicle pipeline while it is on: the camera locks a
    /// long exposure for the dark side of the glass, and the question becomes
    /// "is anything moving in there", not "what is that".
    @Published var glassMode: Bool { didSet { d.set(glassMode, forKey: "glassMode") } }
    /// Amplification. Higher sees smaller movement and more reflections.
    @Published var glassGain: Double { didSet { d.set(glassGain, forKey: "glassGain") } }
    /// The window, normalized, origin bottom-left. Drawn by dragging on screen.
    @Published var glassRegion: CGRect {
        didSet {
            d.set(glassRegion.minX, forKey: "glassRegionX")
            d.set(glassRegion.minY, forKey: "glassRegionY")
            d.set(glassRegion.width, forKey: "glassRegionW")
            d.set(glassRegion.height, forKey: "glassRegionH")
        }
    }
    /// Sustained-activity fraction that counts as occupied.
    @Published var glassOccupiedThreshold: Double {
        didSet { d.set(glassOccupiedThreshold, forKey: "glassOccupiedThreshold") }
    }

    /// Grace period after arming so you can walk out of frame.
    @Published var armDelaySeconds: Double { didSet { d.set(armDelaySeconds, forKey: "armDelaySeconds") } }
    /// Feet and miles per hour by default; metric is opt-in.
    @Published var useMetric: Bool {
        didSet { d.set(useMetric, forKey: "useMetric"); Units.useMetric = useMetric }
    }

    private init() {
        useFrontCamera       = bool("useFrontCamera", false)
        zoomFactor           = dbl("zoomFactor", 1.0)
        longRangeMode        = bool("longRangeMode", false)
        nightView            = bool("nightView", false)
        personConfidence     = dbl("personConfidence", 0.55)
        motionSensitivity    = dbl("motionSensitivity", 0.004)
        confirmHits          = int("confirmHits", 3)
        alertDistanceMeters  = dbl("alertDistanceMeters", 30.0)
        subjectHeightMeters  = dbl("subjectHeightMeters", 1.72)
        if let raw = store.stringArray(forKey: "alertCategories") {
            alertCategories = Set(raw.compactMap(SubjectCategory.init(rawValue:)))
        } else {
            alertCategories = [.person, .vehicle]
        }
        requireApproach      = bool("requireApproach", false)
        soundTrigger         = bool("soundTrigger", true)
        sirenEnabled         = bool("sirenEnabled", false)
        notificationsEnabled = bool("notificationsEnabled", true)
        webhookURL           = store.string(forKey: "webhookURL") ?? ""
        cooldownSeconds      = dbl("cooldownSeconds", 20.0)
        // 15 s was far too long to stand around for; 5 is enough to set a device
        // down and step away, and the dial goes to zero for immediate arming.
        armDelaySeconds      = dbl("armDelaySeconds", 5.0)
        useMetric            = bool("useMetric", false)
        recordClips          = bool("recordClips", true)
        clipPreRoll          = dbl("clipPreRoll", 6.0)
        clipPostRoll         = dbl("clipPostRoll", 8.0)
        clipRetention        = int("clipRetention", 200)
        llmQuestion          = str("llmQuestion", "")
        retrievalQuery       = str("retrievalQuery", "")
        textCategories       = str("textCategories", "")
        translationTarget    = str("translationTarget", "")
        watchKeywords        = str("watchKeywords", "")
        groundingQuery       = str("groundingQuery", "")
        modelCallInterval    = dbl("modelCallInterval", 30)
        privacyBlurTarget    = str("privacyBlurTarget", "faces")
        blurRecordings       = bool("blurRecordings", true)
        redactionRegions     = (d.data(forKey: "redactionRegions")
            .flatMap { try? JSONDecoder().decode([CGRect].self, from: $0) }) ?? []
        glassMode            = bool("glassMode", false)
        glassGain            = dbl("glassGain", 28)
        glassOccupiedThreshold = dbl("glassOccupiedThreshold", 0.30)
        glassRegion = CGRect(x: dbl("glassRegionX", 0.22),
                             y: dbl("glassRegionY", 0.30),
                             width: dbl("glassRegionW", 0.56),
                             height: dbl("glassRegionH", 0.40))
    }
}

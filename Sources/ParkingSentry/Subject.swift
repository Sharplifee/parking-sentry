import CoreGraphics
import Foundation

/// What kind of thing was detected. Alerting is filtered per category.
enum SubjectCategory: String, CaseIterable, Codable {
    case person
    case vehicle
    case animal
    case object      // a recognised class that is none of the above (backpack, suitcase, bag...)
    case unknown     // something moved and held together, but no classifier named it

    var display: String {
        switch self {
        case .person: return "People"
        case .vehicle: return "Vehicles"
        case .animal: return "Animals"
        case .object: return "Objects"
        case .unknown: return "Unidentified movement"
        }
    }

    var settingsKey: String { "alert_" + rawValue }
}

/// Typical real-world size of a class, used to turn apparent pixel size into range.
/// Height is used for upright things, width for vehicles, because a car's height is
/// far more variable in frame (parked, angled, partially occluded) than its width.
struct SubjectMetrics {
    let heightMeters: Double?
    let widthMeters: Double?
}

enum COCOClass {
    static let vehicles: Set<String> = [
        "car", "truck", "bus", "motorbike", "motorcycle", "bicycle",
        "train", "aeroplane", "airplane", "boat"
    ]
    static let animals: Set<String> = [
        "dog", "cat", "bird", "horse", "sheep", "cow", "elephant",
        "bear", "zebra", "giraffe"
    ]

    static func category(for label: String) -> SubjectCategory {
        let l = label.lowercased()
        if l == "person" { return .person }
        if vehicles.contains(l) { return .vehicle }
        if animals.contains(l) { return .animal }
        return .object
    }

    /// Only classes with a genuinely predictable size get a range estimate.
    /// Anything absent from this table reports range unknown rather than a made-up number.
    static func metrics(for label: String, personHeight: Double) -> SubjectMetrics {
        switch label.lowercased() {
        case "person":            return SubjectMetrics(heightMeters: personHeight, widthMeters: nil)
        case "car":               return SubjectMetrics(heightMeters: nil, widthMeters: 1.80)
        case "truck":             return SubjectMetrics(heightMeters: nil, widthMeters: 2.40)
        case "bus":               return SubjectMetrics(heightMeters: nil, widthMeters: 2.55)
        case "motorbike", "motorcycle": return SubjectMetrics(heightMeters: 1.30, widthMeters: nil)
        case "bicycle":           return SubjectMetrics(heightMeters: 1.10, widthMeters: nil)
        case "dog":               return SubjectMetrics(heightMeters: 0.55, widthMeters: nil)
        case "cat":               return SubjectMetrics(heightMeters: 0.30, widthMeters: nil)
        default:                  return SubjectMetrics(heightMeters: nil, widthMeters: nil)
        }
    }
}

struct DetectedSubject {
    let boundingBox: CGRect      // normalized, origin bottom-left
    let confidence: Float
    let label: String
    let category: SubjectCategory
    /// Body joints Vision could locate, for people only. Higher = more certainly a real person.
    let jointCount: Int
}

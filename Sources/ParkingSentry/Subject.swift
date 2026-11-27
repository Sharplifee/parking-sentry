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

    /// Turns a model's own class name into something a person would say.
    ///
    /// The detector's vocabulary is the COCO and PASCAL VOC class list, whose
    /// names were written for training scripts, not for people: "tvmonitor",
    /// "pottedplant", "diningtable", "aeroplane". Those were going straight onto
    /// the screen over the camera. Anything not in this table is already an
    /// ordinary word — "car", "dog", "person" — and only needs its first letter,
    /// so the table lists the exceptions rather than all eighty classes.
    static func readable(_ label: String) -> String {
        let l = label.lowercased()
        if let fixed = names[l] { return fixed }
        // Multi-word class names arrive joined or underscored.
        let spaced = l.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static let names: [String: String] = [
        "tvmonitor": "TV screen",
        "tv": "TV screen",
        "pottedplant": "Potted plant",
        "diningtable": "Dining table",
        "aeroplane": "Aeroplane",
        "motorbike": "Motorbike",
        "sofa": "Sofa",
        "cell phone": "Phone",
        "cellphone": "Phone",
        "mobile phone": "Phone",
        "remote": "Remote control",
        "laptop": "Laptop",
        "keyboard": "Keyboard",
        "mouse": "Mouse",
        "wine glass": "Wine glass",
        "sports ball": "Ball",
        "baseball bat": "Baseball bat",
        "baseball glove": "Baseball glove",
        "tennis racket": "Tennis racket",
        "hair drier": "Hairdryer",
        "teddy bear": "Teddy bear",
        "traffic light": "Traffic light",
        "fire hydrant": "Fire hydrant",
        "stop sign": "Stop sign",
        "parking meter": "Parking meter",
        "potted plant": "Potted plant",
        "dining table": "Dining table",
        "toilet": "Toilet",
        "tooth brush": "Toothbrush",
        "toothbrush": "Toothbrush",
        "hot dog": "Hot dog",
        "donut": "Doughnut",
        "backpack": "Backpack",
        "handbag": "Handbag",
        "suitcase": "Suitcase",
        "skis": "Skis",
        "snowboard": "Snowboard",
        "surfboard": "Surfboard",
        "skateboard": "Skateboard",
        "person": "Person",
        "bicycle": "Bicycle",
        "motorcycle": "Motorbike",
        "airplane": "Aeroplane"
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

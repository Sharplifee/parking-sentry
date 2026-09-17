import Foundation

/// Everything is computed in metres internally — the camera maths is metric —
/// and shown in US customary. Connor reads distances in feet, heights in feet
/// and inches, speed in mph.
enum Units {

    /// Distance to a subject. Feet up to 1000, miles beyond that.
    static func distance(_ meters: Double) -> String {
        let feet = meters * 3.280839895
        if feet >= 1000 {
            return String(format: "%.2f mi", feet / 5280)
        }
        return String(format: "%.0f ft", feet)
    }

    /// Short form for overlay labels where space is tight.
    static func distanceShort(_ meters: Double) -> String {
        let feet = meters * 3.280839895
        if feet >= 1000 { return String(format: "%.1fmi", feet / 5280) }
        return String(format: "%.0fft", feet)
    }

    /// A person or object's height, as feet and inches — 5'11", not 1.8 m.
    static func height(_ meters: Double) -> String {
        let totalInches = (meters * 39.3700787).rounded()
        let feet = Int(totalInches) / 12
        let inches = Int(totalInches) % 12
        return "\(feet)'\(inches)\""
    }

    static func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.0f mph", metersPerSecond * 2.23694)
    }

    // MARK: Settings entry

    static func feetToMeters(_ feet: Double) -> Double { feet / 3.280839895 }
    static func metersToFeet(_ meters: Double) -> Double { meters * 3.280839895 }

    /// Slider label for a distance setting held in metres but chosen in feet.
    static func distanceSetting(_ meters: Double) -> String {
        meters == 0 ? "any distance" : distance(meters)
    }
}

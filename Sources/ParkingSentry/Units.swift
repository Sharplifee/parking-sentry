import Foundation

/// Everything on screen is US customary. Ranges and sizes are computed in metres
/// internally because the camera maths is metric, and converted only at the edge
/// where a human reads it — so there is exactly one place to get this right.
enum Units {

    static let feetPerMeter = 3.280839895
    static let mphPerMPS = 2.2369362920544

    static func feet(_ meters: Double) -> Double { meters * feetPerMeter }

    /// Distance to a subject. Feet up to ~1000 ft, then miles, because "3,400 ft
    /// away" is not how anyone describes a distance that size.
    static func distance(_ meters: Double) -> String {
        let ft = feet(meters)
        if ft < 1000 {
            return String(format: "%.0f ft", ft)
        }
        return String(format: "%.2f mi", ft / 5280)
    }

    /// Compact form for an overlay label where space is tight.
    static func distanceShort(_ meters: Double) -> String {
        let ft = feet(meters)
        if ft < 1000 { return String(format: "%.0fft", ft) }
        return String(format: "%.1fmi", ft / 5280)
    }

    /// Heights read as feet and inches — 5'11", not 1.8 m.
    static func height(_ meters: Double) -> String {
        let totalInches = (meters * feetPerMeter * 12).rounded()
        let f = Int(totalInches) / 12
        let i = Int(totalInches) % 12
        return "\(f)'\(i)\""
    }

    static func speedMPH(_ metersPerSecond: Double) -> Double {
        metersPerSecond * mphPerMPS
    }

    static func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.0f mph", speedMPH(metersPerSecond))
    }

    /// For settings sliders that store metres but are operated in feet.
    static func metersFromFeet(_ ft: Double) -> Double { ft / feetPerMeter }
}

import Foundation

/// Everything the app shows is US customary. Ranges and sizes are computed in
/// metres because the camera maths is metric, but nothing metric is ever shown.
enum Units {

    /// US customary by default; metric is opt-in from Settings. Mirrored here so
    /// the formatters can be called from anywhere without threading Settings
    /// through every call site.
    static var useMetric: Bool = UserDefaults.standard.bool(forKey: "useMetric")

    /// Distance: feet up to ~1000 ft, then miles.
    static func distance(_ meters: Double) -> String {
        if useMetric {
            return meters < 1000 ? String(format: "%.0f m", meters)
                                 : String(format: "%.2f km", meters / 1000)
        }
        let feet = meters * 3.28084
        if feet < 1000 { return String(format: "%.0f ft", feet) }
        return String(format: "%.2f mi", meters / 1609.344)
    }

    /// Short form for tight labels on video tiles.
    static func distanceShort(_ meters: Double) -> String {
        if useMetric { return String(format: "%.0fm", meters) }
        let feet = meters * 3.28084
        if feet < 1000 { return String(format: "%.0f'", feet) }
        return String(format: "%.1fmi", meters / 1609.344)
    }

    /// Heights read as feet and inches — "6'1\"", not "1.85 m".
    static func height(_ meters: Double) -> String {
        if useMetric { return String(format: "%.2f m", meters) }
        let totalInches = (meters * 39.3701).rounded()
        let feet = Int(totalInches) / 12
        let inches = Int(totalInches) % 12
        return "\(feet)'\(inches)\""
    }

    static func speed(_ metersPerSecond: Double) -> String {
        useMetric ? String(format: "%.0f km/h", metersPerSecond * 3.6)
                  : String(format: "%.0f mph", metersPerSecond * 2.23694)
    }

    // MARK: Settings round-trips

    static func feetToMeters(_ feet: Double) -> Double { feet / 3.28084 }
    static func metersToFeet(_ meters: Double) -> Double { meters * 3.28084 }
    static func inchesToMeters(_ inches: Double) -> Double { inches / 39.3701 }
    static func metersToInches(_ meters: Double) -> Double { meters * 39.3701 }
}

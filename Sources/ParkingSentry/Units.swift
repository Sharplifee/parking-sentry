import Foundation

/// US customary throughout: feet for distance, switching to miles past ~1000 ft,
/// feet-and-inches for heights, mph for speed. The detection maths runs in
/// metres because the camera intrinsics are metric; only display converts.
enum Units {

    static func distance(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet >= 1000 {
            return String(format: "%.1f mi", feet / 5280)
        }
        return String(format: "%.0f ft", feet)
    }

    /// Short form for cramped places like an overlay label.
    static func distanceShort(_ meters: Double) -> String {
        let feet = meters * 3.28084
        return feet >= 1000 ? String(format: "%.1fmi", feet / 5280)
                            : String(format: "%.0fft", feet)
    }

    /// Heights read naturally as feet and inches — "6 ft 1 in", not "1.85 m".
    static func height(_ meters: Double) -> String {
        let totalInches = (meters * 39.3701).rounded()
        let ft = Int(totalInches) / 12
        let inch = Int(totalInches) % 12
        return inch == 0 ? "\(ft) ft" : "\(ft) ft \(inch) in"
    }

    static func heightShort(_ meters: Double) -> String {
        let totalInches = (meters * 39.3701).rounded()
        return "\(Int(totalInches) / 12)'\(Int(totalInches) % 12)\""
    }

    static func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.0f mph", metersPerSecond * 2.23694)
    }

    // Settings sliders are stored in metres; these convert at the edges.
    static func metersFromFeet(_ feet: Double) -> Double { feet / 3.28084 }
    static func feetFromMeters(_ meters: Double) -> Double { meters * 3.28084 }
}

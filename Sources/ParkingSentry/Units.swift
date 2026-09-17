import Foundation

/// Everything internal is metric because the camera maths is metric. Everything
/// shown to the operator is US customary, because that is what he reads a lot in.
enum Units {

    /// Distance: feet up close, miles once feet stop being useful.
    static func distance(_ meters: Double) -> String {
        let feet = meters * 3.280839895
        if feet >= 1000 {
            return String(format: "%.2f mi", feet / 5280)
        }
        return String(format: "%.0f ft", feet)
    }

    /// Height of a subject: feet and inches, the way a person is described.
    static func height(_ meters: Double) -> String {
        let totalInches = (meters * 39.3700787).rounded()
        var feet = Int(totalInches) / 12
        var inches = Int(totalInches) % 12
        if inches == 12 { feet += 1; inches = 0 }
        return "\(feet)'\(inches)\""
    }

    /// Speed in mph, given metres per second.
    static func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.0f mph", metersPerSecond * 2.2369363)
    }

    static func feet(fromMeters m: Double) -> Double { m * 3.280839895 }
    static func meters(fromFeet f: Double) -> Double { f / 3.280839895 }
    static func inches(fromMeters m: Double) -> Double { m * 39.3700787 }
    static func meters(fromInches i: Double) -> Double { i / 39.3700787 }
}

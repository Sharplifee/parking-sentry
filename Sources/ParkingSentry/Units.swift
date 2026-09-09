import Foundation

/// Every distance, height and speed the app shows goes through here.
/// Defaults to US customary — feet and miles per hour — because that is what
/// gets read on the screen; metric stays available for anyone who wants it.
enum Units {
    static var useMetric: Bool {
        get { UserDefaults.standard.bool(forKey: "useMetric") }
        set { UserDefaults.standard.set(newValue, forKey: "useMetric") }
    }

    /// Range or height. Metres in, display string out.
    static func distance(_ meters: Double) -> String {
        if useMetric { return String(format: "%.0f m", meters) }
        let feet = meters * 3.28084
        return feet < 1000 ? String(format: "%.0f ft", feet)
                           : String(format: "%.2f mi", feet / 5280)
    }

    /// Subject height, where inches matter more than they do for range.
    static func height(_ meters: Double) -> String {
        if useMetric { return String(format: "%.1f m", meters) }
        let totalInches = meters * 39.3701
        let ft = Int(totalInches / 12)
        let inch = Int(totalInches.truncatingRemainder(dividingBy: 12).rounded())
        return inch == 12 ? "\(ft + 1)'0\"" : "\(ft)'\(inch)\""
    }

    /// Speed. Metres per second in.
    static func speed(_ mps: Double) -> String {
        useMetric ? String(format: "%.0f km/h", mps * 3.6)
                  : String(format: "%.0f mph", mps * 2.23694)
    }

    /// Label for the assumed-person-height slider.
    static func heightSetting(_ meters: Double) -> String { height(meters) }
}

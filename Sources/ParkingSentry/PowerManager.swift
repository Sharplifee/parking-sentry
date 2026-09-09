import Foundation
import UIKit
import Combine

/// Decides how hard the app is allowed to work.
///
/// A sentry app runs for hours on a propped-up device, so the defaults matter
/// far more than the peak capability. Everything expensive — capture rate,
/// resolution, how often Vision runs, how often frames are encoded for the wall
/// and for clips — is scaled from here, and pulled back automatically when the
/// device gets hot, the battery gets low, or Low Power Mode is on.
@MainActor
final class PowerManager: ObservableObject {

    static let shared = PowerManager()

    enum Budget: String {
        case full        // plugged in or plenty of headroom
        case normal      // the everyday case
        case reduced     // warm, low battery, or Low Power Mode
        case minimal     // hot enough that the OS is about to throttle us
    }

    @Published private(set) var budget: Budget = .normal
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var charging = false
    @Published private(set) var lowPowerMode = false

    /// Someone is actually looking at a live feed. Worth spending more on.
    @Published var beingWatched = false { didSet { recompute() } }

    private var observers: [NSObjectProtocol] = []
    var onChange: ((Budget) -> Void)?

    /// Snapshots readable from any queue — the capture path cannot hop to the
    /// main actor for every frame.
    nonisolated(unsafe) private(set) static var captureFPSSnapshot = 15
    nonisolated(unsafe) private(set) static var visionIntervalSnapshot: TimeInterval = 0.14
    nonisolated(unsafe) private(set) static var peerFPSSnapshot: Double = 10
    nonisolated(unsafe) private(set) static var clipFPSSnapshot: Double = 12
    nonisolated(unsafe) private(set) static var allowHighResSnapshot = false

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let c = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification,
                     .NSProcessInfoPowerStateDidChange,
                     UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification] {
            observers.append(c.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in PowerManager.shared.recompute() }
            })
        }
        recompute()
    }

    private func recompute() {
        thermal = ProcessInfo.processInfo.thermalState
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        batteryLevel = UIDevice.current.batteryLevel
        charging = UIDevice.current.batteryState == .charging
            || UIDevice.current.batteryState == .full

        let old = budget
        switch thermal {
        case .critical:
            budget = .minimal
        case .serious:
            budget = .reduced
        default:
            if lowPowerMode || (batteryLevel >= 0 && batteryLevel < 0.15 && !charging) {
                budget = .reduced
            } else if charging || beingWatched {
                budget = .full
            } else {
                budget = .normal
            }
        }
        Self.captureFPSSnapshot = captureFPS
        Self.visionIntervalSnapshot = visionInterval
        Self.peerFPSSnapshot = peerFPS
        Self.clipFPSSnapshot = clipFPS
        if budget != old { onChange?(budget) }
    }

    // MARK: What each budget actually costs

    /// Frames per second to pull off the sensor. The single biggest lever:
    /// everything downstream is per-frame, so halving this halves the ISP, the
    /// GPU work and every encode. Detection does not need 30 — Vision is rate
    /// limited well below that anyway.
    var captureFPS: Int {
        switch budget {
        case .full: return beingWatched ? 24 : 20
        case .normal: return 15
        case .reduced: return 10
        case .minimal: return 6
        }
    }

    /// Cap on how often the Vision pass may run, in seconds between runs.
    var visionInterval: TimeInterval {
        switch budget {
        case .full: return 0.10
        case .normal: return 0.14
        case .reduced: return 0.30
        case .minimal: return 0.60
        }
    }

    /// Frames per second pushed to other devices.
    var peerFPS: Double {
        switch budget {
        case .full: return 12
        case .normal: return 10
        case .reduced: return 6
        case .minimal: return 3
        }
    }

    /// Frames per second retained for clip pre-roll.
    var clipFPS: Double {
        switch budget {
        case .full, .normal: return 12
        case .reduced: return 8
        case .minimal: return 5
        }
    }

    /// 4K is a large, sustained power cost. Allow it only when the user asked
    /// for it AND the device is in a state to sustain it.
    func allowsHighResolution(userWants: Bool) -> Bool {
        guard userWants else { return false }
        switch budget {
        case .full, .normal: return true
        case .reduced, .minimal: return false
        }
    }

    func allowsHighResolutionSync(userWants: Bool) -> Bool { allowsHighResolution(userWants: userWants) }
    var captureFPSSync: Int { captureFPS }
    var visionIntervalSync: TimeInterval { visionInterval }

    /// Plain-language line for the telemetry row.
    var summary: String {
        var parts = [budget.rawValue]
        if lowPowerMode { parts.append("low-power") }
        if thermal == .serious || thermal == .critical { parts.append("hot") }
        if batteryLevel >= 0 { parts.append("\(Int(batteryLevel * 100))%") }
        return parts.joined(separator: " · ")
    }
}

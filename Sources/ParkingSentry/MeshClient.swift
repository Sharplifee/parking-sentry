import Foundation
import UIKit
import Combine

/// Talks to the MotionSentry relay on sharp-cloud-01.
///
/// Deliberately not a Supabase client. The project's anon key can read every table
/// in that database, so putting it in a shipped binary would expose far more than
/// this app's own data. The relay holds the service key and is scoped to the two
/// sentry_* tables, so the token below grants access to detections and nothing else.
final class MeshClient: ObservableObject {

    static let shared = MeshClient()

    private let base = URL(string: "https://207-148-6-194.sslip.io/mesh/174b19ff555f6533f9aa3ede7b7d924e")!
    private let token = "ms_JN3zs1Hhc9spYSX_3HAz0_HMXe5ANI__Iqe9DFJAWsY"

    @Published var devices: [MeshDevice] = []
    @Published var feed: [MeshEvent] = []
    @Published var online = false
    @Published var lastError: String?

    private var heartbeatTimer: Timer?
    private var pollTimer: Timer?
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        // The relay is optional history, not a dependency: keep the timeout
        // short so a box that is off or unreachable never stalls anything.
        cfg.timeoutIntervalForRequest = 6
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    // MARK: Identity

    /// Stable per-install id. Survives relaunch, dies with the app, which is what we want:
    /// a reinstalled node should not inherit an old node's history.
    static var deviceKey: String {
        let k = "meshDeviceKey"
        if let existing = UserDefaults.standard.string(forKey: k) { return existing }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: k)
        return made
    }

    static var defaultName: String {
        UIDevice.current.name
    }

    var deviceName: String {
        get { UserDefaults.standard.string(forKey: "meshDeviceName") ?? MeshClient.defaultName }
        set { UserDefaults.standard.set(newValue, forKey: "meshDeviceName") }
    }

    // MARK: Requests

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         completion: ((Data?) -> Void)? = nil) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    self?.online = false
                    self?.lastError = error.localizedDescription
                } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self?.online = false
                    self?.lastError = "relay \(http.statusCode)"
                } else {
                    self?.online = true
                    self?.lastError = nil
                }
                completion?(data)
            }
        }.resume()
    }

    // MARK: Lifecycle

    func register(hasLiDAR: Bool, hasTrueDepth: Bool) {
        let body: [String: Any] = [
            "device_key": MeshClient.deviceKey,
            "name": deviceName,
            "model": UIDevice.current.model,
            "platform": UIDevice.current.systemName.lowercased(),
            "has_lidar": hasLiDAR,
            "has_truedepth": hasTrueDepth
        ]
        request("POST", "register", body: body)
        startTimers()
    }

    func heartbeat(armed: Bool, soundDB: Float, ambientDB: Float) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var body: [String: Any] = [
            "device_key": MeshClient.deviceKey,
            "name": deviceName,
            "is_armed": armed,
            "sound_db": Double(soundDB),
            "ambient_db": Double(ambientDB),
            "last_seen": ISO8601DateFormatter().string(from: Date())
        ]
        let level = UIDevice.current.batteryLevel
        if level >= 0 { body["battery"] = Double(level) }
        request("POST", "heartbeat", body: body)
    }

    func post(event: MeshEventDraft) {
        var body: [String: Any] = [
            "device_key": MeshClient.deviceKey,
            "device_name": deviceName,
            "label": event.label,
            "category": event.category,
            "confidence": Double(event.confidence)
        ]
        if let r = event.rangeMeters { body["range_m"] = r }
        if let s = event.rangeSource { body["range_source"] = s }
        if let sp = event.speedMPH { body["speed_mph"] = sp }
        if let c = event.closing { body["closing"] = c }
        if let db = event.soundDB { body["sound_db"] = Double(db) }
        request("POST", "event", body: body)
    }

    // MARK: Polling

    private func startTimers() {
        heartbeatTimer?.invalidate()
        pollTimer?.invalidate()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopTimers() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        pollTimer?.invalidate(); pollTimer = nil
    }

    func refresh() {
        request("GET", "devices") { [weak self] data in
            guard let data,
                  let rows = try? JSONDecoder.mesh.decode([MeshDevice].self, from: data) else { return }
            self?.devices = rows
        }
        request("GET", "events") { [weak self] data in
            guard let data,
                  let rows = try? JSONDecoder.mesh.decode([MeshEvent].self, from: data) else { return }
            self?.feed = rows
        }
    }
}

// MARK: - Wire types

struct MeshEventDraft {
    let label: String
    let category: String
    let confidence: Float
    let rangeMeters: Double?
    let rangeSource: String?
    let speedMPH: Double?
    let closing: Bool?
    let soundDB: Float?
}

struct MeshDevice: Identifiable, Decodable {
    let id: String
    let deviceKey: String
    let name: String
    let platform: String?
    let isArmed: Bool
    let hasLidar: Bool
    let hasTruedepth: Bool
    let battery: Double?
    let soundDb: Double?
    let ambientDb: Double?
    let lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, platform, battery
        case deviceKey = "device_key"
        case isArmed = "is_armed"
        case hasLidar = "has_lidar"
        case hasTruedepth = "has_truedepth"
        case soundDb = "sound_db"
        case ambientDb = "ambient_db"
        case lastSeen = "last_seen"
    }

    /// A node that has not checked in for half a minute is not watching anything.
    var isLive: Bool {
        guard let lastSeen else { return false }
        return Date().timeIntervalSince(lastSeen) < 30
    }
}

struct MeshEvent: Identifiable, Decodable {
    let id: Int
    let deviceName: String
    let occurredAt: Date?
    let label: String
    let category: String
    let confidence: Double?
    let rangeM: Double?
    let rangeSource: String?
    let speedMph: Double?
    let closing: Bool?
    let soundDb: Double?

    enum CodingKeys: String, CodingKey {
        case id, label, category, confidence, closing
        case deviceName = "device_name"
        case occurredAt = "occurred_at"
        case rangeM = "range_m"
        case rangeSource = "range_source"
        case speedMph = "speed_mph"
        case soundDb = "sound_db"
    }

    var summary: String {
        var parts: [String] = [label.capitalized]
        if let r = rangeM { parts.append(String(format: "%.0f m", r)) }
        if let s = speedMph, s > 0.3 { parts.append(String(format: "%.0f mph", s)) }
        if closing == true { parts.append("closing") }
        if let db = soundDb { parts.append(String(format: "%.0f dB", db)) }
        return parts.joined(separator: " · ")
    }
}

extension JSONDecoder {
    /// Postgres timestamptz comes back with variable fractional-second precision,
    /// which the stock ISO8601 strategy rejects outright.
    static let mesh: JSONDecoder = {
        let d = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "bad date \(s)"))
        }
        return d
    }()
}

import Foundation
import CoreGraphics
import Combine

/// Zones and counting lines the operator draws on the feed, persisted between runs.
///
/// Kept out of Settings because these are geometry the user draws rather than
/// preferences they set, and because the analytics layers all read from one place.
/// Everything is normalized with a bottom-left origin, matching every other
/// coordinate in the layer system.
final class LayerGeometry: ObservableObject {

    static let shared = LayerGeometry()

    struct Zone: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var rect: CGRect
        /// Raise an alert when occupancy reaches this. Zero means count only.
        var alertAtCount: Int = 0
        /// Raise an alert when anything dwells this long, in seconds. Zero is off.
        var alertAfterSeconds: Double = 0
    }

    struct CountLine: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var a: CGPoint
        var b: CGPoint
    }

    @Published var zones: [Zone] { didSet { save(zones, "layerZones") } }
    @Published var lines: [CountLine] { didSet { save(lines, "layerLines") } }

    private init() {
        zones = LayerGeometry.load([Zone].self, "layerZones") ?? []
        lines = LayerGeometry.load([CountLine].self, "layerLines") ?? []
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func addZone(_ rect: CGRect) {
        let n = zones.count + 1
        zones.append(Zone(name: "Zone \(n)", rect: rect))
        EventLog.action("layer.zone.add", ["name": "Zone \(n)"])
    }

    func addLine(from a: CGPoint, to b: CGPoint) {
        let n = lines.count + 1
        lines.append(CountLine(name: "Line \(n)", a: a, b: b))
        EventLog.action("layer.line.add", ["name": "Line \(n)"])
    }

    func removeZone(_ id: UUID) { zones.removeAll { $0.id == id } }
    func removeLine(_ id: UUID) { lines.removeAll { $0.id == id } }

    /// Snapshots for the capture queue, which must not touch @Published storage.
    private let lock = NSLock()
    private var zoneCache: [Zone] = []
    private var lineCache: [CountLine] = []

    func refreshCaches() {
        lock.lock(); zoneCache = zones; lineCache = lines; lock.unlock()
    }

    var zonesSnapshot: [Zone] {
        lock.lock(); defer { lock.unlock() }
        return zoneCache
    }

    var linesSnapshot: [CountLine] {
        lock.lock(); defer { lock.unlock() }
        return lineCache
    }
}

/// Which side of a directed line a point falls on. Sign flips across the line, so a
/// crossing is a sign change between two consecutive samples of the same track —
/// which is how the counter avoids double-counting someone loitering on the line.
func sideOfLine(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
    let v = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    return Double(v)
}

/// True when the segment p0->p1 actually intersects segment a->b, not merely when it
/// changes side of the infinite line. Without this, a track crossing the line's
/// extension far off to one side would be counted.
func segmentsCross(_ p0: CGPoint, _ p1: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Bool {
    func orient(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Int {
        let v = (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        if abs(v) < 1e-9 { return 0 }
        return v > 0 ? 1 : -1
    }
    let d1 = orient(a, b, p0), d2 = orient(a, b, p1)
    let d3 = orient(p0, p1, a), d4 = orient(p0, p1, b)
    return d1 != d2 && d3 != d4
}

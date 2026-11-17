import Foundation
import CoreGraphics

/// Higher-order layers. None of these run a model — they read the tracks the main
/// pipeline has already produced, which is why they cost microseconds and can run on
/// every frame with no thermal cost at all.

// MARK: - Zone occupancy and dwell

final class ZoneOccupancyLayer: DerivedAILayer {
    let id = "zones"
    let title = "Zones & dwell"
    let detail = "Counts what is inside each drawn zone and how long it has stayed."
    let group = LayerGroup.analytics
    let modality = LayerModality.derived
    var availability: LayerAvailability {
        LayerGeometry.shared.zonesSnapshot.isEmpty
            ? .needsSetup("Draw a zone on the feed first")
            : .available
    }

    /// When each track entered each zone, so dwell is measured rather than counted
    /// in frames.
    private var entered: [UUID: [Int: Date]] = [:]
    private var lastAlert: [UUID: Date] = [:]

    func process(_ ctx: FrameContext) -> LayerOutput? {
        let zones = LayerGeometry.shared.zonesSnapshot
        guard !zones.isEmpty else { return nil }

        var out = LayerOutput()
        var totalInside = 0
        var alerts: [String] = []
        let now = Date()

        for zone in zones {
            var insideIDs: [Int] = []
            var longest: TimeInterval = 0

            for track in ctx.tracks where track.misses == 0 {
                let centre = CGPoint(x: track.box.midX, y: track.box.midY)
                guard zone.rect.contains(centre) else {
                    entered[zone.id]?[track.id] = nil
                    continue
                }
                insideIDs.append(track.id)
                var map = entered[zone.id] ?? [:]
                let since = map[track.id] ?? now
                map[track.id] = since
                entered[zone.id] = map
                longest = max(longest, now.timeIntervalSince(since))
            }

            // Forget tracks the tracker has dropped, or dwell grows forever.
            let liveIDs = Set(ctx.tracks.map(\.id))
            entered[zone.id] = entered[zone.id]?.filter { liveIDs.contains($0.key) }

            totalInside += insideIDs.count
            let label = longest >= 1
                ? "\(zone.name): \(insideIDs.count) · \(Int(longest))s"
                : "\(zone.name): \(insideIDs.count)"
            out.shapes.append(.box(zone.rect, label: label,
                                   tint: insideIDs.isEmpty ? .neutral : .warn))

            let cooled = now.timeIntervalSince(lastAlert[zone.id] ?? .distantPast) > 20
            if zone.alertAtCount > 0, insideIDs.count >= zone.alertAtCount, cooled {
                alerts.append("\(zone.name): \(insideIDs.count) inside")
                lastAlert[zone.id] = now
            }
            if zone.alertAfterSeconds > 0, longest >= zone.alertAfterSeconds, cooled {
                alerts.append("\(zone.name): loitering \(Int(longest))s")
                lastAlert[zone.id] = now
            }
        }

        out.badge = "\(totalInside) in"
        if !alerts.isEmpty {
            out.alert = alerts.joined(separator: " · ")
            out.lines = alerts
        }
        return out
    }
}

// MARK: - Line crossing

final class LineCrossingLayer: DerivedAILayer {
    let id = "lines"
    let title = "Line crossing"
    let detail = "Counts crossings of each drawn line, separately in each direction."
    let group = LayerGroup.analytics
    let modality = LayerModality.derived
    var availability: LayerAvailability {
        LayerGeometry.shared.linesSnapshot.isEmpty
            ? .needsSetup("Draw a counting line on the feed first")
            : .available
    }

    private var lastSide: [UUID: [Int: Double]] = [:]
    private var forward: [UUID: Int] = [:]
    private var backward: [UUID: Int] = [:]

    func process(_ ctx: FrameContext) -> LayerOutput? {
        let lines = LayerGeometry.shared.linesSnapshot
        guard !lines.isEmpty else { return nil }

        var out = LayerOutput()
        var crossedThisFrame: [String] = []

        for line in lines {
            var sides = lastSide[line.id] ?? [:]
            for track in ctx.tracks where track.misses == 0 {
                let centre = CGPoint(x: track.box.midX, y: track.box.midY)
                let side = sideOfLine(centre, line.a, line.b)
                defer { sides[track.id] = side }

                guard let previous = sides[track.id], previous != 0, side != 0,
                      (previous < 0) != (side < 0) else { continue }
                // Sign changed. Confirm the track's own path actually met the
                // segment, not just the infinite line it sits on.
                guard let prevCentre = track.samples.dropLast().last?.centre,
                      segmentsCross(prevCentre, centre, line.a, line.b) else { continue }

                if side > 0 {
                    forward[line.id, default: 0] += 1
                    crossedThisFrame.append("\(line.name): \(track.label) in")
                } else {
                    backward[line.id, default: 0] += 1
                    crossedThisFrame.append("\(line.name): \(track.label) out")
                }
            }
            let liveIDs = Set(ctx.tracks.map(\.id))
            lastSide[line.id] = sides.filter { liveIDs.contains($0.key) }

            let f = forward[line.id] ?? 0, b = backward[line.id] ?? 0
            out.shapes.append(.polyline([line.a, line.b], tint: .primary))
            out.shapes.append(.label("\(line.name)  \(f) in / \(b) out",
                                     at: CGPoint(x: (line.a.x + line.b.x) / 2,
                                                 y: (line.a.y + line.b.y) / 2),
                                     tint: .primary))
        }

        let totalIn = forward.values.reduce(0, +)
        let totalOut = backward.values.reduce(0, +)
        out.badge = "\(totalIn)/\(totalOut)"
        out.lines = crossedThisFrame
        return out
    }

    func resetCounts() {
        forward.removeAll(); backward.removeAll()
    }
}

// MARK: - Heatmap

final class HeatmapLayer: DerivedAILayer {
    let id = "heatmap"
    let title = "Heatmap"
    let detail = "Where things have been, accumulated over the whole session."
    let group = LayerGroup.analytics
    let modality = LayerModality.derived
    let availability = LayerAvailability.available

    private let cols = 32
    private let rows = 24
    private var grid: [Double]
    private var peak: Double = 0.001

    init() { grid = [Double](repeating: 0, count: cols * rows) }

    func process(_ ctx: FrameContext) -> LayerOutput? {
        for track in ctx.tracks where track.misses == 0 {
            // Weight the bottom of the box: that is where a person meets the ground,
            // and a heatmap of torso centres floats oddly above the floor.
            let x = track.box.midX
            let y = track.box.minY + track.box.height * 0.15
            let cx = min(cols - 1, max(0, Int(x * CGFloat(cols))))
            let cy = min(rows - 1, max(0, Int(y * CGFloat(rows))))
            grid[cy * cols + cx] += 1
            peak = max(peak, grid[cy * cols + cx])
        }
        guard peak > 0 else { return nil }
        // Normalize on a log curve, or one parked car saturates the scale and
        // everything else disappears.
        let normalized = grid.map { min(1.0, log1p($0) / log1p(peak)) }
        var out = LayerOutput()
        out.shapes = [.grid(values: normalized, cols: cols, rows: rows, tint: .heat)]
        out.badge = String(format: "%.0f", grid.reduce(0, +))
        return out
    }

    func clear() {
        grid = [Double](repeating: 0, count: cols * rows)
        peak = 0.001
    }
}

// MARK: - Behavioural flags

/// Loitering, abandoned objects and converging paths. All three are patterns over
/// time in data the tracker already holds, which is the only reason they are cheap.
final class BehaviourFlagsLayer: DerivedAILayer {
    let id = "behaviour"
    let title = "Behaviour flags"
    let detail = "Loitering, abandoned objects, and two things converging fast."
    let group = LayerGroup.analytics
    let modality = LayerModality.derived
    let availability = LayerAvailability.available

    private var flagged: [Int: String] = [:]
    private var lastAlert: Date = .distantPast

    func process(_ ctx: FrameContext) -> LayerOutput? {
        var out = LayerOutput()
        var findings: [String] = []
        let now = Date()

        for track in ctx.tracks where track.misses == 0 && track.hits > 20 {
            let age = now.timeIntervalSince(track.firstSeen)

            // Loitering: present a long time without covering ground. Measured as
            // total displacement against elapsed time, so pacing in one spot still
            // counts as loitering while walking through does not.
            if age > 45, track.samples.count > 12,
               let first = track.samples.first?.centre,
               let last = track.samples.last?.centre {
                let moved = hypot(last.x - first.x, last.y - first.y)
                if moved < 0.12, track.category == .person {
                    findings.append("loitering \(Int(age))s")
                    out.shapes.append(.box(track.box, label: "loitering \(Int(age))s", tint: .warn))
                    flagged[track.id] = "loitering"
                }
            }

            // Abandoned object: a non-person, non-vehicle thing that arrived, stopped
            // and has not moved since. A bag left on the ground reads exactly like
            // this; so does a traffic cone, which is why it is a flag and not an alarm.
            if age > 60, track.category != .person, track.category != .vehicle,
               track.samples.count > 15,
               let first = track.samples.first?.centre,
               let last = track.samples.last?.centre,
               hypot(last.x - first.x, last.y - first.y) < 0.03 {
                findings.append("stationary \(track.label) \(Int(age))s")
                out.shapes.append(.box(track.box, label: "left behind?", tint: .warn))
                flagged[track.id] = "abandoned"
            }
        }

        // Converging paths: two tracks closing on each other quickly. Reported as a
        // near-miss flag, not a collision prediction — there is no ground plane here
        // to make that claim honestly.
        let live = ctx.tracks.filter { $0.misses == 0 && $0.samples.count > 6 }
        for i in live.indices {
            for j in live.indices where j > i {
                let a = live[i], b = live[j]
                guard let a0 = a.samples.first?.centre, let a1 = a.samples.last?.centre,
                      let b0 = b.samples.first?.centre, let b1 = b.samples.last?.centre
                else { continue }
                let was = hypot(a0.x - b0.x, a0.y - b0.y)
                let now2 = hypot(a1.x - b1.x, a1.y - b1.y)
                guard was > 0.18, now2 < 0.08, was - now2 > 0.12 else { continue }
                findings.append("\(a.label) and \(b.label) converging")
                out.shapes.append(.polyline([a1, b1], tint: .alert))
            }
        }

        let liveIDs = Set(ctx.tracks.map(\.id))
        flagged = flagged.filter { liveIDs.contains($0.key) }

        out.badge = flagged.isEmpty ? nil : "\(flagged.count)"
        if !findings.isEmpty {
            out.lines = findings
            if now.timeIntervalSince(lastAlert) > 30 {
                lastAlert = now
                out.alert = findings.joined(separator: " · ")
            }
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Trend detection

/// Rate of arrivals over three windows. Useful for "busier than usual" rather than
/// any single event, and it is the one analytic that says something a still frame
/// cannot.
final class TrendLayer: DerivedAILayer {
    let id = "trend"
    let title = "Trend"
    let detail = "Arrival rate now versus the last hour, per minute."
    let group = LayerGroup.analytics
    let modality = LayerModality.derived
    let availability = LayerAvailability.available

    private var arrivals: [Date] = []
    private var seen = Set<Int>()

    func process(_ ctx: FrameContext) -> LayerOutput? {
        let now = Date()
        for track in ctx.tracks where !seen.contains(track.id) && track.hits > 5 {
            seen.insert(track.id)
            arrivals.append(now)
        }
        if seen.count > 4000 { seen.removeAll() }
        arrivals.removeAll { now.timeIntervalSince($0) > 3600 }
        guard arrivals.count > 2 else { return nil }

        let lastMinute = arrivals.filter { now.timeIntervalSince($0) <= 60 }.count
        let perMinuteHour = Double(arrivals.count) / 60.0

        var out = LayerOutput()
        out.badge = "\(lastMinute)/min"
        if perMinuteHour > 0.5, Double(lastMinute) > perMinuteHour * 2.5 {
            out.lines = [String(format: "busier than usual — %d in the last minute vs %.1f/min average",
                                lastMinute, perMinuteHour)]
        }
        return out
    }
}

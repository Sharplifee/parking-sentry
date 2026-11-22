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

            // Standardized: a zone dragged right-to-left or bottom-to-top arrives
            // with a negative width or height, and `CGRect.contains` is false for
            // every point in such a rect — so half the zones anyone drew counted
            // nothing at all and looked simply broken.
            let area = zone.rect.standardized
            for track in ctx.tracks where track.misses == 0 {
                let centre = CGPoint(x: track.box.midX, y: track.box.midY)
                guard area.contains(centre) else {
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
            out.shapes.append(.box(area, label: label,
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
        // Spelled out rather than "12/3". A counting line's number is meant to be a
        // running tally, but a bare pair of digits next to a live camera reads as
        // what is in frame, so it says which it is.
        out.badge = crossedThisFrame.isEmpty ? "watching" : "crossing"
        out.total = "\(totalIn) in · \(totalOut) out"
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
    private var frames = 0
    /// Half-life of a cell's weight, in frames. Roughly ten minutes at 30 fps.
    private let halfLife = 18_000.0

    init() { grid = [Double](repeating: 0, count: cols * rows) }

    func process(_ ctx: FrameContext) -> LayerOutput? {
        var occupied = 0
        for track in ctx.tracks where track.misses == 0 {
            // Weight the bottom of the box: that is where a person meets the ground,
            // and a heatmap of torso centres floats oddly above the floor.
            let x = track.box.midX
            let y = track.box.minY + track.box.height * 0.15
            let cx = min(cols - 1, max(0, Int(x * CGFloat(cols))))
            let cy = min(rows - 1, max(0, Int(y * CGFloat(rows))))
            grid[cy * cols + cx] += 1
            peak = max(peak, grid[cy * cols + cx])
            occupied += 1
        }

        // Decay, so a car parked all morning fades instead of owning the scale for
        // the rest of the session. Without this `peak` only ever rose and every
        // later visitor was normalised into invisibility against it.
        frames += 1
        if frames % 300 == 0 {
            let factor = pow(0.5, 300.0 / halfLife)
            for i in grid.indices { grid[i] *= factor }
            peak = max(0.001, peak * factor)
        }

        guard peak > 0.5 else { return nil }
        // Normalize on a log curve, or one parked car saturates the scale and
        // everything else disappears.
        let normalized = grid.map { min(1.0, log1p($0) / log1p(peak)) }
        var out = LayerOutput()
        out.shapes = [.grid(values: normalized, cols: cols, rows: rows, tint: .heat)]
        // Live occupancy, and separately how much of the view has ever been walked
        // on. The badge used to be the sum of the whole grid — one person standing
        // still for a minute added 1800 to it, and a toggle reading "1800" beside a
        // camera showing one person is simply a wrong answer to the question the
        // number appears to be answering.
        out.badge = occupied > 0 ? "\(occupied) moving" : "quiet"
        let touched = grid.filter { $0 > 0.5 }.count
        out.total = touched > 0
            ? String(format: "%.0f%% of view used", Double(touched) / Double(grid.count) * 100)
            : nil
        return out
    }

    func clear() {
        grid = [Double](repeating: 0, count: cols * rows)
        peak = 0.001
        frames = 0
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
            // `maxExcursion` is how far this track has ever got from where it first
            // appeared, measured over its whole life. The samples array only spans
            // three seconds, so the previous version measured three seconds of
            // movement and called it forty-five — anyone walking slowly across the
            // frame was flagged for loitering the moment they had been in view long
            // enough.
            if age > 45, track.category == .person, track.maxExcursion < 0.12 {
                findings.append("loitering \(Int(age))s")
                out.shapes.append(.box(track.box, label: "loitering \(Int(age))s", tint: .warn))
                flagged[track.id] = "loitering"
            }

            // Abandoned object: a non-person, non-vehicle thing that arrived, stopped
            // and has not moved since. A bag left on the ground reads exactly like
            // this; so does a traffic cone, which is why it is a flag and not an alarm.
            if age > 60, track.category != .person, track.category != .vehicle,
               track.maxExcursion < 0.03 {
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
    private var startedAt = Date()

    func process(_ ctx: FrameContext) -> LayerOutput? {
        let now = Date()
        for track in ctx.tracks where !seen.contains(track.id)
            && track.hits > 5 && track.misses == 0 {
            seen.insert(track.id)
            arrivals.append(now)
        }
        // Drop ids that the tracker itself has forgotten rather than wiping the
        // whole set at a threshold: a wipe made every track still in frame count as
        // a fresh arrival the next frame, which put a spike in the trend that
        // nothing in the scene corresponded to.
        if seen.count > 4000 {
            let live = Set(ctx.tracks.map(\.id))
            seen = seen.filter { live.contains($0) }
        }
        arrivals.removeAll { now.timeIntervalSince($0) > 3600 }
        guard arrivals.count > 2 else { return nil }

        let lastMinute = arrivals.filter { now.timeIntervalSince($0) <= 60 }.count
        // Divide by the minutes actually observed, not a flat sixty. For the first
        // hour of any session the window is not full, so dividing by 60 understated
        // the baseline by up to sixty times and "busier than usual" fired on
        // essentially every arrival until the app had been watching for an hour.
        let observedMinutes = max(1.0, min(60.0, now.timeIntervalSince(startedAt) / 60.0))
        let perMinute = Double(arrivals.count) / observedMinutes

        var out = LayerOutput()
        out.badge = "\(lastMinute)/min"
        out.total = String(format: "%.1f/min avg", perMinute)
        // Needs a real baseline and a real excess before it says anything, and five
        // minutes of history before it is willing to call anything unusual.
        if observedMinutes >= 5, perMinute > 0.5, Double(lastMinute) > perMinute * 2.5 {
            out.lines = [String(format: "busier than usual — %d in the last minute vs %.1f/min average",
                                lastMinute, perMinute)]
        }
        return out
    }
}

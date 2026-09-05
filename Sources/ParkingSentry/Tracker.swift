import CoreGraphics
import Foundation

/// Stage 3: persistence. One good frame is never enough.
///
/// A track has to be re-seen on several frames in the same neighbourhood before it
/// can trigger anything. This is what kills single-frame Vision misfires from rain
/// streaks, insects near the lens, and headlight glare.
final class Track {
    let id: Int
    var box: CGRect
    var hits: Int = 1
    var misses: Int = 0
    var firstSeen: Date = Date()
    var lastSeen: Date = Date()
    var lastAlert: Date?
    /// (timestamp, range in metres, box centre) so speed is measured, not guessed.
    var samples: [(t: Date, range: Double?, centre: CGPoint)] = []
    var rangeHistory: [Double] = []
    var category: SubjectCategory = .unknown
    var label: String = "movement"
    var bestConfidence: Float = 0
    var heightSamples: [Double] = []
    var widthSamples: [Double] = []
    var maxJoints: Int = 0

    init(id: Int, box: CGRect) {
        self.id = id
        self.box = box
    }

    /// Median of recent height measurements — a single frame's box is noisy,
    /// the median across a second of them is not.
    var measuredHeight: Double? {
        guard heightSamples.count >= 3 else { return nil }
        let t = heightSamples.suffix(9).sorted()
        return t[t.count / 2]
    }

    var measuredWidth: Double? {
        guard widthSamples.count >= 3 else { return nil }
        let t = widthSamples.suffix(9).sorted()
        return t[t.count / 2]
    }

    var smoothedRange: Double? {
        guard !rangeHistory.isEmpty else { return nil }
        let tail = rangeHistory.suffix(5).sorted()
        return tail[tail.count / 2]
    }

    /// Negative = closing on the camera, in metres per second.
    /// Measured across the actual timestamps of the samples, not an assumed frame rate.
    var closingRate: Double? {
        let ranged = samples.compactMap { s -> (Date, Double)? in s.range.map { (s.t, $0) } }
        guard ranged.count >= 4, let first = ranged.first, let last = ranged.last else { return nil }
        let dt = last.0.timeIntervalSince(first.0)
        guard dt > 0.4 else { return nil }
        let half = ranged.count / 2
        let early = ranged.prefix(half).map(\.1).reduce(0, +) / Double(half)
        let late = ranged.suffix(half).map(\.1).reduce(0, +) / Double(half)
        return (late - early) / dt
    }

    /// Sideways speed in m/s, from angular movement across the frame scaled by range.
    /// Without a range there is no way to turn pixels into metres, so it returns nil.
    func lateralRate(horizontalFOVRadians: Double) -> Double? {
        guard let r = smoothedRange, samples.count >= 4,
              let first = samples.first, let last = samples.last else { return nil }
        let dt = last.t.timeIntervalSince(first.t)
        guard dt > 0.4 else { return nil }
        let dx = Double(last.centre.x - first.centre.x)
        let dy = Double(last.centre.y - first.centre.y)
        let angular = sqrt(dx * dx + dy * dy) * horizontalFOVRadians
        return (angular * r) / dt
    }

    /// Total speed in m/s combining closing and lateral components.
    func speed(horizontalFOVRadians: Double) -> Double? {
        let c = closingRate ?? 0
        let l = lateralRate(horizontalFOVRadians: horizontalFOVRadians) ?? 0
        guard closingRate != nil || lateralRate(horizontalFOVRadians: horizontalFOVRadians) != nil else { return nil }
        return sqrt(c * c + l * l)
    }
}

final class Tracker {
    private var tracks: [Track] = []
    private var nextID = 1
    private let matchIoU: CGFloat = 0.18
    private let maxMisses = 12

    var active: [Track] { tracks }

    func update(with subjects: [DetectedSubject]) -> [Track] {
        var unmatched = subjects
        var touched = Set<Int>()

        for track in tracks {
            var bestIdx: Int?
            var bestScore: CGFloat = matchIoU
            for (i, s) in unmatched.enumerated() {
                let score = iou(track.box, s.boundingBox)
                if score > bestScore { bestScore = score; bestIdx = i }
            }
            if let i = bestIdx {
                let s = unmatched.remove(at: i)
                track.box = s.boundingBox
                track.hits += 1
                track.misses = 0
                track.lastSeen = Date()
                // A named class always beats a bare "something moved".
                if s.category != .unknown || track.category == .unknown {
                    track.category = s.category
                    track.label = s.label
                }
                track.bestConfidence = max(track.bestConfidence, s.confidence)
                track.maxJoints = max(track.maxJoints, s.jointCount)
                touched.insert(track.id)
            }
        }

        for s in unmatched {
            let t = Track(id: nextID, box: s.boundingBox)
            t.category = s.category
            t.label = s.label
            t.bestConfidence = s.confidence
            t.maxJoints = s.jointCount
            nextID += 1
            tracks.append(t)
        }

        for track in tracks where !touched.contains(track.id) {
            track.misses += 1
        }
        tracks.removeAll { $0.misses > maxMisses }

        return tracks
    }

    func recordSize(height: Double?, width: Double?, for track: Track) {
        if let h = height {
            track.heightSamples.append(h)
            if track.heightSamples.count > 20 { track.heightSamples.removeFirst() }
        }
        if let w = width {
            track.widthSamples.append(w)
            if track.widthSamples.count > 20 { track.widthSamples.removeFirst() }
        }
    }

    func recordSample(range: Double?, for track: Track) {
        if let r = range {
            track.rangeHistory.append(r)
            if track.rangeHistory.count > 30 { track.rangeHistory.removeFirst() }
        }
        track.samples.append((Date(), range, CGPoint(x: track.box.midX, y: track.box.midY)))
        // Keep roughly the last three seconds; older points make speed sluggish.
        let cutoff = Date().addingTimeInterval(-3.0)
        track.samples.removeAll { $0.t < cutoff }
        if track.samples.count > 40 { track.samples.removeFirst(track.samples.count - 40) }
    }

    func reset() {
        tracks.removeAll()
    }
}

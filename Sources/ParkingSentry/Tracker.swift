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
    var rangeHistory: [Double] = []
    var category: SubjectCategory = .unknown
    var label: String = "movement"
    var bestConfidence: Float = 0
    var maxJoints: Int = 0

    init(id: Int, box: CGRect) {
        self.id = id
        self.box = box
    }

    var smoothedRange: Double? {
        guard !rangeHistory.isEmpty else { return nil }
        let tail = rangeHistory.suffix(5).sorted()
        return tail[tail.count / 2]
    }

    /// Negative = closing on the camera, in meters per second.
    var closingRate: Double? {
        guard rangeHistory.count >= 4 else { return nil }
        let recent = Array(rangeHistory.suffix(6))
        let first = recent.prefix(recent.count / 2).reduce(0, +) / Double(recent.count / 2)
        let last = recent.suffix(recent.count / 2).reduce(0, +) / Double(recent.count / 2)
        let dt = max(0.2, Date().timeIntervalSince(firstSeen) / 2)
        return (last - first) / dt
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

    func recordRange(_ meters: Double, for track: Track) {
        track.rangeHistory.append(meters)
        if track.rangeHistory.count > 30 { track.rangeHistory.removeFirst() }
    }

    func reset() {
        tracks.removeAll()
    }
}

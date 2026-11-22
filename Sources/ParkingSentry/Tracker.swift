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

    /// Where this track was first seen, and how far it has ever got from there.
    ///
    /// `samples` only holds the last three seconds, so anything asking "has this
    /// person covered any ground since they arrived" cannot be answered from it —
    /// the loitering test used to compare the first and last of those samples and
    /// so measured three seconds of movement while claiming to measure forty-five.
    /// Someone walking steadily across a car park moves very little in three
    /// seconds and was flagged as loitering for it.
    private(set) var origin: CGPoint?
    private(set) var maxExcursion: Double = 0

    func notePosition(_ p: CGPoint) {
        guard let origin else {
            origin = p
            return
        }
        let d = Double(hypot(p.x - origin.x, p.y - origin.y))
        maxExcursion = max(maxExcursion, d)
    }

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
    /// The rate is the change between the two halves' *means*, so the time it is
    /// divided by has to be the gap between the two halves' mean timestamps — not
    /// the full first-to-last span, which is about twice as long. Dividing by the
    /// full span reported every approach speed at roughly half its true value, so a
    /// car closing at 20 mph was logged at 10 and anything thresholded on speed
    /// fired late or not at all.
    var closingRate: Double? {
        let ranged = samples.compactMap { s -> (Date, Double)? in s.range.map { (s.t, $0) } }
        guard ranged.count >= 4 else { return nil }
        let half = ranged.count / 2
        let earlyHalf = Array(ranged.prefix(half))
        let lateHalf = Array(ranged.suffix(half))
        guard !earlyHalf.isEmpty, !lateHalf.isEmpty else { return nil }

        let early = earlyHalf.map(\.1).reduce(0, +) / Double(earlyHalf.count)
        let late = lateHalf.map(\.1).reduce(0, +) / Double(lateHalf.count)
        let earlyT = earlyHalf.map(\.0.timeIntervalSince1970).reduce(0, +) / Double(earlyHalf.count)
        let lateT = lateHalf.map(\.0.timeIntervalSince1970).reduce(0, +) / Double(lateHalf.count)

        let dt = lateT - earlyT
        guard dt > 0.2 else { return nil }
        return (late - early) / dt
    }

    /// Sideways speed in m/s, from angular movement across the frame scaled by range.
    /// Without a range there is no way to turn pixels into metres, so it returns nil.
    ///
    /// `displayAspect` is width over height of the frame. Normalized vertical
    /// movement spans the vertical field of view, not the horizontal one, so
    /// scaling dy by the horizontal FOV — as this did — overstated vertical motion
    /// by the aspect ratio, about 1.8x in landscape.
    func lateralRate(horizontalFOVRadians: Double, displayAspect: Double = 16.0 / 9.0) -> Double? {
        guard let r = smoothedRange, samples.count >= 4,
              let first = samples.first, let last = samples.last else { return nil }
        let dt = last.t.timeIntervalSince(first.t)
        guard dt > 0.4 else { return nil }
        let verticalFOV = horizontalFOVRadians / max(0.1, displayAspect)
        let dx = Double(last.centre.x - first.centre.x) * horizontalFOVRadians
        let dy = Double(last.centre.y - first.centre.y) * verticalFOV
        // Small-angle: within a phone's field of view the tangent and the angle
        // agree to a few percent, which is well inside the error on `range`.
        let angular = sqrt(dx * dx + dy * dy)
        return (angular * r) / dt
    }

    /// Total speed in m/s combining closing and lateral components.
    func speed(horizontalFOVRadians: Double, displayAspect: Double = 16.0 / 9.0) -> Double? {
        let c = closingRate
        let l = lateralRate(horizontalFOVRadians: horizontalFOVRadians,
                            displayAspect: displayAspect)
        guard c != nil || l != nil else { return nil }
        let cv = c ?? 0, lv = l ?? 0
        return sqrt(cv * cv + lv * lv)
    }
}

final class Tracker {
    private var tracks: [Track] = []
    private var nextID = 1
    private let matchIoU: CGFloat = 0.18
    private let maxMisses = 12

    var active: [Track] { tracks }

    /// Associates this frame's detections with existing tracks.
    ///
    /// Three things changed here, and together they are most of why counts used to
    /// drift upward. Every unnecessary new track id is a new "arrival" to the trend
    /// layer, a new person to re-identification and a new face to enrol, so one
    /// person who loses their id four times becomes four people everywhere
    /// downstream — which is exactly how a room with one person in it reports three.
    ///
    ///   GLOBAL MATCHING   Every (track, detection) pair is scored and the best
    ///                     pairs are taken first. The old version walked tracks in
    ///                     creation order and let each take its own favourite, so
    ///                     two people passing each other reliably swapped ids —
    ///                     whoever was created first got first pick of a box that
    ///                     belonged to the other.
    ///   CENTRE FALLBACK   Vision does not run on every frame, so a detection can
    ///                     jump far enough between runs that two boxes of the same
    ///                     person no longer overlap at all. A box that does not
    ///                     overlap but whose centre barely moved, relative to its
    ///                     own size, is the same thing — and without this rule it
    ///                     became a new one.
    ///   CATEGORY GATING   A person track can no longer absorb a car detection just
    ///                     because the boxes happened to overlap, which used to
    ///                     relabel the track and hand a person's history to a
    ///                     vehicle.
    func update(with subjects: [DetectedSubject]) -> [Track] {
        var touched = Set<Int>()
        var claimed = Set<Int>()        // indices into `subjects`

        // Score every plausible pairing once.
        var pairs: [(track: Track, index: Int, score: CGFloat)] = []
        for track in tracks {
            for (i, s) in subjects.enumerated() {
                guard Tracker.compatible(track.category, s.category) else { continue }
                guard let score = Tracker.affinity(track.box, s.boundingBox,
                                                   floor: matchIoU) else { continue }
                pairs.append((track, i, score))
            }
        }
        pairs.sort { $0.score > $1.score }

        for pair in pairs {
            guard !touched.contains(pair.track.id), !claimed.contains(pair.index) else { continue }
            let s = subjects[pair.index]
            let track = pair.track
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
            claimed.insert(pair.index)
        }

        for (i, s) in subjects.enumerated() where !claimed.contains(i) {
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

    /// Two named classes have to agree. Anything still unknown may become anything,
    /// because that is what an unnamed moving blob resolving into a car looks like.
    private static func compatible(_ a: SubjectCategory, _ b: SubjectCategory) -> Bool {
        a == .unknown || b == .unknown || a == b
    }

    /// How strongly a detection looks like the continuation of a track.
    ///
    /// Overlap when there is any, and otherwise proximity measured against the size
    /// of the boxes, which is the scale-free way to ask "did this barely move".
    /// Proximity scores strictly below any real overlap so it only ever decides a
    /// pairing that overlap could not.
    private static func affinity(_ a: CGRect, _ b: CGRect, floor: CGFloat) -> CGFloat? {
        let overlap = iou(a, b)
        if overlap > floor { return 1 + overlap }

        let span = max(a.width, a.height, b.width, b.height)
        guard span > 0.0001 else { return nil }
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        let distance = sqrt(dx * dx + dy * dy) / span
        guard distance < 0.75 else { return nil }
        // Sizes must also be in the same ballpark, or a distant car matches a
        // nearby one that happens to sit in the same part of the frame.
        let areaA = max(a.width * a.height, 1e-6)
        let areaB = max(b.width * b.height, 1e-6)
        let ratio = max(areaA, areaB) / min(areaA, areaB)
        guard ratio < 3.0 else { return nil }
        return 1 - distance
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
        let centre = CGPoint(x: track.box.midX, y: track.box.midY)
        track.notePosition(centre)
        track.samples.append((Date(), range, centre))
        // Keep roughly the last three seconds; older points make speed sluggish.
        let cutoff = Date().addingTimeInterval(-3.0)
        track.samples.removeAll { $0.t < cutoff }
        if track.samples.count > 40 { track.samples.removeFirst(track.samples.count - 40) }
    }

    func reset() {
        tracks.removeAll()
    }
}

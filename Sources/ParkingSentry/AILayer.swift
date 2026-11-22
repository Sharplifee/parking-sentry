import Foundation
import CoreVideo
import CoreGraphics
import AVFoundation
import Vision
import QuartzCore
import Combine

/// The layer system: one plain feed, many models, each independently toggleable.
///
/// The design tension worth naming up front. "Every model runs continuously in the
/// background, toggle only controls rendering" and "low power, smooth feed, stay
/// cool" cannot both be literally true on an iPhone — twenty-five Vision requests
/// per frame will thermally throttle an A17 in under two minutes and the feed will
/// stutter long before that. So this splits the two things a toggle could mean:
///
///   WARM  — the model is loaded, compiled and resident on the Neural Engine, with
///           its request objects built. No frames are consumed. This is what makes
///           a toggle feel instant: first-frame latency after flipping a warm layer
///           on is one inference, not a model load.
///   ACTIVE — the layer consumes frames and renders.
///
/// Every cheap layer stays warm from launch. Heavy ones load on first activation and
/// stay warm afterwards. That is what "background models stay light, heavy work is
/// on-demand" has to mean in practice, and it delivers the thing actually wanted:
/// output appears the instant a toggle flips.
///
/// The second half is the governor below. Layers declare how often they need to run;
/// when the measured per-frame cost of the active set exceeds the frame budget, the
/// governor stretches the expensive layers' intervals rather than dropping frames, so
/// the preview stays smooth and the overlays degrade gracefully instead of the feed
/// hitching.

// MARK: - Taxonomy

enum LayerGroup: String, CaseIterable, Identifiable {
    case vision      = "Vision"
    case audio       = "Audio & Speech"
    case language    = "Language"
    case multimodal  = "Multimodal"
    case sensors     = "Sensors"
    case analytics   = "Analytics"
    case privacy     = "Privacy"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .vision:     return "eye"
        case .audio:      return "waveform"
        case .language:   return "text.alignleft"
        case .multimodal: return "square.stack.3d.up"
        case .sensors:    return "gyroscope"
        case .analytics:  return "chart.bar"
        case .privacy:    return "eye.slash"
        }
    }
}

enum LayerModality {
    case video, audio, text, sensor, derived
}

/// Why a layer cannot run, stated rather than faked. A layer that Apple provides no
/// API for is shown in the list as unavailable with the reason, because silently
/// omitting it invites the question "did it get built?" every time, and a plausible
/// fake output is worse than an honest blank.
enum LayerAvailability: Equatable {
    case available
    /// Hardware this device does not have.
    case needsHardware(String)
    /// Works, but needs the operator to draw or choose something first. Still
    /// toggleable — the hint goes in the panel instead of blocking the switch.
    case needsSetup(String)
    /// A model has to be downloaded first. Toggleable: switching the layer on is
    /// what starts the download, and the panel shows the progress.
    case needsDownload(String)
    /// Works, but the inference is not on-device.
    case needsNetwork(String)
    /// Apple ships no public API for this and no model is bundled.
    case noPublicAPI(String)
    /// A bundled model is missing or failed to load.
    case modelMissing(String)

    var isUsable: Bool {
        switch self {
        case .available, .needsNetwork, .needsSetup, .needsDownload: return true
        default: return false
        }
    }

    var reason: String? {
        switch self {
        case .available:                return nil
        case .needsHardware(let s):     return s
        case .needsSetup(let s):        return s
        case .needsDownload(let s):     return s
        case .needsNetwork(let s):      return s
        case .noPublicAPI(let s):       return s
        case .modelMissing(let s):      return s
        }
    }
}

/// Tints are named rather than concrete colors so the model layer never imports
/// SwiftUI; the renderer owns the palette.
enum LayerTint: String {
    case primary, person, vehicle, animal, text, face, hand, flow, heat,
         warn, alert, mask, neutral
}

// MARK: - Output

/// What a layer hands the renderer. Everything is in normalized coordinates with a
/// bottom-left origin — Vision's convention — so one renderer maps every layer and a
/// new layer gets correct placement for free.
struct LayerOutput {
    var shapes: [LayerShape] = []
    /// A fully composited image replacing the region it covers (privacy blur).
    var image: CGImage?
    /// Lines for the side panel: transcript, OCR, entities, labels.
    var lines: [String] = []
    /// One compact value shown on the layer's own toggle row.
    var badge: String?
    /// Set when this output should raise an alert through the normal path.
    var alert: String?

    var isEmpty: Bool {
        shapes.isEmpty && image == nil && lines.isEmpty && badge == nil && alert == nil
    }
}

enum LayerShape {
    case box(CGRect, label: String?, tint: LayerTint)
    /// Four or more corners, for oriented boxes and text quads.
    case quad([CGPoint], label: String?, tint: LayerTint)
    case points([CGPoint], tint: LayerTint)
    case polyline([CGPoint], tint: LayerTint)
    /// Joint pairs for a skeleton.
    case bones([(CGPoint, CGPoint)], tint: LayerTint)
    /// Row-major grid of 0–1 intensities, origin bottom-left.
    case grid(values: [Double], cols: Int, rows: Int, tint: LayerTint)
    case label(String, at: CGPoint, tint: LayerTint)
}

// MARK: - Input

struct FrameContext {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    /// One handler per frame, shared by every layer. Vision prepares the image once
    /// per handler, so twelve layers sharing one handler is materially cheaper than
    /// twelve handlers over the same buffer — and the instance-mask API needs the
    /// very handler its request was performed on in order to upscale a mask.
    let handler: VNImageRequestHandler
    let depth: AVDepthData?
    let frameIndex: Int
    let timestamp: CMTime
    let width: Int
    let height: Int
    /// This frame's detections from the main pipeline, so derived layers never
    /// re-run a detector that has already run.
    let subjects: [DetectedSubject]
    let tracks: [Track]
}

// MARK: - Layer protocols

protocol AILayer: AnyObject {
    var id: String { get }
    var title: String { get }
    var detail: String { get }
    var group: LayerGroup { get }
    var modality: LayerModality { get }
    var availability: LayerAvailability { get }
    /// Frames between runs at full speed. 1 = every frame. The governor may
    /// stretch this under load but never shortens it.
    var preferredInterval: Int { get }
    /// False for layers heavy enough that holding them resident when unused is
    /// not worth the memory; those load on first activation.
    var warmAtLaunch: Bool { get }

    func warm()
    func cool()
}

extension AILayer {
    var preferredInterval: Int { 1 }
    var warmAtLaunch: Bool { true }
    func warm() {}
    func cool() {}
}

protocol VideoAILayer: AILayer {
    func process(_ ctx: FrameContext) throws -> LayerOutput?
}

protocol AudioAILayer: AILayer {
    func process(buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> LayerOutput?
    /// Audio layers that own a stream analyzer need to know when they stop.
    func reset()
}

extension AudioAILayer {
    func reset() {}
}

/// Post-processing over the main pipeline's tracks. No model, negligible cost, so
/// these run every frame whenever active.
protocol DerivedAILayer: AILayer {
    func process(_ ctx: FrameContext) -> LayerOutput?
}

// MARK: - Registry

/// Owns every layer, which ones are on, their latest output and what each costs.
///
/// Toggle state persists, so the set of layers from the last session is live again
/// the moment the camera starts.
final class LayerRegistry: ObservableObject {

    static let shared = LayerRegistry()

    /// Latest output per layer id. Only active layers appear.
    @Published private(set) var outputs: [String: LayerOutput] = [:]
    /// Rolling mean cost in milliseconds per run, per layer.
    @Published private(set) var cost: [String: Double] = [:]
    /// Interval the governor settled on, when it differs from the layer's preference.
    @Published private(set) var throttled: [String: Int] = [:]
    /// Set when the governor is stretching intervals, for the UI to explain itself.
    @Published private(set) var governorNote: String?
    /// Measured cost of the active set per frame, in milliseconds.
    @Published private(set) var activeCostMS: Double = 0
    /// Published for the UI, written only on the main thread.
    @Published private(set) var activeIDs: Set<String> = []
    /// The same set, read by the capture and audio threads. Kept separately
    /// because mutating a @Published value off the main thread is a data race
    /// and SwiftUI complains about it loudly and correctly.
    private var liveActive: Set<String> = []
    /// Side-panel text, newest first, pooled across every active layer.
    @Published private(set) var feed: [LayerFeedLine] = []

    private(set) var all: [AILayer] = []
    private let defaultsKey = "activeAILayers"
    private let lock = NSLock()
    private var intervalOverride: [String: Int] = [:]
    private var lastRun: [String: Int] = [:]
    private var costSamples: [String: [Double]] = [:]
    /// Lock-protected mirror of `cost`, for the governor, which runs on the
    /// capture thread and must not read a @Published dictionary.
    private var costMirror: [String: Double] = [:]

    struct LayerFeedLine: Identifiable {
        let id = UUID()
        let layer: String
        let text: String
        let date: Date
    }

    private init() {
        let saved = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        activeIDs = saved
        liveActive = saved
    }

    /// Called once at startup with every layer the app knows about.
    func register(_ layers: [AILayer]) {
        all = layers
        // Drop remembered ids for layers that cannot run on this device, so a
        // toggle saved on a LiDAR phone does not look stuck on a phone without one.
        let kept = activeIDs.filter { id in
            all.first(where: { $0.id == id })?.availability.isUsable ?? false
        }
        activeIDs = kept
        lock.lock(); liveActive = kept; lock.unlock()
        for layer in all where layer.warmAtLaunch && layer.availability.isUsable {
            layer.warm()
        }
        for layer in all where kept.contains(layer.id) {
            layer.warm()
        }
    }

    func layer(_ id: String) -> AILayer? { all.first { $0.id == id } }

    /// Safe from any thread; the UI reads the published set, everything else
    /// reads this.
    func isActive(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveActive.contains(id)
    }

    private var liveActiveSnapshot: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return liveActive
    }

    func layers(in group: LayerGroup) -> [AILayer] { all.filter { $0.group == group } }

    func activeCount(in group: LayerGroup) -> Int {
        all.filter { $0.group == group && activeIDs.contains($0.id) }.count
    }

    /// Flipping a layer. Warming happens here rather than on the first frame so the
    /// first output lands one inference after the tap, not one model load after it.
    func setActive(_ id: String, _ on: Bool) {
        guard let layer = layer(id) else { return }
        guard !on || layer.availability.isUsable else { return }

        lock.lock()
        if on { liveActive.insert(id) } else { liveActive.remove(id) }
        let ids = liveActive
        lock.unlock()

        if on {
            layer.warm()
        } else {
            if !layer.warmAtLaunch { layer.cool() }
            if let a = layer as? AudioAILayer { a.reset() }
            DispatchQueue.main.async {
                self.outputs[id] = nil
                self.throttled[id] = nil
                self.feed.removeAll { $0.layer == id }
            }
        }
        UserDefaults.standard.set(Array(ids), forKey: defaultsKey)
        DispatchQueue.main.async { self.activeIDs = ids }
        EventLog.action("layer.toggle", ["layer": id, "on": on])
    }

    func toggle(_ id: String) { setActive(id, !isActive(id)) }

    func deactivateAll() {
        for id in liveActiveSnapshot { setActive(id, false) }
    }

    // MARK: Running

    /// True when this layer should run on this frame, honouring its own preferred
    /// interval and anything the governor has added on top.
    private func due(_ layer: AILayer, frame: Int) -> Bool {
        let interval = max(layer.preferredInterval, intervalOverride[layer.id] ?? 1)
        guard interval > 1 else { return true }
        let last = lastRun[layer.id] ?? Int.min
        return frame - last >= interval
    }

    /// Runs the active video and derived layers for one frame. Called on the capture
    /// queue; never on main.
    ///
    /// Returns this frame's outputs to the caller directly. The published
    /// `outputs` dictionary is written on main a moment later for the UI, and
    /// reading that from the capture thread would be both a frame stale and a
    /// genuine data race on a Swift dictionary.
    @discardableResult
    func runVideo(_ ctx: FrameContext) -> [String: LayerOutput] {
        let active = liveActiveSnapshot
        guard !active.isEmpty else { return [:] }
        var produced: [String: LayerOutput] = [:]
        var newLines: [LayerFeedLine] = []
        var spent = 0.0

        for layer in all where active.contains(layer.id) {
            guard due(layer, frame: ctx.frameIndex) else { continue }

            let started = CACurrentMediaTime()
            var out: LayerOutput?
            if let v = layer as? VideoAILayer {
                do { out = try v.process(ctx) }
                catch {
                    // A failing layer turns itself off rather than throwing on every
                    // frame for the rest of the session.
                    EventLog.error(error, name: "layer.failed", ["layer": layer.id])
                    setActive(layer.id, false)
                    continue
                }
            } else if let d = layer as? DerivedAILayer {
                out = d.process(ctx)
            } else {
                continue
            }
            let ms = (CACurrentMediaTime() - started) * 1000
            spent += ms
            lastRun[layer.id] = ctx.frameIndex
            recordCost(layer.id, ms)

            if let out {
                produced[layer.id] = out
                for line in out.lines {
                    newLines.append(LayerFeedLine(layer: layer.id, text: line, date: Date()))
                }
            }
        }

        govern(spent: spent, active: active)

        guard !produced.isEmpty || !newLines.isEmpty else { return produced }
        let snapshot = produced
        DispatchQueue.main.async {
            for (k, v) in snapshot { self.outputs[k] = v }
            if !newLines.isEmpty { self.appendFeed(newLines) }
        }
        return produced
    }

    /// Audio layers are driven from the mic tap, on its own thread.
    func runAudio(buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let active = liveActiveSnapshot
        guard !active.isEmpty else { return }
        var produced: [String: LayerOutput] = [:]
        var newLines: [LayerFeedLine] = []

        for layer in all where active.contains(layer.id) {
            guard let a = layer as? AudioAILayer else { continue }
            let started = CACurrentMediaTime()
            guard let out = a.process(buffer: buffer, at: time) else { continue }
            recordCost(layer.id, (CACurrentMediaTime() - started) * 1000)
            produced[layer.id] = out
            for line in out.lines {
                newLines.append(LayerFeedLine(layer: layer.id, text: line, date: Date()))
            }
        }

        guard !produced.isEmpty else { return }
        DispatchQueue.main.async {
            for (k, v) in produced { self.outputs[k] = v }
            if !newLines.isEmpty { self.appendFeed(newLines) }
        }
    }

    private func appendFeed(_ lines: [LayerFeedLine]) {
        feed.insert(contentsOf: lines, at: 0)
        if feed.count > 120 { feed.removeLast(feed.count - 120) }
    }

    private func recordCost(_ id: String, _ ms: Double) {
        var s = costSamples[id] ?? []
        s.append(ms)
        if s.count > 30 { s.removeFirst() }
        costSamples[id] = s
        let mean = s.reduce(0, +) / Double(s.count)
        lock.lock(); costMirror[id] = mean; lock.unlock()
        DispatchQueue.main.async {
            self.cost[id] = mean
            self.recomputeTotalCost()
        }
    }

    /// The governor. Budget is most of a frame interval; the rest belongs to capture,
    /// the main detector and the preview. When the active set overruns it, the most
    /// expensive layers get longer intervals — output arrives less often but the feed
    /// does not stutter, which is the right trade for an overlay.
    private func govern(spent: Double, active: Set<String>) {
        let fps = max(1, PowerManager.captureFPSSnapshot)
        let budget = (1000.0 / Double(fps)) * 0.55

        if spent <= budget {
            guard !intervalOverride.isEmpty else { return }
            // Relax gradually; snapping straight back re-triggers the overrun.
            for (k, v) in intervalOverride {
                if v <= 2 { intervalOverride[k] = nil } else { intervalOverride[k] = v - 1 }
            }
            let snapshot = intervalOverride
            DispatchQueue.main.async {
                self.throttled = snapshot
                self.governorNote = snapshot.isEmpty ? nil : self.noteFor(snapshot)
                self.recomputeTotalCost()
            }
            return
        }

        // Stretch the single worst offender per overrun rather than everything at
        // once, so one expensive layer does not drag the cheap ones down with it.
        let ranked = active
            .compactMap { id -> (String, Double)? in
                lock.lock(); let c = costMirror[id] ?? 0; lock.unlock()
                guard c > 1 else { return nil }
                return (id, c)
            }
            .sorted { $0.1 > $1.1 }

        guard let worst = ranked.first else { return }
        let next = min(30, max(2, (intervalOverride[worst.0] ?? 1) + 1))
        intervalOverride[worst.0] = next
        let snapshot = intervalOverride
        DispatchQueue.main.async {
            self.throttled = snapshot
            self.governorNote = self.noteFor(snapshot)
            self.recomputeTotalCost()
        }
    }

    private func noteFor(_ map: [String: Int]) -> String? {
        guard !map.isEmpty else { return nil }
        let names = map.keys.compactMap { layer($0)?.title }.sorted()
        let fps = max(1, PowerManager.captureFPSSnapshot)
        return "Thermal budget reached — \(names.joined(separator: ", ")) now running slower than \(fps)/s to keep the feed smooth."
    }

    /// Recomputed on main whenever a cost or interval changes, rather than
    /// computed on demand from a view. The governor's state lives on the capture
    /// thread, and reading a Swift dictionary while another thread writes it can
    /// crash outright rather than merely returning a stale number.
    private func recomputeTotalCost() {
        let total = activeIDs.reduce(0.0) { sum, id in
            let interval = Double(max(layer(id)?.preferredInterval ?? 1,
                                      throttled[id] ?? 1))
            return sum + (cost[id] ?? 0) / interval
        }
        if abs(total - activeCostMS) > 0.05 { activeCostMS = total }
    }

    /// True when an active layer reads tracks from the main detector. The engine
    /// uses this to keep a light detection pass running even while unarmed, so
    /// zones and counts are not silently dead on an idle camera.
    var needsTracks: Bool {
        let active = liveActiveSnapshot
        return all.contains { active.contains($0.id) && $0 is DerivedAILayer }
    }

    /// True when an active layer composites the image itself, which means the raw
    /// camera preview must come off screen.
    var producesComposite: Bool {
        let active = liveActiveSnapshot
        return all.contains { active.contains($0.id) && $0.group == .privacy }
    }

    /// Does any active layer need audio buffers? The mic is only tapped if so.
    var needsAudio: Bool {
        let active = liveActiveSnapshot
        return all.contains { active.contains($0.id) && $0 is AudioAILayer }
    }
}

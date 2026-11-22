import Foundation

/// One-tap setups.
///
/// Forty-one layers is a menu nobody reads. The honest problem with a system this
/// size is not discovery — every layer is listed — it is that a person pointing a
/// phone at a parking lot has no way to know which eight of them are the right
/// eight. A preset answers that: it is a named job, and choosing it switches on the
/// set that does that job and switches off everything else.
///
/// Each one is deliberately small. A preset that turns on fifteen layers would
/// thermally throttle the phone and teach the operator that the app is slow, so
/// these stay inside the frame budget with room to spare, and the panel still shows
/// the cost so nothing is hidden.
struct LayerPreset: Identifiable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    let layers: [String]
    /// Models these layers will want. Shown up front so a preset never silently
    /// starts a 100 MB download.
    var downloads: [String] {
        layers.compactMap { ModelStore.manifest[$0]?.id }
            + (layers.contains("clip.find") || layers.contains("action")
               || layers.contains("fusion.retrieval") ? ["clip.image", "clip.text"] : [])
    }

    static let all: [LayerPreset] = [
        LayerPreset(
            id: "lot",
            name: "Parking lot",
            detail: "What arrived, where it went, how long it stayed.",
            icon: "car.2",
            layers: ["objects", "tracking", "zones", "lines", "behaviour", "trend",
                     "sound.events"]),

        LayerPreset(
            id: "door",
            name: "Doorway",
            detail: "Who came to the door, and whether you have seen them before.",
            icon: "door.left.hand.closed",
            layers: ["objects", "faces", "faces.identity", "action", "sound.events"]),

        LayerPreset(
            id: "night",
            name: "Night watch",
            detail: "Movement and sound only. Cheapest set that still catches things.",
            icon: "moon.stars",
            layers: ["objects", "tracking", "anomaly", "sound.events", "audio.vad"]),

        LayerPreset(
            id: "read",
            name: "Read everything",
            detail: "Plates, signs, labels and barcodes in view.",
            icon: "text.viewfinder",
            layers: ["anpr", "ocr", "barcodes", "objects"]),

        LayerPreset(
            id: "listen",
            name: "Listen",
            detail: "Transcribe, tell voices apart, and judge the tone.",
            icon: "waveform",
            layers: ["speech.transcript", "audio.diarization", "sound.events",
                     "audio.emotion", "text.keywords"]),

        LayerPreset(
            id: "understand",
            name: "Describe the scene",
            detail: "Names what it is looking at and what people are doing.",
            icon: "eye.square",
            layers: ["objects", "scene", "segmentation.semantic", "action",
                     "fusion.caption"]),

        LayerPreset(
            id: "search",
            name: "Find something",
            detail: "Look for anything you can describe, and search back through it.",
            icon: "sparkle.magnifyingglass",
            layers: ["clip.find", "fusion.retrieval", "objects"]),

        LayerPreset(
            id: "private",
            name: "Privacy first",
            detail: "Watch the scene with every face blurred before it is recorded.",
            icon: "eye.slash",
            layers: ["objects", "tracking", "privacy.blur"]),

        LayerPreset(
            id: "measure",
            name: "Measure",
            detail: "Distance, depth and speed of what is in frame.",
            icon: "ruler",
            layers: ["objects", "tracking", "depth", "depth.mono", "imu"])
    ]

    /// Which preset, if any, the current set of active layers exactly matches.
    static func matching(_ active: Set<String>) -> LayerPreset? {
        all.first { Set($0.layers) == active }
    }

    func apply() {
        let registry = LayerRegistry.shared
        let wanted = Set(layers)
        // Off first, so the frame budget never briefly holds both sets.
        for id in registry.activeIDs where !wanted.contains(id) {
            registry.setActive(id, false)
        }
        for id in layers {
            guard let layer = registry.layer(id), layer.availability.isUsable else { continue }
            registry.setActive(id, true)
        }
        EventLog.action("layers.preset", ["preset": id, "count": layers.count])
    }

    /// Layers in this preset that this device cannot run, with the reason — shown
    /// before applying rather than leaving the operator to wonder why six of
    /// seven came on.
    var unavailable: [(String, String)] {
        layers.compactMap { id in
            guard let layer = LayerRegistry.shared.layer(id) else { return nil }
            guard !layer.availability.isUsable else { return nil }
            return (layer.title, layer.availability.reason ?? "not available here")
        }
    }

    /// Total megabytes this preset will download if nothing is cached yet.
    var downloadMB: Int {
        var seen = Set<String>()
        var bytes = 0
        for id in downloads where !seen.contains(id) {
            seen.insert(id)
            guard case .absent = ModelStore.shared.state(id) else { continue }
            bytes += ModelStore.manifest[id]?.totalBytes ?? 0
        }
        return bytes / 1_000_000
    }
}

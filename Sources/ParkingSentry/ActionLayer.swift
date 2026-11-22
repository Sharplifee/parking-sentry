import Foundation
import CoreGraphics

/// Naming what someone is doing, with no trained action classifier.
///
/// The usual way to do this is a Create ML action classifier over pose sequences,
/// which needs a labelled dataset nobody here has. The other way is zero-shot
/// through CLIP: embed the phrase "a person climbing a fence" once, embed what the
/// camera sees, and compare. That is what this does, and it is worth being exact
/// about what it therefore is and is not.
///
/// What it is: a real, open-ended answer to "what is this person doing", from a
/// prompt list that can be edited without retraining anything, running on device.
///
/// What it is not: motion analysis. CLIP reads appearance, so it sees the posture
/// and the scene, not the movement between frames. It distinguishes someone lying
/// on the ground from someone standing very well, and someone walking from someone
/// running quite poorly. Scores are smoothed over several seconds and compared
/// against a neutral baseline rather than reported raw, because the absolute
/// numbers mean little and only the margin between candidates carries signal.
final class ActionRecognitionLayer: ModelBackedLayer, VideoAILayer {
    let id = "action"
    let title = "Action recognition"
    let detail = "Names what a person is doing, zero-shot through CLIP. Reads posture, not motion."
    let group = LayerGroup.vision
    let modality = LayerModality.video
    var availability: LayerAvailability {
        let image = ModelStore.shared.state("clip.image")
        let text = ModelStore.shared.state("clip.text")
        if case .ready = image, case .ready = text {
            return CLIPTokenizer.shared.ready
                ? .available
                : .modelMissing("The CLIP vocabulary did not load from the app bundle")
        }
        let mb = ((ModelStore.manifest["clip.image"]?.totalBytes ?? 0)
                  + (ModelStore.manifest["clip.text"]?.totalBytes ?? 0)) / 1_000_000
        return .needsDownload("Needs \(mb) MB of CLIP models — switch on to download once")
    }
    let preferredInterval = 15
    let warmAtLaunch = false

    /// The candidate set. Phrased the way CLIP was trained — a plain caption of a
    /// photograph — because prompt wording moves these scores more than anything
    /// else does. The last few are the ones a sentry camera actually cares about.
    private static let actions: [(phrase: String, label: String, notable: Bool)] = [
        ("a photo of a person standing still",                 "standing",        false),
        ("a photo of a person walking",                        "walking",         false),
        ("a photo of a person running",                        "running",         true),
        ("a photo of a person sitting down",                   "sitting",         false),
        ("a photo of a person lying on the ground",            "on the ground",   true),
        ("a photo of a person crouching down low",             "crouching",       true),
        ("a photo of a person climbing over a fence or wall",  "climbing",        true),
        ("a photo of two people fighting",                     "fighting",        true),
        ("a photo of a person carrying a large object",         "carrying something", false),
        ("a photo of a person looking into a car window",      "looking into a car", true),
        ("a photo of a person pulling on a door handle",       "trying a door",   true),
        ("a photo of a person taking photographs",             "photographing",   false),
        ("a photo of a person riding a bicycle",               "cycling",         false),
        ("a photo of a person walking a dog",                  "walking a dog",   false),
        ("a photo of an empty scene with no people",           "nobody",          false)
    ]

    /// Rolling score per action, so a single frame cannot decide.
    private var history: [String: [Float]] = [:]
    private var lastReport = Date.distantPast
    private var reported = ""

    init() { super.init(modelID: "clip.image") }

    override func ensureModel() {
        for id in ["clip.image", "clip.text"] {
            if case .ready = ModelStore.shared.state(id) { continue }
            ModelStore.shared.fetch(id)
        }
    }

    func warm() {
        ensureModel()
        CLIPEngine.shared.prepare()
    }

    func cool() { history.removeAll() }

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        guard CLIPEngine.shared.imageReady, CLIPEngine.shared.textReady else {
            ensureModel()
            return nil
        }

        // Prefer the largest person in frame: a crop of them scores far more
        // sharply than the whole scene, where a parked car and a building dominate
        // whatever the person is doing.
        let people = ctx.subjects
            .filter { $0.category == .person }
            .sorted { $0.boundingBox.height > $1.boundingBox.height }

        var vector: [Float]?
        var anchor: CGRect?
        if let subject = people.first, subject.boundingBox.height > 0.1 {
            vector = CLIPEngine.shared.embed(crop: subject.boundingBox, of: ctx.pixelBuffer)
            anchor = subject.boundingBox
        } else {
            vector = CLIPEngine.shared.embed(image: ctx.pixelBuffer)
        }
        guard let vector else { return nil }

        // Score every candidate. The text embeddings are cached, so after the
        // first run this is fifteen dot products, not fifteen model calls.
        var scores: [(String, Float, Bool)] = []
        for action in ActionRecognitionLayer.actions {
            guard let target = CLIPEngine.shared.embed(text: action.phrase) else { continue }
            scores.append((action.label, CLIPEngine.similarity(target, vector), action.notable))
        }
        guard scores.count > 3 else { return nil }

        for (label, score, _) in scores {
            var series = history[label] ?? []
            series.append(score)
            if series.count > 8 { series.removeFirst() }
            history[label] = series
        }

        let smoothed = scores.compactMap { (label, _, notable) -> (String, Float, Bool)? in
            guard let series = history[label], !series.isEmpty else { return nil }
            return (label, series.reduce(0, +) / Float(series.count), notable)
        }.sorted { $0.1 > $1.1 }

        guard let best = smoothed.first, let runnerUp = smoothed.dropFirst().first else { return nil }
        // The margin is what matters. CLIP's absolute similarities sit in a narrow
        // band, so a win by 0.001 means the model cannot tell, and saying
        // "fighting" on that basis would be worse than saying nothing.
        let margin = best.1 - runnerUp.1

        var out = LayerOutput()
        let confident = margin > 0.012 && best.0 != "nobody"
        out.badge = confident ? best.0 : "unclear"

        if confident, let anchor {
            out.shapes = [.box(anchor, label: best.0, tint: best.2 ? .alert : .person)]
        }

        if confident, best.0 != reported, Date().timeIntervalSince(lastReport) > 8 {
            reported = best.0
            lastReport = Date()
            let line = String(format: "%@ (margin %.3f over \"%@\")", best.0, margin, runnerUp.0)
            out.lines = [line]
            TextBus.shared.add("someone appears to be \(best.0)", source: "action")
            // Only the ones worth waking someone for, and only on a clear margin.
            if best.2, margin > 0.02 {
                out.alert = "Possible \(best.0)"
            }
        }
        return out
    }
}

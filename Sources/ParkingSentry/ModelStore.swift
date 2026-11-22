import Foundation
import CoreML
import Combine

/// Downloads, compiles and caches the Core ML models that Apple's own frameworks
/// do not provide.
///
/// Why on demand rather than bundled: these four models are 175 MB together, and
/// bundling them would mean every install pays for every capability whether it is
/// used or not. Downloading on first toggle keeps the app small and means a layer
/// nobody switches on costs nothing.
///
/// Why compiled on device: a `.mlpackage` has to be compiled to `.mlmodelc` before
/// Core ML will load it, and that compilation normally happens in Xcode on a Mac.
/// `MLModel.compileModel(at:)` does the same thing at runtime, which is what makes
/// a no-Mac pipeline possible at all. Compilation happens once and the result is
/// cached in Application Support, so the second launch is instant.
///
/// Sources are pinned to a commit SHA rather than a branch, and every file's exact
/// byte count is checked after download. A model that silently changed upstream, or
/// a truncated download, would otherwise fail at inference time as a wrong-shaped
/// output rather than as an honest error here.
final class ModelStore: ObservableObject {

    static let shared = ModelStore()

    // MARK: Catalog

    struct Remote {
        let id: String
        let title: String
        /// A `.mlpackage` is a directory, so each model is several files that get
        /// reassembled into that structure locally.
        let files: [(path: String, bytes: Int)]
        /// Everything before the package name. Hugging Face for Apple's own
        /// conversions, this repository for the ones converted here.
        let base: String
        let packageName: String
        let license: String

        var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

        func url(for path: String) -> URL? {
            URL(string: "\(base)/\(packageName)/\(path)")
        }
    }

    static let manifest: [String: Remote] = {
        let standard = [("Data/com.apple.CoreML/model.mlmodel", 0),
                        ("Data/com.apple.CoreML/weights/weight.bin", 0),
                        ("Manifest.json", 617)]
        _ = standard

        func make(_ id: String, _ title: String, repo: String, sha: String,
                  pkg: String, model: Int, weights: Int, license: String) -> Remote {
            Remote(id: id, title: title,
                   files: [("Data/com.apple.CoreML/model.mlmodel", model),
                           ("Data/com.apple.CoreML/weights/weight.bin", weights),
                           ("Manifest.json", 617)],
                   base: "https://huggingface.co/\(repo)/resolve/\(sha)",
                   packageName: pkg, license: license)
        }

        /// Models converted from ONNX here and committed to this repository.
        /// Pinned by exact byte count rather than by commit, since the branch is
        /// one I control and the size check still catches a truncated download.
        func mine(_ id: String, _ title: String, pkg: String,
                  model: Int, weights: Int, license: String) -> Remote {
            Remote(id: id, title: title,
                   files: [("Data/com.apple.CoreML/model.mlmodel", model),
                           ("Data/com.apple.CoreML/weights/weight.bin", weights),
                           ("Manifest.json", 617)],
                   base: "https://raw.githubusercontent.com/Sharplifee/parking-sentry/main/Models",
                   packageName: pkg, license: license)
        }

        return [
            "depth.mono": make(
                "depth.mono", "Monocular depth",
                repo: "apple/coreml-depth-anything-v2-small",
                sha: "cfef6f6f2a70783dedc0bfae40cecbc2052285d3",
                pkg: "DepthAnythingV2SmallF16INT8.mlpackage",
                model: 427_587, weights: 24_967_424, license: "Apache-2.0"),

            "segmentation.semantic": make(
                "segmentation.semantic", "Semantic segmentation",
                repo: "apple/coreml-detr-semantic-segmentation",
                sha: "7c771f8867a479d1441ac5fb0a8de31feea76bb6",
                pkg: "DETRResnet50SemanticSegmentationF16INT8.mlpackage",
                model: 353_974, weights: 43_005_024, license: "Apache-2.0"),

            "clip.image": make(
                "clip.image", "Image understanding (CLIP)",
                repo: "apple/coreml-mobileclip",
                sha: "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947",
                pkg: "mobileclip_s0_image.mlpackage",
                model: 153_260, weights: 22_717_696, license: "Apple ML Research"),

            "clip.text": make(
                "clip.text", "Text understanding (CLIP)",
                repo: "apple/coreml-mobileclip",
                sha: "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947",
                pkg: "mobileclip_s0_text.mlpackage",
                model: 57_953, weights: 84_871_616, license: "Apple ML Research"),

            "faces.identity": mine(
                "faces.identity", "Face recognition",
                pkg: "FaceEmbedding.mlpackage",
                model: 48_315, weights: 19_296_256,
                license: "SFace, OpenCV Zoo"),

            "faces.age": mine(
                "faces.age", "Age bracket",
                pkg: "AgeBracket.mlpackage",
                model: 113_010, weights: 11_971_200,
                license: "Levi & Hassner, ONNX Model Zoo, Apache-2.0"),

            "faces.gender": mine(
                "faces.gender", "Gender estimate",
                pkg: "GenderClass.mlpackage",
                model: 113_007, weights: 11_958_912,
                license: "Levi & Hassner, ONNX Model Zoo, Apache-2.0"),

            "audio.diarization": mine(
                "audio.diarization", "Speaker voice prints",
                pkg: "SpeakerEmbedding.mlpackage",
                model: 59_260, weights: 13_264_960,
                license: "WeSpeaker, CC-BY-4.0"),

            "faces.emotion": mine(
                "faces.emotion", "Facial expression",
                pkg: "FacialEmotion.mlpackage",
                model: 21_289, weights: 17_517_056,
                license: "FER+, Apache-2.0")
        ]
    }()

    // MARK: State

    enum State: Equatable {
        case absent
        case downloading(Double)      // 0–1
        case compiling
        case ready
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    /// Lock-protected mirror of `states`.
    ///
    /// `states` is `@Published` and every write to it hops to the main thread, but
    /// `state(_:)` is called from layer `availability` and `warm()`, which run on
    /// the capture queue. Reading a Swift dictionary while another thread
    /// reassigns it is not a stale read, and State carries a String in its
    /// `.failed` case, so there is a refcounted object in there too.
    private var stateMirror: [String: State] = [:]
    /// Loaded models, kept alive so a toggle does not reload from disk.
    private var loaded: [String: MLModel] = [:]
    private let lock = NSLock()
    private var inFlight = Set<String>()

    private init() {
        for id in ModelStore.manifest.keys {
            let state: State = compiledURL(for: id) != nil ? .ready : .absent
            states[id] = state
            stateMirror[id] = state
        }
    }

    /// Single place that moves a state, so the published copy and the mirror can
    /// never disagree.
    private func setState(_ id: String, _ state: State) {
        lock.lock(); stateMirror[id] = state; lock.unlock()
        DispatchQueue.main.async { self.states[id] = state }
    }

    // MARK: Paths

    private var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func packageURL(for id: String) -> URL? {
        guard let remote = ModelStore.manifest[id] else { return nil }
        return root.appendingPathComponent(remote.packageName, isDirectory: true)
    }

    /// The compiled model, if it is already on disk.
    private func compiledURL(for id: String) -> URL? {
        let url = root.appendingPathComponent("\(id).mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Access

    /// The model if it is ready, otherwise nil. Never blocks and never downloads —
    /// a layer calls this every frame, so it has to be cheap and non-committal.
    func model(_ id: String) -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        return loaded[id]
    }

    func state(_ id: String) -> State {
        lock.lock(); defer { lock.unlock() }
        return stateMirror[id] ?? .absent
    }

    func isReady(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded[id] != nil
    }

    /// Loads a model already compiled on disk. Called at launch for anything the
    /// operator has downloaded before, so a previously used layer is warm.
    func loadIfPresent(_ id: String) {
        lock.lock()
        let already = loaded[id] != nil
        lock.unlock()
        guard !already, let compiled = compiledURL(for: id) else { return }

        DispatchQueue.global(qos: .utility).async {
            do {
                let config = MLModelConfiguration()
                // All compute units: the Neural Engine is the whole point, and
                // Core ML falls back to GPU or CPU on its own where an operation
                // is not supported there.
                config.computeUnits = .all
                let model = try MLModel(contentsOf: compiled, configuration: config)
                self.lock.lock(); self.loaded[id] = model; self.lock.unlock()
                self.setState(id, .ready)
                EventLog.action("model.loaded", ["model": id])
            } catch {
                // A compiled model that will not load is usually a half-written
                // cache from an interrupted compile. Clearing it means the next
                // request re-downloads rather than failing forever.
                try? FileManager.default.removeItem(at: compiled)
                self.setState(id, .absent)
                EventLog.error(error, name: "model.load.failed", ["model": id])
            }
        }
    }

    /// Download, verify, compile and load. Safe to call repeatedly; only one
    /// attempt per model runs at a time.
    func fetch(_ id: String) {
        guard let remote = ModelStore.manifest[id] else { return }
        lock.lock()
        let busy = inFlight.contains(id) || loaded[id] != nil
        if !busy { inFlight.insert(id) }
        lock.unlock()
        guard !busy else { return }

        if let compiled = compiledURL(for: id) {
            _ = compiled
            lock.lock(); inFlight.remove(id); lock.unlock()
            loadIfPresent(id)
            return
        }

        setState(id, .downloading(0))
        let job = EventLog.job("model.fetch")

        DispatchQueue.global(qos: .utility).async {
            defer { self.lock.lock(); self.inFlight.remove(id); self.lock.unlock() }
            guard let package = self.packageURL(for: id) else { return }

            do {
                // Download into a staging directory and move into place only once
                // every file has arrived and checked out, so an interrupted
                // download can never leave a package that looks complete.
                let staging = self.root.appendingPathComponent("staging-\(id)", isDirectory: true)
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

                var done = 0
                for file in remote.files {
                    guard let url = remote.url(for: file.path) else {
                        throw Failure("could not build a URL for \(file.path)")
                    }
                    let data = try self.download(url)
                    if file.bytes > 0, data.count != file.bytes {
                        throw Failure("\(file.path) is \(data.count) bytes, expected \(file.bytes) — the upstream model changed or the download was truncated")
                    }
                    let dest = staging.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: dest)

                    done += data.count
                    let fraction = Double(done) / Double(max(1, remote.totalBytes))
                    self.setState(id, .downloading(fraction))
                }

                try? FileManager.default.removeItem(at: package)
                try FileManager.default.moveItem(at: staging, to: package)

                self.setState(id, .compiling)
                // The step that normally needs Xcode on a Mac.
                let compiledTemp = try MLModel.compileModel(at: package)
                let compiled = self.root.appendingPathComponent("\(id).mlmodelc", isDirectory: true)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: compiledTemp, to: compiled)
                // The .mlpackage is dead weight once compiled — tens of megabytes
                // of it — so it goes.
                try? FileManager.default.removeItem(at: package)

                let config = MLModelConfiguration()
                config.computeUnits = .all
                let model = try MLModel(contentsOf: compiled, configuration: config)
                self.lock.lock(); self.loaded[id] = model; self.lock.unlock()
                self.setState(id, .ready)
                job.end(["model": id])
                EventLog.action("model.ready", ["model": id])
            } catch {
                self.setState(id, .failed(error.localizedDescription))
                job.fail(error)
            }
        }
    }

    /// Removes a model from disk. The operator may well want 175 MB back.
    func remove(_ id: String) {
        lock.lock(); loaded[id] = nil; inFlight.remove(id); lock.unlock()
        if let compiled = compiledURL(for: id) {
            try? FileManager.default.removeItem(at: compiled)
        }
        if let package = packageURL(for: id) {
            try? FileManager.default.removeItem(at: package)
        }
        setState(id, .absent)
        EventLog.action("model.removed", ["model": id])
    }

    var diskUsed: Int64 {
        guard let items = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else {
            return 0
        }
        return items.reduce(Int64(0)) { total, sub in
            let path = root.appendingPathComponent(sub).path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    // MARK: Download

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// Synchronous on purpose: this runs on a utility queue and the sequencing
    /// (file after file, then compile) is far easier to follow than a chain of
    /// completion handlers, with no benefit lost.
    private func download(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("MotionSentry", forHTTPHeaderField: "User-Agent")

        var result: Data?
        var failure: Error?
        let done = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                failure = Failure("HTTP \(code) fetching \(url.lastPathComponent)")
                return
            }
            result = data
        }.resume()

        // Generous: the largest single file here is 85 MB and a phone on a weak
        // connection is a normal case, not a failure.
        guard done.wait(timeout: .now() + 600) == .success else {
            throw Failure("timed out fetching \(url.lastPathComponent)")
        }
        if let failure { throw failure }
        guard let result else { throw Failure("no data for \(url.lastPathComponent)") }
        return result
    }
}

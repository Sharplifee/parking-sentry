import AVFoundation
import Vision
import CoreImage
import UIKit
import Combine

struct SentryEvent: Identifiable {
    let id: UUID
    let date: Date
    let text: String
    let rangeMeters: Double?
    let thumbnail: UIImage?
    let alerted: Bool
    /// The recording this detection produced, once it exists.
    var clipURL: URL?
}

struct BoxOverlay: Identifiable {
    let id: Int
    let rect: CGRect          // normalized, origin bottom-left
    let label: String
    let confirmed: Bool
    let category: SubjectCategory
}

final class DetectionEngine: NSObject, ObservableObject {

    /// Set on init so a remote arm/disarm arriving over the peer link has
    /// something to act on. One engine per app, so this is safe.
    static private(set) weak var shared: DetectionEngine?

    /// The external-display view needs a concrete object to observe. The app
    /// always creates exactly one engine at launch, so this resolves to it;
    /// the fallback only exists so the type is non-optional.
    @MainActor static var sharedOrPlaceholder: DetectionEngine {
        if let s = shared { return s }
        let made = DetectionEngine()
        return made
    }

    // MARK: Published state
    @Published var isRunning = false
    @Published var isArmed = false
    @Published var armCountdown: Int = 0
    @Published var status = "Idle"
    @Published var motionScore: Float = 0
    @Published var shadowRejectFraction: Float = 0
    @Published var rangeSourceLabel = "—"
    @Published var overlays: [BoxOverlay] = []
    @Published var events: [SentryEvent] = []
    @Published var depthAvailable = false
    @Published var visionHz: Double = 0
    @Published var modelStatus = "loading"
    @Published var previewLive = false
    /// Non-nil when the camera could not be brought up. Shown on screen, because
    /// the alternative — a black rectangle and a status nobody reads — is what
    /// made an iPad look identical to a working device that just saw darkness.
    @Published var cameraProblem: String?
    @Published var clipURLs: [URL] = []
    private var eventsAwaitingClip: [UUID] = []
    @Published var usingFrontCamera = false
    @Published var zoom: CGFloat = 1
    @Published var minZoom: CGFloat = 1
    @Published var maxZoom: CGFloat = 1
    @Published var soundLevelDB: Float = 0
    @Published var ambientDB: Float = 0

    // MARK: Through-glass occupancy
    /// Amplified movement inside the drawn window, 0–1.
    @Published var glassActivity: Double = 0
    /// Fraction of the last few seconds that showed movement. This, not a
    /// single frame, is what the verdict rests on.
    @Published var glassSustained: Double = 0
    /// This frame's change was one coherent sweep — a reflection, discarded.
    @Published var glassGlare = false
    /// Mean brightness inside the window, 0–1. Near zero means the exposure
    /// lock is not opening the glass up and nothing can be recovered.
    @Published var glassExposure: Double = 0
    @Published var glassContrast: Double = 0
    @Published var glassVerdict = "Draw a box over the window"
    /// True once sustained movement clears the threshold.
    @Published var glassOccupied = false
    /// The window, stretched and with moving cells tinted. The thing to look at.
    @Published var glassImage: UIImage?

    /// Set when a privacy layer is compositing. While this is non-nil the raw
    /// camera preview is off screen and this is what the operator sees, so there
    /// is no unredacted layer underneath to show through on a dropped frame.
    @Published var composedFrame: UIImage?


    // MARK: Capture
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "sentry.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var previewRotationObservation: NSKeyValueObservation?
    private var sessionObservers: [NSObjectProtocol] = []
    /// The live preview layer, handed over by the view. The rotation coordinator
    /// needs it: built with nil, the preview connection is never rotated, so on
    /// iPad in landscape the picture and the detection buffers disagree and every
    /// overlay box lands in the wrong place.
    weak var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet { sessionQueue.async { [weak self] in self?.rebuildRotationCoordinator() } }
    }

    // MARK: Pipeline
    private let gate = MotionGate()
    private let detector = SubjectDetector()
    private let ranger = DistanceEstimator()
    private let audio = AudioMonitor()
    private let clips = ClipRecorder()
    private let tracker = Tracker()
    private var frameIndex = 0
    /// This frame's detections, kept so derived layers can read them without the
    /// detector running a second time.
    private var lastSubjects: [DetectedSubject] = []
    private var lastLayerDetect = Date.distantPast
    private var lastLayerAlert: [String: Date] = [:]
    private let glass = ThroughGlassAnalyzer()
    private var lastGlassRender: Date = .distantPast
    private var lastGlassAlert: Date = .distantPast
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var settings: Settings { Settings.shared }
    private var armAt: Date = .distantFuture
    private var lastVisionRun: Date = .distantPast
    private var lastForcedVision: Date = .distantPast
    private var visionTimestamps: [Date] = []

    /// Horizontal field of view of the active format, in radians per unit of normalized x.
    private var fovRadians: Double = 60 * .pi / 180

    /// Refreshed from the power budget instead of being a fixed ceiling.
    private var visionIntervalNow: TimeInterval = 0.14
    private let forcedVisionInterval: TimeInterval = 2.0 // catch slow creep the gate missed

    override init() {
        super.init()
        DetectionEngine.shared = self
        visionIntervalNow = PowerManager.visionIntervalSnapshot
        PowerManager.onBudgetChange = { [weak self] in
            guard let self else { return }
            self.visionIntervalNow = PowerManager.visionIntervalSnapshot
            self.applyPowerBudget()
        }
        ClipRecorder.prune()
        clips.onClipFinished = { [weak self] url in
            guard let self else { return }
            if !self.clipURLs.contains(url) { self.clipURLs.insert(url, at: 0) }
        }
        clips.onClipAssigned = { [weak self] tag, url in
            guard let self, let i = self.events.firstIndex(where: { $0.id == tag }) else { return }
            self.events[i].clipURL = url
        }
        clipURLs = ClipRecorder.existingClips()
        modelStatus = detector.modelLoaded
            ? "YOLOv3-Tiny"
            : "model failed: " + (detector.modelLoadError ?? "unknown")
    }

    // MARK: Lifecycle

    /// Bring the camera up without arming anything. Without this the screen is
    /// simply black until you tap Arm, which reads as a broken app and gives you
    /// no way to frame the shot before starting.
    func startPreview() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            reallyStartPreview()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.reallyStartPreview() }
                else { DispatchQueue.main.async {
                    self.cameraProblem = "Camera access was declined. Enable it in Settings → MotionSentry."
                } }
            }
        default:
            cameraProblem = "Camera access is off for MotionSentry. Turn it on in Settings → MotionSentry."
        }
        // The mic is used for sound triggering and the intercom; ask once here
        // so the first push-to-talk isn't the thing that surprises you.
        if AVAudioApplication.shared.recordPermission == .undetermined {
            AVAudioApplication.requestRecordPermission { _ in }
        }
    }

    private func reallyStartPreview() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }
            if self.session.inputs.isEmpty { self.configure() }
            // Starting a session with no inputs yields a black rectangle and no
            // error; refuse instead so the reason reaches the screen.
            guard !self.session.inputs.isEmpty else {
                DispatchQueue.main.async { self.previewLive = false }
                return
            }
            self.session.startRunning()
            DispatchQueue.main.async {
                self.previewLive = self.session.isRunning
                if self.session.isRunning { self.cameraProblem = nil }
            }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            do { try self.audio.start() } catch { print("audio monitor failed: \(error)") }
            DispatchQueue.main.async {
                MeshClient.shared.register(hasLiDAR: self.depthAvailable, hasTrueDepth: self.depthAvailable)
                self.startHeartbeat()
                // Link already runs from launch; nothing to start here.
            }
            DispatchQueue.main.async {
                // Only hold the screen awake while actually watching for something.
                UIApplication.shared.isIdleTimerDisabled = true
                self.isRunning = true
                self.status = "Learning background"
                self.tracker.reset()
                self.gate.reset()
                self.armAt = Date().addingTimeInterval(self.settings.armDelaySeconds)
                self.isArmed = false
                self.tickCountdown()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Leave the capture session running so the preview stays up; only
            // detection, alerting and the peer broadcast stop.
            self.audio.stop()
            // Keep the peer link up after disarming so the device stays
            // watchable and can be re-armed remotely.
            DispatchQueue.main.async {
                self.stopHeartbeat()
                // Let the device sleep again once disarmed.
                if !RemoteControl.shared.stealth {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.isArmed = false
                self.status = "Idle"
                self.overlays = []
                AlertManager.shared.stopSiren()
            }
        }
    }

    func restartForSettingsChange() {
        guard isRunning else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            for i in self.session.inputs { self.session.removeInput(i) }
            for o in self.session.outputs { self.session.removeOutput(o) }
            self.synchronizer = nil
            self.configure()
            self.session.startRunning()
            DispatchQueue.main.async {
                self.gate.reset()
                self.tracker.reset()
                self.armAt = Date().addingTimeInterval(self.settings.armDelaySeconds)
                self.isArmed = false
                self.tickCountdown()
            }
        }
    }

    private func tickCountdown() {
        let remaining = Int(ceil(armAt.timeIntervalSinceNow))
        armCountdown = max(0, remaining)
        if remaining <= 0 {
            isArmed = true
            status = "Armed"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isRunning else { return }
            self.tickCountdown()
        }
    }

    // MARK: Session configuration

    private func configure() {
        session.beginConfiguration()

        guard attachCamera() else { session.commitConfiguration(); return }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Without this the ranging math has no focal length to work with.
        if let vc = videoOutput.connection(with: .video),
           vc.isCameraIntrinsicMatrixDeliverySupported {
            vc.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        var haveDepth = false
        if !session.outputs.contains(depthOutput), session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true
            if let dc = depthOutput.connection(with: .depthData), dc.isEnabled {
                haveDepth = true
            } else {
                session.removeOutput(depthOutput)
            }
        } else if session.outputs.contains(depthOutput) {
            haveDepth = depthOutput.connection(with: .depthData)?.isEnabled ?? false
        }

        if haveDepth {
            let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            sync.setDelegate(self, queue: sessionQueue)
            synchronizer = sync
        } else {
            synchronizer = nil
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }

        DispatchQueue.main.async { self.observeSessionHealth() }
        rebuildRotationCoordinator()

        // Mirroring must be identical on the preview and on the frames Vision
        // sees, or the boxes are horizontally flipped on the front camera.
        for c in [videoOutput.connection(with: .video), previewLayer?.connection].compactMap({ $0 }) {
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        let ml = detector.modelLoaded ? "YOLOv3-Tiny" : ("model failed: " + (detector.modelLoadError ?? "unknown"))
        DispatchQueue.main.async {
            self.depthAvailable = haveDepth
            self.modelStatus = ml
        }
    }

    /// Rebuilt whenever the device or the preview layer changes. Capture and
    /// preview get their own angles — they are not always the same value.
    /// The camera can be taken away at any time — another app claims it, the
    /// device is in Split View, a call arrives. None of that raises an error on
    /// the session, so without these observers the app just shows black forever
    /// and blames permissions.
    private func observeSessionHealth() {
        let center = NotificationCenter.default
        sessionObservers.forEach { center.removeObserver($0) }
        sessionObservers.removeAll()

        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: .main) { [weak self] note in
                guard let self else { return }
                let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
                let reason = AVCaptureSession.InterruptionReason(rawValue: raw)
                self.cameraProblem = Self.describe(reason)
                self.previewLive = false
        })

        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.cameraProblem = nil
                // The session does not always resume itself.
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    DispatchQueue.main.async { self.previewLive = self.session.isRunning }
                }
        })

        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: .main) { [weak self] note in
                guard let self else { return }
                let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self.cameraProblem = "Camera stopped: \(err?.localizedDescription ?? "unknown error"). Reopening usually clears it."
                self.previewLive = false
                // Media-services-reset is recoverable by restarting the session.
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    DispatchQueue.main.async {
                        if self.session.isRunning {
                            self.previewLive = true
                            self.cameraProblem = nil
                        }
                    }
                }
        })
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "iPadOS took the camera because MotionSentry is sharing the screen. Make it full screen — close Split View or Slide Over — and the picture returns."
        case .videoDeviceInUseByAnotherClient:
            return "Another app is using the camera. Close it and MotionSentry will pick the camera back up."
        case .videoDeviceNotAvailableInBackground:
            return "The camera pauses while MotionSentry is in the background."
        case .audioDeviceInUseByAnotherClient:
            return "Another app is using the microphone."
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "The device is too hot or under heavy load, so the camera paused. It resumes once it cools."
        default:
            return "The camera was interrupted by the system."
        }
    }

    /// Swap between the front and back camera without tearing the session down.
    func flipCamera() {
        // Settings is a @Published ObservableObject: mutating it off the main
        // thread is undefined and silently did nothing when the flip arrived
        // from another device.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settings.useFrontCamera.toggle()
            self.performFlip()
        }
    }

    private func performFlip() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            self.attachCamera()
            self.session.commitConfiguration()
            // The new lens has its own orientation and mirroring; outputs stay
            // attached, but their connections must be re-pointed at it.
            self.rebuildRotationCoordinator()
            for c in [self.videoOutput.connection(with: .video),
                      self.previewLayer?.connection].compactMap({ $0 }) {
                if c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = false
                }
            }
            DispatchQueue.main.async {
                self.usingFrontCamera = self.settings.useFrontCamera
                self.gate.reset()
                self.tracker.reset()
            }
        }
    }

    /// Pinch-to-zoom, clamped to what the lens actually supports.
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let cam = self.device else { return }
            let clamped = max(cam.minAvailableVideoZoomFactor,
                              min(factor, min(cam.maxAvailableVideoZoomFactor, 12)))
            try? cam.lockForConfiguration()
            cam.videoZoomFactor = clamped
            cam.unlockForConfiguration()
            DispatchQueue.main.async {
                self.zoom = clamped
                self.settings.zoomFactor = Double(clamped)
            }
        }
    }


    /// Pick, open and configure a camera and add it to the session.
    /// Shared by first-time setup and by flipping, so the two can never drift.
    @discardableResult
    private func attachCamera() -> Bool {
        let position: AVCaptureDevice.Position = settings.useFrontCamera ? .front : .back
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]

        var found = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                     mediaType: .video,
                                                     position: position).devices
        if found.isEmpty {
            // iPads vary far more than iPhones in which camera types they expose;
            // fall back to any camera at all rather than showing black.
            found = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera,
                              .builtInTrueDepthCamera, .builtInLiDARDepthCamera],
                mediaType: .video, position: .unspecified).devices
        }
        guard let cam = found.first else {
            DispatchQueue.main.async {
                self.cameraProblem = "No camera available on this device."
            }
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
            DispatchQueue.main.async {
                self.cameraProblem = "This device's camera could not be opened. Close any other app using it and reopen MotionSentry."
            }
            return false
        }
        session.addInput(input)
        device = cam

        // Preset is chosen HERE, after the input exists. Asked before, the
        // session has no device to validate against and answers yes to almost
        // anything — which is how an iPad ended up "running" at 4K it cannot
        // actually deliver, showing a black frame with no error.
        let wantsHighRes = settings.longRangeMode && PowerManager.allowHighResSnapshot
        let ladder: [AVCaptureSession.Preset] = wantsHighRes
            ? [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
            : [.hd1920x1080, .hd1280x720, .high]
        if let usable = ladder.first(where: { session.canSetSessionPreset($0) }) {
            session.sessionPreset = usable
        } else {
            session.sessionPreset = .high
        }

        // Focal length for ranging: intrinsics when the connection supplies
        // them, field of view as the fallback. Re-read on every attach because
        // the front and back lenses are not the same.
        ranger.horizontalFOVDegrees = Double(cam.activeFormat.videoFieldOfView)
        fovRadians = Double(cam.activeFormat.videoFieldOfView) * .pi / 180

        try? cam.lockForConfiguration()
        if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
        if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
        if cam.isLowLightBoostSupported { cam.automaticallyEnablesLowLightBoostWhenAvailable = true }
        cam.videoZoomFactor = max(cam.minAvailableVideoZoomFactor,
                                  min(CGFloat(settings.zoomFactor), cam.maxAvailableVideoZoomFactor))
        applyFrameRate(to: cam)
        cam.unlockForConfiguration()

        // Re-apply after every attach: flipping the camera or changing a preset
        // rebuilds the input and hands back a device on full auto-exposure,
        // which would quietly turn the mode off while the UI still said it was on.
        if settings.glassMode {
            glass.reset()
            ThroughGlassAnalyzer.configureCameraForGlass(cam, enabled: true,
                                                         frameDuration: cam.activeVideoMinFrameDuration)
        }

        DispatchQueue.main.async {
            self.usingFrontCamera = (cam.position == .front)
            self.minZoom = cam.minAvailableVideoZoomFactor
            self.maxZoom = min(cam.maxAvailableVideoZoomFactor, 12)
            self.zoom = cam.videoZoomFactor
        }
        return true
    }

    /// Clamp the sensor to the rate the current power budget allows. Must be
    /// called inside a lockForConfiguration block.
    private func applyFrameRate(to cam: AVCaptureDevice) {
        var target = PowerManager.captureFPSSnapshot
        // Through-glass needs a long exposure, and iOS will not let exposure
        // exceed the frame duration. 15 fps buys 1/15 s of light collection,
        // which is the whole point of the mode; movement inside a parked car
        // does not need 30 fps to be seen.
        if settings.glassMode { target = min(target, 15) }
        let ranges = cam.activeFormat.videoSupportedFrameRateRanges
        guard let range = ranges.first else { return }
        let fps = Double(max(Int(range.minFrameRate), min(target, Int(range.maxFrameRate))))
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        cam.activeVideoMinFrameDuration = duration
        cam.activeVideoMaxFrameDuration = duration
    }

    /// Re-apply the frame rate when the power budget shifts — hot device, Low
    /// Power Mode, or someone opening a live feed.
    func applyPowerBudget() {
        sessionQueue.async { [weak self] in
            guard let self, let cam = self.device else { return }
            try? cam.lockForConfiguration()
            self.applyFrameRate(to: cam)
            cam.unlockForConfiguration()
        }
    }

    private func rebuildRotationCoordinator() {
        guard let cam = device else { return }
        let layer = previewLayer
        let coordinator = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: layer)
        rotationCoordinator = coordinator

        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)

        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                   options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            self?.sessionQueue.async { self?.applyRotation(angle) }
        }
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                          options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let c = previewLayer?.connection, c.isVideoRotationAngleSupported(angle) else { return }
        c.videoRotationAngle = angle
    }

    private func applyRotation(_ angle: CGFloat) {
        if let c = videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
            c.videoRotationAngle = angle
        }
        if let c = depthOutput.connection(with: .depthData), c.isVideoRotationAngleSupported(angle) {
            c.videoRotationAngle = angle
        }
    }

    // MARK: Frame processing

    private func handle(sampleBuffer: CMSampleBuffer, depth: AVDepthData?) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Rolling pre-roll buffer: fed always while armed so a clip can start
        // seconds BEFORE the trigger. A clip that begins at the detection has
        // already missed the approach, which is the part worth seeing.
        // Recording happens after the layer pass below when a privacy layer is
        // compositing, so the clip holds the redacted frame rather than the raw one.
        let willRedact = settings.blurRecordings && LayerRegistry.shared.producesComposite
        if isRunning, settings.recordClips, !willRedact { clips.ingest(sampleBuffer) }

        ranger.updateIntrinsics(from: sampleBuffer,
                                bufferWidth: CVPixelBufferGetWidth(pixelBuffer),
                                bufferHeight: CVPixelBufferGetHeight(pixelBuffer))

        frameIndex += 1

        // The layer system runs on the plain feed, armed or not: a toggled-on
        // layer that only works while armed would be a surprise, and reading a
        // scene is a different act from watching it for intruders.
        let composite = runLayers(pixelBuffer: pixelBuffer, depth: depth,
                                  sampleBuffer: sampleBuffer)

        // Stream to any connected device whether or not detection is armed.
        // Watching a camera and arming it are different things: gating video on
        // "armed" meant two paired devices saw each other and no picture.
        // PeerMesh throttles and downscales internally, so detection still gets
        // the full-resolution buffer.
        if let composite, settings.blurRecordings {
            if isRunning, settings.recordClips {
                clips.ingest(redacted: composite,
                             at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            }
            PeerMesh.shared.offer(redacted: composite, status: liveStatusLine())
        } else {
            PeerMesh.shared.offer(frame: pixelBuffer, status: liveStatusLine())
        }

        // Through-glass occupancy replaces the whole detection pipeline rather
        // than running alongside it: Vision has nothing to classify through 5%
        // tint, and the motion gate is tuned to ignore exactly the sub-percent
        // luminance changes this mode exists to find. It runs unarmed too, so
        // you can point the device at a car and read it immediately.
        if settings.glassMode {
            handleGlass(pixelBuffer: pixelBuffer)
            return
        }

        // Idle: preview and streaming only. No gate, no Vision.
        guard isRunning else { return }

        let motion = gate.process(pixelBuffer: pixelBuffer)
        DispatchQueue.main.async {
            self.motionScore = motion.score
            self.shadowRejectFraction = motion.shadowFraction
        }

        let now = Date()
        let dueToMotion = motion.score >= Float(settings.motionSensitivity)
        let dueToClock = now.timeIntervalSince(lastForcedVision) > forcedVisionInterval
        // A car door or breaking glass happens before anything enters frame.
        let dueToSound = settings.soundTrigger && audio.transient
        DispatchQueue.main.async {
            self.soundLevelDB = self.audio.currentDB
            self.ambientDB = self.audio.ambientDB
        }
        guard dueToMotion || dueToClock || dueToSound else {
            if tracker.active.isEmpty {
                DispatchQueue.main.async { if self.overlays.isEmpty == false { self.overlays = [] } }
            }
            return
        }
        guard now.timeIntervalSince(lastVisionRun) >= visionIntervalNow else { return }
        lastVisionRun = now
        if dueToClock { lastForcedVision = now }

        let subjects = detector.detect(in: pixelBuffer,
                                       orientation: .up,
                                       roi: (dueToMotion && !dueToSound) ? motion.region : nil,
                                       minConfidence: Float(settings.personConfidence),
                                       wantUnknownObjects: settings.alertCategories.contains(.unknown))

        visionTimestamps.append(now)
        visionTimestamps.removeAll { now.timeIntervalSince($0) > 2 }
        let hz = Double(visionTimestamps.count) / 2.0

        lastSubjects = subjects
        let tracks = tracker.update(with: subjects)

        var sourceLabel = "—"
        for t in tracks where t.misses == 0 {
            let est = ranger.estimate(box: t.box, depthData: depth,
                                      metrics: COCOClass.metrics(for: t.label,
                                                                 personHeight: settings.subjectHeightMeters))
            tracker.recordSample(range: est.meters, for: t)
            if let r = est.meters {
                sourceLabel = est.source.rawValue
                let sz = ranger.size(box: t.box, rangeMeters: r, source: est.source,
                                     metrics: COCOClass.metrics(for: t.label,
                                                                personHeight: settings.subjectHeightMeters),
                                     truncated: est.truncated)
                tracker.recordSize(height: sz.heightMeters, width: sz.widthMeters, for: t)
            }
        }

        let boxes = tracks.filter { $0.misses <= 2 }.map { t -> BoxOverlay in
            let name = t.label.capitalized
            var text = t.smoothedRange.map { "\(name)  " + Units.distance($0) } ?? name
            if let mps = t.speed(horizontalFOVRadians: self.fovRadians), mps > 0.3 {
                text += "  " + Units.speed(mps)
            }
            if let h = t.measuredHeight { text += "  " + Units.height(h) }
            return BoxOverlay(id: t.id,
                              rect: t.box,
                              label: text,
                              confirmed: t.hits >= settings.confirmHits,
                              category: t.category)
        }

        DispatchQueue.main.async {
            self.overlays = boxes
            self.visionHz = hz
            self.rangeSourceLabel = sourceLabel
        }

        guard isArmed else { return }
        for t in tracks where t.misses == 0 {
            evaluateAlert(track: t, pixelBuffer: pixelBuffer)
        }
    }

    // MARK: AI layers

    /// Runs the active layers for this frame and returns a composited image when a
    /// privacy layer produced one, so the caller can route it to the preview, the
    /// recording and the peer stream instead of the raw buffer.
    @discardableResult
    private func runLayers(pixelBuffer: CVPixelBuffer,
                           depth: AVDepthData?,
                           sampleBuffer: CMSampleBuffer) -> CGImage? {
        let registry = LayerRegistry.shared

        // An audio layer needs the microphone whether or not detection is armed,
        // and should release it when the last one is switched off — holding the
        // mic for nothing costs battery and keeps the recording indicator lit.
        if registry.needsAudio, !audio.isRunning {
            do { try audio.start() }
            catch { EventLog.error(error, name: "layer.audio.start") }
        } else if !registry.needsAudio, audio.isRunning, !isRunning {
            audio.stop()
        }

        guard !registry.activeIDs.isEmpty else {
            if composedFrame != nil { DispatchQueue.main.async { self.composedFrame = nil } }
            return nil
        }

        // Derived layers read the main detector's output. While disarmed the
        // detector does not run at all, so zones, counts and heatmaps would sit
        // silently dead on an idle camera — a few passes a second is enough to
        // keep them honest without turning the idle preview into a full pipeline.
        if !isRunning, registry.needsTracks,
           Date().timeIntervalSince(lastLayerDetect) > 0.25 {
            lastLayerDetect = Date()
            let subjects = detector.detect(in: pixelBuffer,
                                           orientation: .up,
                                           roi: nil,
                                           minConfidence: Float(settings.personConfidence),
                                           wantUnknownObjects: false)
            lastSubjects = subjects
            _ = tracker.update(with: subjects)
        }

        let ctx = FrameContext(pixelBuffer: pixelBuffer,
                               orientation: .up,
                               handler: VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                              orientation: .up,
                                                              options: [:]),
                               depth: depth,
                               frameIndex: frameIndex,
                               timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                               width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer),
                               subjects: lastSubjects,
                               tracks: tracker.active)

        let produced = registry.runVideo(ctx)
        routeLayerAlerts(produced)

        // Privacy layers composite in order, so two of them stack rather than one
        // overwriting the other's redaction. Read from this frame's own results,
        // not the published dictionary, which belongs to the main thread.
        var composite: CGImage?
        for layer in registry.all where layer.group == .privacy {
            if let image = produced[layer.id]?.image { composite = image }
        }
        let shown = composite
        DispatchQueue.main.async {
            self.composedFrame = shown.map { UIImage(cgImage: $0) }
        }
        return composite
    }

    /// Layers raise alerts through the same path as a detection, so a sound event
    /// or a zone breach buzzes the phone and lands in the event list like anything
    /// else. Cooldown is per layer, because one noisy layer should not mute the rest.
    private func routeLayerAlerts(_ produced: [String: LayerOutput]) {
        let registry = LayerRegistry.shared
        for (id, output) in produced {
            guard let message = output.alert else { continue }
            let last = lastLayerAlert[id] ?? .distantPast
            guard Date().timeIntervalSince(last) >= max(10, settings.cooldownSeconds) else { continue }
            lastLayerAlert[id] = Date()

            let title = registry.layer(id)?.title ?? "Layer"
            guard isArmed else {
                // Unarmed, the finding still belongs in the on-screen list; it just
                // does not buzz anyone or fire a siren.
                let text = "\(title): \(message)"
                DispatchQueue.main.async {
                    self.events.insert(SentryEvent(id: UUID(), date: Date(), text: text,
                                                   rangeMeters: nil, thumbnail: nil,
                                                   alerted: false), at: 0)
                    if self.events.count > 60 { self.events.removeLast() }
                }
                EventLog.action("layer.finding", ["layer": id, "detail": message])
                continue
            }

            AlertManager.shared.fire(title: title, body: message,
                                     snapshot: nil, settings: settings)
            let eventID = UUID()
            clips.trigger(label: id, tag: eventID)
            DispatchQueue.main.async {
                self.events.insert(SentryEvent(id: eventID, date: Date(),
                                               text: "\(title): \(message)",
                                               rangeMeters: nil, thumbnail: nil,
                                               alerted: true), at: 0)
                if self.events.count > 60 { self.events.removeLast() }
            }
            EventLog.action("layer.alert", ["layer": id, "detail": message])
        }
    }

    // MARK: Through-glass occupancy

    private func handleGlass(pixelBuffer: CVPixelBuffer) {
        glass.gain = settings.glassGain
        glass.region = settings.glassRegion
        guard let r = glass.analyze(pixelBuffer: pixelBuffer) else { return }

        // The mic is a second, independent answer to the same question: people
        // inside a closed car talk, shift and shut doors. Kept live here
        // because the normal pipeline is what usually updates this.
        let db = audio.currentDB
        DispatchQueue.main.async { self.soundLevelDB = db }

        // The verdict, in the order the failure modes actually occur. A dark
        // readout is not "nobody home" — it is "this measurement is not
        // happening yet", and saying so is the difference between a tool and a
        // coin flip.
        let threshold = settings.glassOccupiedThreshold
        let occupied = r.sustained >= threshold && r.samples >= 45
        var verdict: String
        if r.exposureLevel < 0.015 {
            verdict = "Too dark to read — shade the glass with your body"
        } else if r.contrast < 0.01 {
            verdict = "No detail — back off a foot and re-aim off-axis"
        } else if r.samples < 45 {
            verdict = "Learning the window…"
        } else if occupied {
            verdict = "OCCUPIED · movement inside"
        } else if r.sustained >= threshold * 0.4 {
            verdict = "Possible movement — hold still and keep watching"
        } else {
            verdict = "No movement detected"
        }
        if r.glare { verdict += " · reflection ignored" }

        // Rendering is the expensive part, so it runs at a few frames a second
        // while the analysis runs on every frame.
        var rendered: UIImage?
        if Date().timeIntervalSince(lastGlassRender) > 0.2 {
            lastGlassRender = Date()
            if let cg = glass.enhancedImage(pixelBuffer: pixelBuffer) {
                rendered = UIImage(cgImage: cg)
            }
        }

        DispatchQueue.main.async {
            self.glassActivity = r.activity
            self.glassSustained = r.sustained
            self.glassGlare = r.glare
            self.glassExposure = r.exposureLevel
            self.glassContrast = r.contrast
            self.glassOccupied = occupied
            self.glassVerdict = verdict
            if let rendered { self.glassImage = rendered }
            if self.isRunning { self.status = verdict }
        }

        guard isRunning, isArmed, occupied else { return }
        guard Date().timeIntervalSince(lastGlassAlert) >= settings.cooldownSeconds else { return }
        lastGlassAlert = Date()

        let body = String(format: "movement inside the window · %.0f%% of the last %ds · exposure %.0f%%",
                          r.sustained * 100, Int(Double(r.samples) / 15.0), r.exposureLevel * 100)
        let eventID = UUID()
        clips.trigger(label: "occupied", tag: eventID)
        let jpeg = snapshotJPEG(from: pixelBuffer)
        AlertManager.shared.fire(title: "Occupied vehicle", body: body,
                                 snapshot: jpeg, settings: settings)

        let draft = MeshEventDraft(label: "occupied vehicle",
                                   category: SubjectCategory.person.rawValue,
                                   confidence: Float(min(1, r.sustained)),
                                   rangeMeters: nil,
                                   rangeSource: nil,
                                   speedMPH: nil,
                                   closing: nil,
                                   soundDB: audio.currentDB)
        DispatchQueue.main.async {
            MeshClient.shared.post(event: draft)
            self.events.insert(SentryEvent(id: eventID,
                                           date: Date(),
                                           text: "Occupied vehicle · " + body,
                                           rangeMeters: nil,
                                           thumbnail: rendered ?? jpeg.flatMap { UIImage(data: $0) },
                                           alerted: true), at: 0)
            if self.events.count > 60 { self.events.removeLast() }
        }
        EventLog.action("glass.occupied", ["sustained": r.sustained, "exposure": r.exposureLevel])
    }

    /// Turn through-glass mode on or off. The camera has to be reconfigured
    /// either way — the exposure lock is the mode, the analysis is just what
    /// reads it — so this does the whole switch rather than only the flag.
    func setGlassMode(_ on: Bool) {
        settings.glassMode = on
        // The analyzer's buffers belong to the session queue, so every reset
        // goes through it. Clearing them from the main thread while a frame is
        // mid-analysis is a crash, not a glitch.
        sessionQueue.async { [weak self] in self?.glass.reset() }
        DispatchQueue.main.async {
            self.glassActivity = 0
            self.glassSustained = 0
            self.glassOccupied = false
            self.glassImage = nil
            self.glassVerdict = on ? "Learning the window…" : "Idle"
            // Boxes from the normal pipeline would otherwise sit frozen on
            // screen for as long as this mode is on.
            if on { self.overlays = [] }
            if !on { self.status = self.isArmed ? "Armed" : (self.isRunning ? "Watching" : "Idle") }
        }
        sessionQueue.async { [weak self] in
            guard let self, let cam = self.device else { return }
            // Frame rate first: iOS clamps exposure duration to the active
            // frame duration, so locking 1/20 s at 30 fps silently does nothing.
            try? cam.lockForConfiguration()
            self.applyFrameRate(to: cam)
            cam.unlockForConfiguration()
            ThroughGlassAnalyzer.configureCameraForGlass(cam, enabled: on,
                                                         frameDuration: cam.activeVideoMinFrameDuration)
            EventLog.action("glass.mode", ["enabled": on])
        }
    }

    /// Screen rect in the preview view's own coordinates → normalized
    /// bottom-left rect the analyzer uses. Routed through the preview layer so
    /// aspect-fill cropping and rotation are accounted for; drawing a box over
    /// a window and having the analysis read a different part of the frame is
    /// exactly the failure this avoids. Nil until the layer exists.
    func visionRect(fromLayerRect r: CGRect) -> CGRect? {
        guard let layer = previewLayer else { return nil }
        let meta = layer.metadataOutputRectConverted(fromLayerRect: r)
        return CGRect(x: meta.minX, y: 1 - meta.maxY, width: meta.width, height: meta.height)
    }

    func layerRect(fromVisionRect r: CGRect) -> CGRect? {
        guard let layer = previewLayer else { return nil }
        let meta = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        return layer.layerRectConverted(fromMetadataOutputRect: meta)
    }

    func setGlassRegion(_ rect: CGRect) {
        let clamped = CGRect(x: min(max(0, rect.minX), 0.95),
                             y: min(max(0, rect.minY), 0.95),
                             width: max(0.05, min(rect.width, 1 - min(max(0, rect.minX), 0.95))),
                             height: max(0.05, min(rect.height, 1 - min(max(0, rect.minY), 0.95))))
        settings.glassRegion = clamped
        sessionQueue.async { [weak self] in self?.glass.reset() }
        DispatchQueue.main.async {
            self.glassSustained = 0
            self.glassOccupied = false
            self.glassVerdict = "Learning the window…"
        }
    }

    private func evaluateAlert(track: Track, pixelBuffer: CVPixelBuffer) {
        guard track.hits >= settings.confirmHits else { return }
        guard settings.alertCategories.contains(track.category) else { return }

        // People get an extra check: a real person usually yields several confident pose
        // joints, and requiring a couple on top of the rectangle removes texture false hits.
        // Other categories rely on the classifier's own label confidence instead.
        if track.category == .person, track.maxJoints < 2, track.bestConfidence < 0.8 { return }

        if let last = track.lastAlert,
           Date().timeIntervalSince(last) < settings.cooldownSeconds { return }

        let range = track.smoothedRange
        if settings.alertDistanceMeters > 0, let r = range, r > settings.alertDistanceMeters { return }

        if settings.requireApproach, let rate = track.closingRate, rate > -0.15 { return }

        track.lastAlert = Date()

        let rangeText = range.map { Units.distance($0) + " away" } ?? "range unknown"
        let mps = track.speed(horizontalFOVRadians: fovRadians)
        let speedText = (mps != nil && mps! > 0.3)
            ? " · " + Units.speed(mps!) : ""
        let approachText = (track.closingRate.map { $0 < -0.3 } ?? false) ? " · closing" : ""
        let title = track.label.capitalized + " detected"
        let heightText = track.measuredHeight.map { " · " + Units.height($0) + " tall" } ?? ""
        let body = "\(rangeText)\(speedText)\(approachText)\(heightText) · \(Int(audio.currentDB)) dB · "
            + "\(Int(track.bestConfidence * 100))% confidence · \(rangeSourceLabel) range"

        let eventID = UUID()
        clips.trigger(label: track.label, tag: eventID)

        let jpeg = snapshotJPEG(from: pixelBuffer)
        AlertManager.shared.fire(title: title, body: body, snapshot: jpeg, settings: settings)

        let draft = MeshEventDraft(label: track.label,
                                   category: track.category.rawValue,
                                   confidence: track.bestConfidence,
                                   rangeMeters: range,
                                   rangeSource: rangeSourceLabel == "—" ? nil : rangeSourceLabel,
                                   speedMPH: mps.map { $0 * 2.23694 },
                                   closing: track.closingRate.map { $0 < -0.3 },
                                   soundDB: audio.currentDB)
        DispatchQueue.main.async { MeshClient.shared.post(event: draft) }

        let image = jpeg.flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.status = "ALERT · \(track.label.capitalized) · \(rangeText)"
            self.events.insert(SentryEvent(id: eventID,
                                           date: Date(),
                                           text: body,
                                           rangeMeters: range,
                                           thumbnail: image,
                                           alerted: true), at: 0)
            if self.events.count > 60 { self.events.removeLast() }
        }
    }

    private func snapshotJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 0.35, y: 0.35))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
    }

    private var heartbeatTimer: Timer?

    /// Tell the mesh this node is alive and what it is hearing, so the controller can
    /// show a node as live or stale rather than silently assuming it is still watching.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let fire: (Timer?) -> Void = { [weak self] _ in
            guard let self else { return }
            MeshClient.shared.heartbeat(armed: self.isArmed,
                                        soundDB: self.soundLevelDB,
                                        ambientDB: self.ambientDB)
        }
        fire(nil)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { t in fire(t) }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        MeshClient.shared.heartbeat(armed: false, soundDB: 0, ambientDB: 0)
        MeshClient.shared.stopTimers()
    }

    /// One line describing what this node is seeing right now, shown under its
    /// tile on the controller so you can read the wall without tapping in.
    private func liveStatusLine() -> String {
        // In glass mode the verdict is the status, so a paired phone watching
        // this device's feed reads "OCCUPIED" rather than "idle".
        if settings.glassMode {
            return String(format: "glass · %@ · act %.2f", glassVerdict, glassActivity)
        }
        if let t = tracker.active.first(where: { $0.misses == 0 && $0.hits >= settings.confirmHits }) {
            var s = t.label.capitalized
            if let r = t.smoothedRange { s += " " + Units.distance(r) }
            if let mps = t.speed(horizontalFOVRadians: fovRadians), mps > 0.3 {
                s += " · " + Units.speed(mps)
            }
            if let h = t.measuredHeight { s += " · " + Units.height(h) }
            return s
        }
        return isArmed ? String(format: "armed · %.0f dB", soundLevelDB) : "idle"
    }

    func clearEvents() { events.removeAll() }

    /// Force the background model to relearn — use after moving the device or a lighting change.
    func relearnBackground() {
        sessionQueue.async { self.gate.reset() }
        tracker.reset()
        armAt = Date().addingTimeInterval(settings.armDelaySeconds)
        isArmed = false
        tickCountdown()
    }
}

// MARK: - No-depth path

extension DetectionEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        handle(sampleBuffer: sampleBuffer, depth: nil)
    }
}

// MARK: - LiDAR / TrueDepth path

extension DetectionEngine: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let videoData = collection.synchronizedData(for: videoOutput)
                as? AVCaptureSynchronizedSampleBufferData,
              !videoData.sampleBufferWasDropped else { return }

        let depth = (collection.synchronizedData(for: depthOutput)
                        as? AVCaptureSynchronizedDepthData)
            .flatMap { $0.depthDataWasDropped ? nil : $0.depthData }

        handle(sampleBuffer: videoData.sampleBuffer, depth: depth)
    }
}

import AVFoundation
import Vision
import CoreImage
import UIKit
import Combine

struct SentryEvent: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
    let rangeMeters: Double?
    let thumbnail: UIImage?
    let alerted: Bool
}

struct BoxOverlay: Identifiable {
    let id: Int
    let rect: CGRect          // normalized, origin bottom-left
    let label: String
    let confirmed: Bool
    let category: SubjectCategory
}

final class DetectionEngine: NSObject, ObservableObject {

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
    @Published var soundLevelDB: Float = 0
    @Published var ambientDB: Float = 0


    // MARK: Capture
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "sentry.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    // MARK: Pipeline
    private let gate = MotionGate()
    private let detector = SubjectDetector()
    private let ranger = DistanceEstimator()
    private let audio = AudioMonitor()
    private let tracker = Tracker()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var settings: Settings { Settings.shared }
    private var armAt: Date = .distantFuture
    private var lastVisionRun: Date = .distantPast
    private var lastForcedVision: Date = .distantPast
    private var visionTimestamps: [Date] = []

    /// Horizontal field of view of the active format, in radians per unit of normalized x.
    private var fovRadians: Double = 60 * .pi / 180

    private let minVisionInterval: TimeInterval = 0.12   // ~8 Hz ceiling
    private let forcedVisionInterval: TimeInterval = 2.0 // catch slow creep the gate missed

    // MARK: Lifecycle

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            do { try self.audio.start() } catch { print("audio monitor failed: \(error)") }
            DispatchQueue.main.async {
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
            if self.session.isRunning { self.session.stopRunning() }
            self.audio.stop()
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

        let wanted: AVCaptureSession.Preset = settings.longRangeMode ? .hd4K3840x2160 : .hd1920x1080
        session.sessionPreset = session.canSetSessionPreset(wanted) ? wanted : .hd1920x1080

        let position: AVCaptureDevice.Position = settings.useFrontCamera ? .front : .back
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]

        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: .video,
                                                         position: position)
        guard let cam = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = "No usable camera" }
            return
        }
        session.addInput(input)
        device = cam

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // Without this the ranging math has no focal length to work with.
        if let vc = videoOutput.connection(with: .video),
           vc.isCameraIntrinsicMatrixDeliverySupported {
            vc.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        // Fallback focal length derived from the active format's field of view.
        ranger.horizontalFOVDegrees = Double(cam.activeFormat.videoFieldOfView)
        fovRadians = Double(cam.activeFormat.videoFieldOfView) * .pi / 180

        var haveDepth = false
        if session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true
            if let dc = depthOutput.connection(with: .depthData), dc.isEnabled {
                haveDepth = true
            } else {
                session.removeOutput(depthOutput)
            }
        }

        if haveDepth {
            let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            sync.setDelegate(self, queue: sessionQueue)
            synchronizer = sync
        } else {
            synchronizer = nil
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }

        // Deliver upright buffers so Vision, the motion gate and the overlay all share one space.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: nil)
        rotationCoordinator = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                   options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            self?.sessionQueue.async { self?.applyRotation(angle) }
        }

        try? cam.lockForConfiguration()
        if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
        if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
        if cam.isLowLightBoostSupported { cam.automaticallyEnablesLowLightBoostWhenAvailable = true }
        cam.videoZoomFactor = max(1.0, min(CGFloat(settings.zoomFactor), cam.maxAvailableVideoZoomFactor))
        cam.unlockForConfiguration()

        session.commitConfiguration()
        let ml = detector.modelLoaded ? "YOLOv3-Tiny" : ("model failed: " + (detector.modelLoadError ?? "unknown"))
        DispatchQueue.main.async {
            self.depthAvailable = haveDepth
            self.modelStatus = ml
        }
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

        ranger.updateIntrinsics(from: sampleBuffer,
                                bufferWidth: CVPixelBufferGetWidth(pixelBuffer),
                                bufferHeight: CVPixelBufferGetHeight(pixelBuffer))

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
        guard now.timeIntervalSince(lastVisionRun) >= minVisionInterval else { return }
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

        let tracks = tracker.update(with: subjects)

        var sourceLabel = "—"
        for t in tracks where t.misses == 0 {
            let est = ranger.estimate(box: t.box, depthData: depth,
                                      metrics: COCOClass.metrics(for: t.label,
                                                                 personHeight: settings.subjectHeightMeters))
            tracker.recordSample(range: est.meters, for: t)
            if est.meters != nil { sourceLabel = est.source.rawValue }
        }

        let boxes = tracks.filter { $0.misses <= 2 }.map { t -> BoxOverlay in
            let name = t.label.capitalized
            var text = t.smoothedRange.map { String(format: "%@  %.0f m", name, $0) } ?? name
            if let mps = t.speed(horizontalFOVRadians: self.fovRadians), mps > 0.3 {
                text += String(format: "  %.0f mph", mps * 2.23694)
            }
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

        let rangeText = range.map { String(format: "%.0f m away", $0) } ?? "range unknown"
        let mps = track.speed(horizontalFOVRadians: fovRadians)
        let speedText = (mps != nil && mps! > 0.3)
            ? String(format: " · %.0f mph", mps! * 2.23694) : ""
        let approachText = (track.closingRate.map { $0 < -0.3 } ?? false) ? " · closing" : ""
        let title = track.label.capitalized + " detected"
        let body = "\(rangeText)\(speedText)\(approachText) · \(Int(audio.currentDB)) dB · "
            + "\(Int(track.bestConfidence * 100))% confidence · \(rangeSourceLabel) range"

        let jpeg = snapshotJPEG(from: pixelBuffer)
        AlertManager.shared.fire(title: title, body: body, snapshot: jpeg, settings: settings)

        let image = jpeg.flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.status = "ALERT · \(track.label.capitalized) · \(rangeText)"
            self.events.insert(SentryEvent(date: Date(),
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

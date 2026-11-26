// FeedSource.swift — video arriving from somewhere other than this device's camera.
//
// The app was built around one input: the phone's own camera, delivered as
// `420YpCbCr8BiPlanarFullRange` sample buffers. Everything downstream — the
// motion gate, the detector, all fifty-nine layers, the privacy composite, the
// clip recorder, the peer stream — hangs off that one callback. This file adds
// other inputs that arrive at exactly the same door in exactly the same format,
// so a network camera is not a special case anywhere else in the app.
//
// What is here:
//   • FeedPixelConverter — any decoded image into the capture format.
//   • MJPEGFeed          — multipart JPEG over HTTP, what most Wi-Fi cameras
//                          and every ESP32/Pi camera serve.
//   • HLSFeed            — HLS and progressive MP4 over HTTP, via AVPlayer.
//   • ExternalFeed        — the protocol the engine consumes.
//
// What is deliberately not here: RTSP. AVFoundation ships no RTSP client, so it
// would need a bundled decoder; see FeedDirectory.note.

import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import QuartzCore
import MultipeerConnectivity

// MARK: - Pixel format

/// Renders a decoded image into the exact pixel format the capture path emits.
///
/// This is not a convenience, it is the whole reason an outside feed behaves like
/// the real camera. Three parts of the pipeline read pixel planes directly rather
/// than going through Vision: the motion gate reads the luma plane, the
/// colour-attribute layer reads luma and chroma to name a colour, and
/// through-glass mode reads luma. All three guard on plane count and return
/// quietly when handed a packed BGRA buffer. So an outside feed decoded the
/// obvious way — JPEG to CGImage to BGRA — would run every Vision layer
/// correctly while silently disabling motion detection, colour naming and glass
/// mode, with nothing on screen to say why. Rendering into
/// `420YpCbCr8BiPlanarFullRange` instead means a network camera and the built-in
/// camera are indistinguishable to everything downstream.
final class FeedPixelConverter {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false,
                                                .cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// Set once the first frame has been checked, so the device log carries
    /// evidence that the plane conversion actually happened rather than an
    /// assumption that it did.
    private var verified = false

    private func rebuildPool(width: Int, height: Int) {
        poolWidth = width
        poolHeight = height
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &created)
        pool = created
    }

    func buffer(from image: CIImage) -> CVPixelBuffer? {
        // Chroma is subsampled by two, so an odd width or height has no whole
        // number of chroma samples and the pool silently rounds — which shears
        // every row of the picture. Round the request instead.
        let w = max(2, Int(image.extent.width.rounded()) & ~1)
        let h = max(2, Int(image.extent.height.rounded()) & ~1)
        if pool == nil || w != poolWidth || h != poolHeight { rebuildPool(width: w, height: h) }
        guard let pool else { return nil }

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out else { return nil }

        // The source may not sit at the origin (an MJPEG frame does, an AVPlayer
        // frame can not), and render(_:to:) maps the image's own coordinate
        // space onto the buffer — an un-translated extent puts the picture
        // partly off the buffer.
        let placed = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x,
                                  y: -image.extent.origin.y))
        let scaled = placed.transformed(
            by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width,
                                  y: CGFloat(h) / image.extent.height))
        ciContext.render(scaled, to: out)

        if !verified {
            verified = true
            verifyOnce(out)
        }
        return out
    }

    /// Reads the converted buffer once and reports what it actually contains.
    ///
    /// Whether CoreImage writes both planes of a biplanar target is the one thing
    /// in this file that cannot be settled by reading it, so the first frame of
    /// the first external feed says so in the permanent log rather than being
    /// taken on trust. A `planes` of 2 with a non-zero luma mean is a working
    /// conversion; anything else means the gate and the colour layer are getting
    /// nothing and the log will show it.
    private func verifyOnce(_ buffer: CVPixelBuffer) {
        let planes = CVPixelBufferGetPlaneCount(buffer)
        var lumaMean = -1.0
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        if planes >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            var total = 0
            var counted = 0
            // A sparse sample: this runs once and must not cost a frame.
            for y in stride(from: 0, to: h, by: max(1, h / 32)) {
                for x in stride(from: 0, to: w, by: max(1, w / 32)) {
                    total += Int(luma[y * bpr + x])
                    counted += 1
                }
            }
            if counted > 0 { lumaMean = Double(total) / Double(counted) }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        EventLog.action("feed.convert.verified", [
            "planes": planes,
            "lumaMean": Int(lumaMean.rounded()),
            "format": "420f",
            "ok": planes >= 2 && lumaMean > 0
        ])
    }
}

// MARK: - The protocol the engine consumes

protocol ExternalFeed: AnyObject {
    /// Called on a background queue, once per decoded frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    /// Called with text fit to show the operator; the feed is stopped by then.
    var onProblem: ((String) -> Void)? { get set }
    var describing: String { get }
    func start()
    func stop()
}

// MARK: - Basic auth

extension URL {
    /// Splits `http://user:pass@host/path` into a clean URL plus the header
    /// value for it. URLSession drops credentials embedded in a URL, and a great
    /// many cameras are configured exactly that way, so they are moved into an
    /// Authorization header rather than lost.
    var strippingCredentials: (url: URL, authorization: String?) {
        guard var parts = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let user = parts.user, !user.isEmpty else { return (self, nil) }
        let password = parts.password ?? ""
        parts.user = nil
        parts.password = nil
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        return (parts.url ?? self, "Basic " + token)
    }
}

// MARK: - MJPEG over HTTP

/// Multipart JPEG, the lowest common denominator of network cameras.
///
/// Frames are found by JPEG's own markers rather than by the multipart boundary.
/// Boundaries are what the spec says to use, but cameras get them wrong in every
/// imaginable way — missing the leading dashes, changing case, omitting
/// Content-Length, re-declaring the boundary mid-stream. The byte pair FFD8 opens
/// every JPEG and FFD9 closes it, no camera can get that wrong, and scanning for
/// them costs nothing next to decoding.
final class MJPEGFeed: NSObject, ExternalFeed, URLSessionDataDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onProblem: ((String) -> Void)?
    var describing: String { source.host ?? source.absoluteString }

    private let source: URL
    private let authorization: String?
    private let converter = FeedPixelConverter()
    private let queue = DispatchQueue(label: "feed.mjpeg")

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var scratch = Data()
    private var started = Date()
    private var framesDelivered = 0

    /// A stream that is not MJPEG at all — an HTML error page, an H.264 body —
    /// would otherwise grow this buffer without limit. Eight megabytes is more
    /// than any single JPEG frame a camera will send and small enough that a
    /// wrong URL fails fast instead of consuming the device.
    private let scratchLimit = 8 * 1024 * 1024

    init(url: URL) {
        let split = url.strippingCredentials
        self.source = split.url
        self.authorization = split.authorization
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        // A live stream never finishes, so a response timeout would kill it on
        // purpose. The resource timeout must be off and only the wait for the
        // *first* byte is bounded, by the watchdog below.
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = TimeInterval.infinity
        config.networkServiceType = .video
        config.allowsCellularAccess = true
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s

        var request = URLRequest(url: source)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.setValue("MotionSentry", forHTTPHeaderField: "User-Agent")
        started = Date()
        let t = s.dataTask(with: request)
        task = t
        t.resume()
        EventLog.action("feed.mjpeg.start", ["host": source.host ?? "—"])
    }

    func stop() {
        task?.cancel()
        task = nil
        // Without this the session holds a strong reference to its delegate —
        // this object — for the life of the process, and every feed the operator
        // ever opened stays alive decoding nothing.
        session?.invalidateAndCancel()
        session = nil
        queue.async { [weak self] in self?.scratch.removeAll(keepingCapacity: false) }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        switch http.statusCode {
        case 200...299:
            completionHandler(.allow)
        case 401, 403:
            completionHandler(.cancel)
            report("That camera refused the connection. It needs a username and password — put them in the address as http://user:password@camera/…")
        case 404:
            completionHandler(.cancel)
            report("That address answered, but there is no video at that path.")
        default:
            completionHandler(.cancel)
            report("That camera answered with an error (\(http.statusCode)).")
        }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in self?.consume(data) }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            report("The connection to that camera dropped: \(error.localizedDescription)")
        } else if error == nil {
            // framesDelivered is only ever written on `queue`; read it there too
            // rather than racing the decode that may still be in flight.
            queue.async { [weak self] in
                guard let self, self.framesDelivered == 0 else { return }
                self.report("That address answered but sent no pictures. It may not be an MJPEG stream.")
            }
        }
    }

    private func report(_ text: String) {
        EventLog.action("feed.mjpeg.problem", ["text": text])
        let handler = onProblem
        DispatchQueue.main.async { handler?(text) }
    }

    private func consume(_ incoming: Data) {
        scratch.append(incoming)
        if scratch.count > scratchLimit {
            scratch.removeAll(keepingCapacity: false)
            report("That stream is not sending JPEG frames.")
            stop()
            return
        }

        // Pull out every complete JPEG the buffer now holds. A camera faster than
        // the pipeline can leave several queued; decoding only the newest and
        // discarding the rest keeps the picture current instead of falling
        // progressively further behind real time.
        //
        // Frames are found by JPEG's own markers rather than by the multipart
        // boundary: FFD8FF opens every JPEG and FFD9 closes it, and no camera
        // gets that wrong, whereas boundary handling is wrong in the field in
        // every imaginable way.
        let soi = Data([0xFF, 0xD8, 0xFF])
        let eoi = Data([0xFF, 0xD9])
        var newest: Data?
        while true {
            guard let start = scratch.range(of: soi) else {
                // No frame has begun. Keep only the last two bytes, which may be
                // the leading half of a marker split across two packets.
                if scratch.count > 2 { scratch.removeSubrange(0..<(scratch.count - 2)) }
                break
            }
            if start.lowerBound > 0 { scratch.removeSubrange(0..<start.lowerBound) }
            // Search past the opening marker, never inside it.
            guard scratch.count > 3,
                  let end = scratch.range(of: eoi, in: 3..<scratch.count) else { break }
            newest = scratch.subdata(in: 0..<end.upperBound)
            scratch.removeSubrange(0..<end.upperBound)
        }

        guard let jpeg = newest, let image = CIImage(data: jpeg) else { return }
        guard let buffer = converter.buffer(from: image) else { return }
        framesDelivered += 1
        if framesDelivered == 1 {
            EventLog.action("feed.mjpeg.firstFrame", [
                "ms": Int(Date().timeIntervalSince(started) * 1000),
                "width": Int(image.extent.width),
                "height": Int(image.extent.height)
            ])
        }
        onFrame?(buffer, CMTime(seconds: Date().timeIntervalSince1970,
                                preferredTimescale: 600))
    }
}

// MARK: - HLS and progressive HTTP

/// Anything AVFoundation can already play: an HLS playlist or a plain MP4 over
/// HTTP. AVPlayer decodes it and the video output hands back pixel buffers, so
/// the layers run on a remote stream exactly as on the camera.
final class HLSFeed: NSObject, ExternalFeed {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onProblem: ((String) -> Void)?
    var describing: String { source.host ?? source.absoluteString }

    private let source: URL
    private let player = AVPlayer()
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        // AVPlayer decodes to the same biplanar format the camera produces, so
        // no conversion is needed on this path at all.
        kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ])
    private let queue = DispatchQueue(label: "feed.hls")
    private var timer: DispatchSourceTimer?
    private var statusObserver: NSKeyValueObservation?
    private var frames = 0

    init(url: URL) {
        self.source = url
        super.init()
    }

    func start() {
        let asset = AVURLAsset(url: source)
        let item = AVPlayerItem(asset: asset)
        item.add(output)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .failed {
                let text = item.error?.localizedDescription
                    ?? "that stream could not be played"
                self.report("This device could not play that stream: \(text). MotionSentry plays HLS and MP4 over HTTP; RTSP is not supported.")
            }
        }
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.play()

        let t = DispatchSource.makeTimerSource(queue: queue)
        // 30 Hz: the pipeline strides its own layers, so pulling faster than the
        // display refreshes buys nothing and costs power.
        t.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.pull() }
        timer = t
        t.resume()
        EventLog.action("feed.hls.start", ["host": source.host ?? "—"])
    }

    func stop() {
        timer?.cancel()
        timer = nil
        statusObserver?.invalidate()
        statusObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func pull() {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard time.isValid, output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time,
                                                  itemTimeForDisplay: nil) else { return }
        frames += 1
        if frames == 1 {
            EventLog.action("feed.hls.firstFrame", [
                "width": CVPixelBufferGetWidth(buffer),
                "height": CVPixelBufferGetHeight(buffer),
                "planes": CVPixelBufferGetPlaneCount(buffer)
            ])
        }
        onFrame?(buffer, time)
    }

    private func report(_ text: String) {
        EventLog.action("feed.hls.problem", ["text": text])
        let handler = onProblem
        DispatchQueue.main.async { handler?(text) }
    }
}

// MARK: - Choosing a reader for an address

enum FeedDirectory {
    /// Picks the reader from the address, because the operator should not have to
    /// know what a container format is.
    static func feed(for url: URL) -> ExternalFeed? {
        let path = url.path.lowercased()
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return nil }
        if path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".mov") {
            return HLSFeed(url: url)
        }
        return MJPEGFeed(url: url)
    }

    static func isSupported(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    /// Shown next to the address field, so the limit is stated where it is hit
    /// rather than discovered.
    static let note = "Works with MJPEG, HLS and MP4 over HTTP — what Wi-Fi cameras, baby monitors and Pi or ESP32 cameras serve. RTSP addresses (rtsp://) will not play: iOS has no RTSP support built in. Most RTSP cameras also offer an HTTP or MJPEG path."

    /// Paths worth trying on a camera found by name, so discovery can offer a
    /// working address rather than just a hostname. Ordered by how common they
    /// are across consumer cameras.
    static let commonPaths = [
        "/video", "/video.mjpg", "/videostream.cgi", "/mjpg/video.mjpg",
        "/cgi-bin/mjpg/video.cgi", "/stream", "/live", "/axis-cgi/mjpg/video.cgi",
        "/nphMotionJpeg?Resolution=640x480", "/stream.m3u8", "/index.m3u8"
    ]
}

// MARK: - A paired device's camera

/// A lock-protected, one-slot relay for JPEG frames arriving from paired devices.
///
/// `PeerMesh` is a main-actor type, and its receive callback is deliberately not:
/// decoding a JPEG on the main thread for every frame of every peer would stutter
/// the whole interface. Rather than reach into main-actor state from the network
/// queue, the receive path hands frames to this, and whoever wants them picks
/// them up wherever they like.
final class PeerFrameRelay: @unchecked Sendable {
    static let shared = PeerFrameRelay()
    private let lock = NSLock()
    private var hook: ((MCPeerID, Data) -> Void)?

    func set(_ hook: ((MCPeerID, Data) -> Void)?) {
        lock.lock(); self.hook = hook; lock.unlock()
    }

    /// Called on the network queue for every video packet received.
    func deliver(peer: MCPeerID, jpeg: Data) {
        lock.lock(); let hook = self.hook; lock.unlock()
        hook?(peer, jpeg)
    }

    var isTapped: Bool {
        lock.lock(); defer { lock.unlock() }
        return hook != nil
    }
}

/// Runs this device's layers on another device's camera.
///
/// The sending device draws its own box and label overlays in its interface, not
/// into the pixels, so what arrives is a clean picture — redacted if the sender
/// is running a privacy layer, otherwise as its camera saw it. That makes it
/// honest to run detection and layers over it here.
///
/// The one thing to be clear-eyed about is resolution. Frames cross the mesh at
/// 480 pixels wide and middling JPEG quality, because that is what fits in a
/// Multipeer datagram. Faces, plates and text will be read far less reliably
/// than on a local camera, and `caveat` says so in the interface rather than
/// leaving the operator to wonder why.
final class PeerFeed: ExternalFeed {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onProblem: ((String) -> Void)?
    var describing: String { peer.displayName }

    static let caveat = "Video from a paired device crosses at 480 pixels wide, so layers that read fine detail — faces, plates, text — will be less reliable than on this device's own camera."

    private let peer: MCPeerID
    private let converter = FeedPixelConverter()
    private let queue = DispatchQueue(label: "feed.peer")
    private var frames = 0
    private var watchdog: DispatchSourceTimer?

    init(peer: MCPeerID) { self.peer = peer }

    func start() {
        PeerFrameRelay.shared.set { [weak self] from, jpeg in
            guard let self, from == self.peer else { return }
            self.queue.async { self.decode(jpeg) }
        }
        // A paired device that stops sharing its camera, goes to sleep or walks
        // out of range leaves a frozen last frame and no explanation. Say so.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 6, repeating: 6)
        t.setEventHandler { [weak self] in
            guard let self, self.frames == 0 else { return }
            self.report("\(self.peer.displayName) is connected but not sending video. Switch its camera sharing on from that device.")
        }
        watchdog = t
        t.resume()
        EventLog.action("feed.peer.start", ["peer": peer.displayName])
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        PeerFrameRelay.shared.set(nil)
    }

    private func decode(_ jpeg: Data) {
        guard let image = CIImage(data: jpeg),
              let buffer = converter.buffer(from: image) else { return }
        frames += 1
        if frames == 1 {
            watchdog?.cancel()
            watchdog = nil
            EventLog.action("feed.peer.firstFrame", [
                "peer": peer.displayName,
                "width": Int(image.extent.width),
                "height": Int(image.extent.height)
            ])
        }
        onFrame?(buffer, CMTime(seconds: Date().timeIntervalSince1970,
                                preferredTimescale: 600))
    }

    private func report(_ text: String) {
        let handler = onProblem
        DispatchQueue.main.async { handler?(text) }
    }
}

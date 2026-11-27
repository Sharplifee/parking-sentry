import Foundation
import MultipeerConnectivity
import AVFoundation
import UIKit
import Combine

/// Device-to-device link with no server, no account and no third-party service.
/// Devices find each other over Wi-Fi, or peer-to-peer Wi-Fi and Bluetooth when
/// there is no network, and stream directly to each other.
///
/// Three things this got wrong the first time, all fixed here:
///  1. Video was gated on the detector being *armed*, so paired devices found
///     each other and showed nothing.
///  2. Discovery only ran once a device armed or opened the wall, so a device
///     was often not reachable when you went looking for it.
///  3. Both sides invited each other, which tears a session down mid-handshake.
@MainActor
final class PeerMesh: NSObject, ObservableObject {

    // Reached from the capture queue every frame to hand over video.
    // The instance is created once at launch and never reassigned.
    nonisolated(unsafe) static let shared = PeerMesh()

    /// Bonjour service type — must match the Info.plist NSBonjourServices entries.
    private static let service = "msentry"

    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var frames: [MCPeerID: UIImage] = [:]
    @Published private(set) var statusLines: [MCPeerID: String] = [:]
    /// Whether each peer's detector is armed, as reported by that peer.
    ///
    /// The wall used to infer this from the status text — "not empty and not
    /// 'idle'" meant armed. But a device that is merely previewing with a person
    /// in frame sends that person's description as its status, and a device in
    /// tinted-glass mode sends its verdict whatever its state, so both read as
    /// armed. The shield button then offered to disarm something that was never
    /// armed. It is a fact about the sender, so the sender states it.
    @Published private(set) var peerArmed: [MCPeerID: Bool] = [:]
    @Published private(set) var lastFrameAt: [MCPeerID: Date] = [:]
    @Published private(set) var running = false
    /// Peers seen by the browser, whether or not a session formed. The gap
    /// between this and `peers` is the whole diagnosis: nothing here means
    /// discovery is blocked (local network permission, Wi-Fi off, wrong
    /// network); entries here with no `peers` means invites are failing.
    @Published private(set) var found: [MCPeerID] = []
    @Published private(set) var advertiseError: String?
    @Published private(set) var browseError: String?
    @Published private(set) var lastInviteAt: Date?
    @Published private(set) var framesSent = 0
    @Published private(set) var framesReceived = 0
    @Published var talkingTo: MCPeerID?
    /// Stop putting this device's own camera on the wire without stopping detection.
    @Published var sharesCamera = true

    /// Rebuild identity and reconnect under a new name. MCPeerID is immutable
    /// and baked into the session, so a rename has to tear the whole link down
    /// and stand it back up — otherwise the old name stays on the network until
    /// the app is force-quit, and peers show a name you already changed.
    func renamed(to newName: String) {
        MeshClient.shared.deviceName = newName
        let wasRunning = running
        stop()
        _session = nil
        _peerID = nil
        if wasRunning { start() }
    }

    private var _peerID: MCPeerID?
    private var _session: MCSession?

    private var peerID: MCPeerID {
        if let p = _peerID { return p }
        let p = Self.makePeerID()
        _peerID = p
        return p
    }

    private static func makePeerID() -> MCPeerID {
        let raw = MeshClient.shared.deviceName
        var name = raw.isEmpty ? UIDevice.current.name : raw
        // Two same-model devices otherwise show up as one indistinguishable
        // entry; a short suffix off the stable id keeps them apart on screen.
        name += " " + MeshClient.deviceKey.suffix(4)
        return MCPeerID(displayName: String(name.prefix(63)))
    }

    private var session: MCSession {
        if let s = _session { return s }
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        _session = s
        return s
    }

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var retryTimer: Timer?

    // Video pacing
    private var lastFrameSent = Date.distantPast
    /// Driven by the power budget rather than fixed: pushing video is one of
    /// the most expensive things this app does.
    private var frameInterval: TimeInterval { 1.0 / max(1, PowerManager.peerFPSSnapshot) }
    private var inFlight = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let encodeQueue = DispatchQueue(label: "peermesh.encode", qos: .userInitiated)

    // Two audio engines on purpose. Sharing one meant stopping the mic after a
    // push-to-talk also tore down playback, so the next incoming burst was silent.
    private let micEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var micRunning = false

    // MARK: Lifecycle

    /// Be findable and look for others. Safe to call repeatedly.
    func start() {
        guard !running else { return }

        let adv = MCNearbyServiceAdvertiser(peer: peerID,
                                            discoveryInfo: ["app": "motionsentry",
                                                            "uid": MeshClient.deviceKey],
                                            serviceType: Self.service)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv

        let b = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.service)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b

        running = true
        startRetryLoop()
    }

    /// Tear everything down and build it again. Needed because a browser that
    /// failed to start — most often because local network permission had not
    /// been granted yet — stays dead forever otherwise, and `running` used to
    /// be set to true regardless of whether browsing actually began.
    func restart() {
        stop()
        advertiseError = nil
        browseError = nil
        start()
    }

    /// An invitation can be lost, refused, or race another one. Re-invite any
    /// peer we can see but are not connected to.
    private func startRetryLoop() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                let connected = Set(self.session.connectedPeers.map(\.displayName))
                for peer in self.found where !connected.contains(peer.displayName) {
                    self.browser?.invitePeer(peer, to: self.session, withContext: nil, timeout: 20)
                    self.lastInviteAt = Date()
                }
            }
        }
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session.disconnect()
        running = false
        found = []
        peers = []
        frames = [:]
        // Cleared with the frames. Left behind, a stale status line sat under an
        // empty tile claiming the device was still armed.
        statusLines = [:]
        peerArmed = [:]
        lastFrameAt = [:]
        endTalking()
    }

    /// Connected is not the same as streaming; the wall needs to tell them apart.
    /// Called by the wall when it opens and closes: a feed being watched earns
    /// a higher budget, and closing it must give that budget straight back.
    func setWatching(_ watching: Bool) {
        PowerManager.shared.beingWatched = watching
        DetectionEngine.shared?.applyPowerBudget()
    }

    func isStreaming(_ peer: MCPeerID) -> Bool {
        guard let t = lastFrameAt[peer] else { return false }
        return Date().timeIntervalSince(t) < 3
    }

    // MARK: Outbound video

    nonisolated func offer(frame pixelBuffer: CVPixelBuffer, status: String, armed: Bool) {
        Task { @MainActor in
            self.sendFrame(CIImage(cvPixelBuffer: pixelBuffer), status: status, armed: armed)
        }
    }

    /// Used when a privacy layer has composited the frame: what goes to the other
    /// device must be the redacted image, not the raw camera buffer. Sending the
    /// original here would blur the local preview and stream the unblurred face.
    nonisolated func offer(redacted image: CGImage, status: String, armed: Bool) {
        Task { @MainActor in
            self.sendFrame(CIImage(cgImage: image), status: status, armed: armed)
        }
    }

    private func sendFrame(_ ci: CIImage, status: String, armed: Bool) {
        guard sharesCamera, !session.connectedPeers.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameSent) >= frameInterval else { return }
        // Never queue a second encode behind a slow one — dropping a frame beats
        // building a backlog that puts the picture seconds behind reality.
        guard !inFlight else { return }
        lastFrameSent = now
        inFlight = true

        let targets = session.connectedPeers
        let ctx = ciContext

        encodeQueue.async { [weak self] in
            var payload: Data?
            // 480 px wide keeps a frame inside Multipeer's datagram limit; larger
            // frames were silently dropped on the unreliable path.
            let scale = min(1, 480 / ci.extent.width)
            let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ctx.createCGImage(small, from: small.extent),
               let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.35) {
                var p = Data([Packet.video.rawValue])
                p.append(armed ? 1 : 0)
                // Truncated by BYTES, not by characters, and clamped to what the
                // one-byte length field can hold. `status.prefix(100)` counts
                // Characters: the status lines carry "·" at two bytes and "—" at
                // three, so a hundred of them encode to far more than 255 bytes
                // and `UInt8(count)` would trap. A crash in the sender, triggered
                // by nothing but the text of a status line.
                var statusData = Data(status.utf8.prefix(255))
                // A byte-wise prefix can land mid-character; drop the partial tail
                // so the receiver is not decoding a broken scalar.
                while !statusData.isEmpty, String(data: statusData, encoding: .utf8) == nil {
                    statusData.removeLast()
                }
                p.append(UInt8(statusData.count))
                p.append(statusData)
                p.append(jpeg)
                payload = p
            }
            Task { @MainActor in
                guard let self else { return }
                self.inFlight = false
                guard let payload else { return }
                let live = targets.filter { self.session.connectedPeers.contains($0) }
                guard !live.isEmpty else { return }
                do {
                    try self.session.send(payload, toPeers: live, with: .unreliable)
                    self.framesSent += 1
                } catch {
                    print("peer send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Push-to-talk

    func beginTalking(to peer: MCPeerID) {
        talkingTo = peer
        AudioSessionCoordinator.shared.beginIntercom()
        startMic(to: [peer])
    }

    func endTalking() {
        talkingTo = nil
        stopMic()
        AudioSessionCoordinator.shared.endIntercom()
    }

    private func startMic(to targets: [MCPeerID]) {
        guard !micRunning else { return }
        let input = micEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self, let chan = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            // The sample rate travels with the audio. The mic is tapped at whatever
            // the hardware gives — 48 kHz on every current iPhone — while playback
            // was hardcoded to 44.1 kHz, so every push-to-talk came out about 9%
            // slow and a tone and a half low. It sounded like a bad connection
            // rather than like a bug, which is why it would have survived testing.
            let rate = UInt32(format.sampleRate.rounded())
            var pcm = Data(capacity: n * 2 + 5)
            pcm.append(Packet.audio.rawValue)
            withUnsafeBytes(of: rate.littleEndian) { pcm.append(contentsOf: $0) }
            for i in 0..<n {
                let v = Int16(max(-1, min(1, chan[i])) * 32000)
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
            Task { @MainActor in self.sendAudio(pcm, to: targets) }
        }
        micEngine.prepare()
        do { try micEngine.start(); micRunning = true }
        catch { print("mic start failed: \(error.localizedDescription)") }
    }

    private func sendAudio(_ data: Data, to targets: [MCPeerID]) {
        let live = targets.filter { session.connectedPeers.contains($0) }
        guard !live.isEmpty else { return }
        try? session.send(data, toPeers: live, with: .unreliable)
    }

    private func stopMic() {
        guard micRunning else { return }
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        micRunning = false
    }

    /// `body` is the audio packet minus its kind byte: a little-endian UInt32
    /// sample rate followed by mono Int16 samples.
    private func play(_ body: Data) {
        guard body.count > 4 else { return }
        let header = Array(body.prefix(4))
        let rate = UInt32(header[0]) | UInt32(header[1]) << 8
                 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        let sampleRate = Double(rate)
        guard sampleRate >= 8000, sampleRate <= 96000 else { return }
        let pcm = Data(body.dropFirst(4))

        // Rebuilt if the far end's rate differs from what is already playing —
        // two devices with different hardware rates, or a device that switched
        // route mid-call.
        if playerNode == nil || playbackFormat?.sampleRate != sampleRate {
            if let old = playerNode {
                old.stop()
                playbackEngine.stop()
                playbackEngine.detach(old)
                playerNode = nil
            }
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                          channels: 1, interleaved: true) else { return }
            let node = AVAudioPlayerNode()
            playbackEngine.attach(node)
            playbackEngine.connect(node, to: playbackEngine.mainMixerNode, format: fmt)
            playbackEngine.prepare()
            do { try playbackEngine.start() } catch {
                print("playback start failed: \(error.localizedDescription)"); return
            }
            node.play()
            playerNode = node
            playbackFormat = fmt
        }
        guard let playerNode, let fmt = playbackFormat else { return }
        let count = AVAudioFrameCount(pcm.count / 2)
        guard count > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count) else { return }
        buf.frameLength = count
        pcm.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = buf.int16ChannelData?[0] {
                memcpy(dst, src, Int(count) * 2)
            }
        }
        playerNode.scheduleBuffer(buf, completionHandler: nil)
    }

    // MARK: Remote control

    func send(command: String, to peer: MCPeerID) {
        var d = Data([Packet.command.rawValue])
        d.append(Data(command.utf8))
        try? session.send(d, toPeers: [peer], with: .reliable)
    }

    enum Packet: UInt8 { case video = 1, audio = 2, command = 3 }
}

// MARK: - Session

extension PeerMesh: MCSessionDelegate {
    nonisolated func session(_ s: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.peers = s.connectedPeers
            if state != .connected {
                self.frames[peerID] = nil
                self.lastFrameAt[peerID] = nil
                self.statusLines[peerID] = nil
                self.peerArmed[peerID] = nil
            }
        }
    }

    nonisolated func session(_ s: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let kind = data.first.flatMap(Packet.init(rawValue:)), data.count > 1 else { return }
        // Copy rather than slice: a Data slice keeps its parent's indices, which
        // makes every subsequent offset arithmetic quietly wrong.
        let body = Data(data.dropFirst())
        switch kind {
        case .video:
            // [armed flag][status length][status][jpeg]
            guard body.count > 2 else { return }
            let armed = body[0] == 1
            let len = Int(body[1])
            guard body.count > 2 + len else { return }
            let status = String(decoding: body[2..<(2 + len)], as: UTF8.self)
            let jpeg = Data(body[(2 + len)...])
            // Handed over before the main-actor hop, so a device chosen as the
            // layer source decodes on the network queue rather than stuttering
            // the interface. No-op when nothing has asked for peer frames.
            if PeerFrameRelay.shared.isTapped {
                PeerFrameRelay.shared.deliver(peer: peerID, jpeg: jpeg)
            }
            guard let img = UIImage(data: jpeg) else { return }
            Task { @MainActor in
                self.frames[peerID] = img
                self.statusLines[peerID] = status
                self.peerArmed[peerID] = armed
                self.lastFrameAt[peerID] = Date()
                self.framesReceived += 1
            }
        case .audio:
            Task { @MainActor in self.play(body) }
        case .command:
            let cmd = String(decoding: body, as: UTF8.self)
            Task { @MainActor in
                switch cmd {
                case "arm":
                    // Remote arming must never light the screen: the point is a
                    // propped device that looks off while it watches.
                    RemoteControl.shared.armSilently()
                case "disarm":
                    DetectionEngine.shared?.stop()
                case "flip":
                    DetectionEngine.shared?.flipCamera()
                case "stealthOn":
                    RemoteControl.shared.stealth = true
                case "stealthOff":
                    RemoteControl.shared.stealth = false
                case "shareOn":
                    // A propped-up device with camera sharing off shows the
                    // other end a frozen frame and no way to fix it without
                    // walking over to it. Remote arming was already possible;
                    // this was the one piece of taking a device over that still
                    // needed hands on the device itself.
                    self.sharesCamera = true
                case "shareOff":
                    self.sharesCamera = false
                default: break
                }
            }
        }
    }

    nonisolated func session(_ s: MCSession, didReceive stream: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    nonisolated func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at url: URL?, withError e: Error?) {}
}

extension PeerMesh: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ a: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(true, self.session) }
    }

    nonisolated func advertiser(_ a: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.advertiseError = error.localizedDescription
            self.running = false
        }
    }
}

extension PeerMesh: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ b: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !self.found.contains(peerID) { self.found.append(peerID) }
            guard !self.session.connectedPeers.contains(peerID) else { return }

            // Previously the lower id invited and the higher one stayed silent.
            // If that invite is dropped — and on a busy network it is — nobody
            // ever tries again and the two sit two feet apart doing nothing.
            // Now the lower id invites immediately and the higher one waits only
            // briefly before inviting too; a duplicate invite is harmless, a
            // missed one is fatal.
            let mine = MeshClient.deviceKey
            let theirs = info?["uid"] ?? ""
            let delay: TimeInterval = (theirs.isEmpty || mine < theirs) ? 0 : 3
            self.lastInviteAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task { @MainActor in
                    guard !self.session.connectedPeers.contains(peerID) else { return }
                    b.invitePeer(peerID, to: self.session, withContext: nil, timeout: 20)
                }
            }
        }
    }

    nonisolated func browser(_ b: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.found.removeAll { $0 == peerID }
            self.peers = self.session.connectedPeers
            self.frames[peerID] = nil
        }
    }

    nonisolated func browser(_ b: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.browseError = error.localizedDescription
            // A browser that failed to start never recovers on its own, and
            // this is what happens when local network permission is refused or
            // still pending at launch. Mark the link down so a retry is possible.
            self.running = false
        }
    }
}

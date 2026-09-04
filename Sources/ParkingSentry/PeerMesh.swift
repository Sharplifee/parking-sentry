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

    static let shared = PeerMesh()

    /// Bonjour service type — must match the Info.plist NSBonjourServices entries.
    private static let service = "msentry"

    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var frames: [MCPeerID: UIImage] = [:]
    @Published private(set) var statusLines: [MCPeerID: String] = [:]
    @Published private(set) var lastFrameAt: [MCPeerID: Date] = [:]
    @Published private(set) var running = false
    @Published private(set) var framesSent = 0
    @Published private(set) var framesReceived = 0
    @Published var talkingTo: MCPeerID?
    /// Stop putting this device's own camera on the wire without stopping detection.
    @Published var sharesCamera = true

    private lazy var peerID: MCPeerID = {
        let raw = MeshClient.shared.deviceName
        var name = raw.isEmpty ? UIDevice.current.name : raw
        // Two same-model devices otherwise show up as one indistinguishable
        // entry; a short suffix off the stable id keeps them apart on screen.
        name += " " + MeshClient.deviceKey.suffix(4)
        return MCPeerID(displayName: String(name.prefix(63)))
    }()

    private lazy var session: MCSession = {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // Video pacing
    private var lastFrameSent = Date.distantPast
    private let frameInterval: TimeInterval = 1.0 / 12.0
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
    }

    func stop() {
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session.disconnect()
        running = false
        peers = []
        frames = [:]
        endTalking()
    }

    /// Connected is not the same as streaming; the wall needs to tell them apart.
    func isStreaming(_ peer: MCPeerID) -> Bool {
        guard let t = lastFrameAt[peer] else { return false }
        return Date().timeIntervalSince(t) < 3
    }

    // MARK: Outbound video

    nonisolated func offer(frame pixelBuffer: CVPixelBuffer, status: String) {
        Task { @MainActor in self.sendFrame(pixelBuffer, status: status) }
    }

    private func sendFrame(_ pixelBuffer: CVPixelBuffer, status: String) {
        guard sharesCamera, !session.connectedPeers.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameSent) >= frameInterval else { return }
        // Never queue a second encode behind a slow one — dropping a frame beats
        // building a backlog that puts the picture seconds behind reality.
        guard !inFlight else { return }
        lastFrameSent = now
        inFlight = true

        let targets = session.connectedPeers
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
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
                let statusData = Data(status.prefix(100).utf8)
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
            var pcm = Data(capacity: n * 2 + 1)
            pcm.append(Packet.audio.rawValue)
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

    private func play(_ pcm: Data) {
        if playerNode == nil {
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100,
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
            guard let len = body.first.map(Int.init), body.count > 1 + len else { return }
            let status = String(decoding: body[1..<(1 + len)], as: UTF8.self)
            let jpeg = Data(body[(1 + len)...])
            guard let img = UIImage(data: jpeg) else { return }
            Task { @MainActor in
                self.frames[peerID] = img
                self.statusLines[peerID] = status
                self.lastFrameAt[peerID] = Date()
                self.framesReceived += 1
            }
        case .audio:
            Task { @MainActor in self.play(body) }
        case .command:
            let cmd = String(decoding: body, as: UTF8.self)
            Task { @MainActor in
                switch cmd {
                case "arm":    DetectionEngine.shared?.start()
                case "disarm": DetectionEngine.shared?.stop()
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
        print("advertise failed: \(error.localizedDescription)")
    }
}

extension PeerMesh: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ b: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard !self.session.connectedPeers.contains(peerID) else { return }

            // Both sides browse, so without a tiebreak both invite and one
            // session is torn down mid-handshake. Break on the stable per-install
            // id carried in discoveryInfo — NOT on displayName, which iOS reports
            // generically ("iPad", "iPhone") and which is identical across two
            // devices of the same model, leaving nobody to invite.
            let mine = MeshClient.deviceKey
            if let theirs = info?["uid"] {
                guard mine < theirs else { return }
            }
            // No id advertised (older build on the other device): invite anyway
            // rather than sit silent. A duplicate invite is recoverable; a
            // missed one is not.
            b.invitePeer(peerID, to: self.session, withContext: nil, timeout: 20)
        }
    }

    nonisolated func browser(_ b: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.peers = self.session.connectedPeers
            self.frames[peerID] = nil
        }
    }

    nonisolated func browser(_ b: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("browse failed: \(error.localizedDescription)")
    }
}

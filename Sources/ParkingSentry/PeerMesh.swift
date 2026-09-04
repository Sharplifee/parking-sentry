import Foundation
import MultipeerConnectivity
import AVFoundation
import UIKit
import Combine

/// Device-to-device connection with no server, no account and no third-party
/// service in the path. Devices find each other over Wi-Fi (or peer-to-peer
/// Wi-Fi / Bluetooth when there is no network) and stream directly.
///
/// This deliberately replaces the hosted-SFU approach: routing your cameras
/// through an outside video service meant another account, another set of keys,
/// and your footage leaving your own devices. Nothing here leaves the room.
@MainActor
final class PeerMesh: NSObject, ObservableObject {

    static let shared = PeerMesh()

    /// Max 8 chars, lowercase, no spaces — Bonjour service type rules.
    private static let service = "msentry"

    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var frames: [MCPeerID: UIImage] = [:]
    @Published private(set) var statusLines: [MCPeerID: String] = [:]
    @Published private(set) var isBroadcasting = false
    @Published private(set) var isWatching = false
    @Published var talkingTo: MCPeerID?

    private lazy var peerID = MCPeerID(displayName: String(MeshClient.shared.deviceName.prefix(63)))
    private lazy var session: MCSession = {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // Video send throttle
    private var lastFrameSent = Date.distantPast
    private let frameInterval: TimeInterval = 1.0 / 12.0
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Audio for push-to-talk
    private let engine = AVAudioEngine()
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var micRunning = false

    // MARK: Roles

    /// A detector node: announce yourself and accept watchers.
    func startBroadcasting() {
        guard !isBroadcasting else { return }
        let adv = MCNearbyServiceAdvertiser(peer: peerID,
                                            discoveryInfo: ["role": "detector"],
                                            serviceType: Self.service)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
        isBroadcasting = true
        startBrowsing()          // so two detectors can also see each other
    }

    /// A controller: look for nodes to watch.
    func startBrowsing() {
        guard browser == nil else { return }
        let b = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.service)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
        isWatching = true
    }

    func stop() {
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session.disconnect()
        isBroadcasting = false
        isWatching = false
        peers = []
        frames = [:]
        stopMic()
    }

    // MARK: Outbound video

    /// Called by the detection engine on every frame it processes. Throttled and
    /// downscaled here rather than at the camera, so detection keeps full
    /// resolution while the wire gets something a phone can actually decode.
    nonisolated func offer(frame pixelBuffer: CVPixelBuffer, status: String) {
        Task { @MainActor in self.sendFrame(pixelBuffer, status: status) }
    }

    private func sendFrame(_ pixelBuffer: CVPixelBuffer, status: String) {
        guard isBroadcasting, !session.connectedPeers.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameSent) >= frameInterval else { return }
        lastFrameSent = now

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let targetWidth: CGFloat = 640
        let scale = min(1, targetWidth / ci.extent.width)
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.4) else { return }

        var payload = Data([Packet.video.rawValue])
        let statusData = Data(status.prefix(120).utf8)
        payload.append(UInt8(statusData.count))
        payload.append(statusData)
        payload.append(jpeg)
        // Unreliable: a dropped frame is better than a growing backlog.
        try? session.send(payload, toPeers: session.connectedPeers, with: .unreliable)
    }

    // MARK: Push-to-talk

    func beginTalking(to peer: MCPeerID) {
        talkingTo = peer
        startMic(to: [peer])
    }

    func endTalking() {
        talkingTo = nil
        stopMic()
    }

    private func startMic(to targets: [MCPeerID]) {
        guard !micRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self, let chan = buf.floatChannelData?[0] else { return }
            // Downconvert to 16-bit mono; float PCM is four times the bytes for
            // no audible gain over a walkie-talkie link.
            let n = Int(buf.frameLength)
            var pcm = Data(capacity: n * 2 + 1)
            pcm.append(Packet.audio.rawValue)
            for i in 0..<n {
                let v = Int16(max(-1, min(1, chan[i])) * 32000)
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
            let rate = format.sampleRate
            Task { @MainActor in self.sendAudio(pcm, rate: rate, to: targets) }
        }
        engine.prepare()
        try? engine.start()
        micRunning = true
    }

    private func sendAudio(_ data: Data, rate: Double, to targets: [MCPeerID]) {
        let live = targets.filter { session.connectedPeers.contains($0) }
        guard !live.isEmpty else { return }
        try? session.send(data, toPeers: live, with: .unreliable)
    }

    private func stopMic() {
        guard micRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micRunning = false
    }

    private func play(_ pcm: Data) {
        // Lazily stand up a playback graph the first time audio arrives.
        if player == nil {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100,
                                    channels: 1, interleaved: true)
            guard let fmt else { return }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            try? engine.start()
            node.play()
            player = node
            playbackFormat = fmt
        }
        guard let player, let fmt = playbackFormat else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = buf.int16ChannelData?[0] {
                memcpy(dst, src, Int(frames) * 2)
            }
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    // MARK: Remote control

    func send(command: String, to peer: MCPeerID) {
        var d = Data([Packet.command.rawValue])
        d.append(Data(command.utf8))
        try? session.send(d, toPeers: [peer], with: .reliable)
    }

    enum Packet: UInt8 {
        case video = 1, audio = 2, command = 3
    }
}

// MARK: - Session

extension PeerMesh: MCSessionDelegate {
    nonisolated func session(_ s: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.peers = s.connectedPeers
            if state != .connected { self.frames[peerID] = nil }
        }
    }

    nonisolated func session(_ s: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let kind = data.first.flatMap(Packet.init(rawValue:)), data.count > 1 else { return }
        let body = data.dropFirst()
        switch kind {
        case .video:
            guard let len = body.first, body.count > 1 + Int(len) else { return }
            let statusBytes = body.dropFirst().prefix(Int(len))
            let jpeg = body.dropFirst(1 + Int(len))
            let status = String(decoding: statusBytes, as: UTF8.self)
            guard let img = UIImage(data: Data(jpeg)) else { return }
            Task { @MainActor in
                self.frames[peerID] = img
                self.statusLines[peerID] = status
            }
        case .audio:
            Task { @MainActor in self.play(Data(body)) }
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

    nonisolated func session(_ s: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ s: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ s: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerMesh: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ a: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // One owner's own devices — accept. The session is encryption-required
        // and the service type is private to this app.
        Task { @MainActor in invitationHandler(true, self.session) }
    }
}

extension PeerMesh: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ b: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            b.invitePeer(peerID, to: self.session, withContext: nil, timeout: 15)
        }
    }
    nonisolated func browser(_ b: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.peers = self.session.connectedPeers
            self.frames[peerID] = nil
        }
    }
}

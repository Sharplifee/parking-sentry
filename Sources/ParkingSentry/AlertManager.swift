import Foundation
import AVFoundation
import UserNotifications
import UIKit

final class AlertManager {
    static let shared = AlertManager()

    private var player: AVAudioPlayer?
    private let haptics = UINotificationFeedbackGenerator()
    private var lastGlobalAlert: Date = .distantPast
    private let globalCooldown: TimeInterval = 4

    private init() {
        // Deliberately does NOT set a category: a .playback category here
        // silently dropped the microphone, which killed sound metering and the
        // intercom the moment any alert fired.
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func fire(title: String, body: String, snapshot: Data?, settings: Settings) {
        guard Date().timeIntervalSince(lastGlobalAlert) > globalCooldown else { return }
        lastGlobalAlert = Date()

        DispatchQueue.main.async { self.haptics.notificationOccurred(.warning) }

        if settings.notificationsEnabled { postNotification(title: title, body: body, snapshot: snapshot) }
        if settings.sirenEnabled { playSiren() }
        if !settings.webhookURL.isEmpty { postWebhook(url: settings.webhookURL, title: title, body: body) }
    }

    // MARK: Local notification

    private func postNotification(title: String, body: String, snapshot: Data?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive

        if let snapshot {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sentry-\(UUID().uuidString).jpg")
            if (try? snapshot.write(to: url)) != nil,
               let att = try? UNNotificationAttachment(identifier: "snap", url: url, options: nil) {
                content.attachments = [att]
            }
        }

        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: Webhook (ntfy.sh / Pushover / anything that takes a POST)

    private func postWebhook(url: String, title: String, body: String) {
        guard let u = URL(string: url) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("high", forHTTPHeaderField: "Priority")
        req.setValue("rotating_light", forHTTPHeaderField: "Tags")
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: Siren

    func playSiren() {
        Task { @MainActor in AudioSessionCoordinator.shared.prepareForAlertPlayback() }
        if player == nil { player = try? AVAudioPlayer(data: Self.sirenWAV()) }
        guard let player else { return }
        player.numberOfLoops = 3
        player.volume = 1.0
        player.currentTime = 0
        player.play()
    }

    func stopSiren() { player?.stop() }

    /// A 1.2 s warbling two-tone siren synthesized at runtime so nothing has to be bundled.
    private static func sirenWAV(seconds: Double = 1.2, sampleRate: Double = 22050) -> Data {
        let count = Int(seconds * sampleRate)
        var samples = [Int16](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let freq = 760 + 420 * sin(2 * .pi * 2.5 * t)     // warble
            phase += 2 * .pi * freq / sampleRate
            let env = min(1.0, t * 20) * min(1.0, (seconds - t) * 20)
            samples[i] = Int16(max(-1, min(1, sin(phase) * env)) * 26000)
        }

        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate) * 2)
        le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(byteCount)
        samples.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                data.append(Data(bytes: base, count: buf.count * MemoryLayout<Int16>.size))
            }
        }
        return data
    }
}

// FeedDiscovery.swift — finding cameras on the same network, and proving they work.
//
// Two halves, because finding a camera and getting a picture out of it are
// different problems:
//
//   • Browse — Bonjour, for cameras that announce themselves. Nearly all
//     consumer Wi-Fi cameras do, under one of a handful of service types.
//   • Probe — a found camera gives a host, not a video address. The stream lives
//     at a path that differs per manufacturer, so each candidate path is tried
//     until one answers with something that is actually video. The operator gets
//     an address that works rather than a hostname and a guessing game.
//
// Browsing silently returns nothing unless every service type is also declared
// in NSBonjourServices in Info.plist. The list there and the list here have to
// match, so they are named in one place: `Discovery.serviceTypes`.

import Foundation
import Network

/// A one-shot flag that is safe to claim from any thread.
///
/// `claim()` returns true exactly once, to exactly one caller, however many
/// threads race for it.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

@MainActor
final class FeedDiscovery: ObservableObject {

    struct Found: Identifiable, Equatable {
        let id: String
        let name: String
        let serviceType: String
        /// Filled in once resolved; nil until then.
        var host: String?
        var port: UInt16?
        /// Filled in once a path has been proved to return video.
        var workingURL: URL?
        var note: String?

        var subtitle: String {
            if let workingURL { return workingURL.absoluteString }
            if let note { return note }
            // A raw address — a link-local IPv6 above all — is noise to read and
            // useless to act on, so it is only shown once it is a working one.
            if host != nil { return "Checking what it can send…" }
            return kindLabel
        }

        var kindLabel: String {
            switch serviceType {
            case "_rtsp._tcp":        return "RTSP camera"
            case "_onvif._tcp":       return "ONVIF camera"
            case "_axis-video._tcp":  return "Axis camera"
            case "_msentry._tcp":     return "MotionSentry device"
            default:                   return "Network device"
            }
        }
    }

    /// Declared identically in Info.plist under NSBonjourServices. A type missing
    /// there is simply never discovered, with no error anywhere.
    static let serviceTypes = [
        "_http._tcp",
        "_rtsp._tcp",
        "_onvif._tcp",
        "_axis-video._tcp"
    ]

    @Published private(set) var found: [Found] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var probing: Set<String> = []

    private var browsers: [NWBrowser] = []

    func start() {
        guard browsers.isEmpty else { return }
        isBrowsing = true
        for type in Self.serviceTypes {
            let descriptor = NWBrowser.Descriptor.bonjour(type: type, domain: nil)
            let browser = NWBrowser(for: descriptor, using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.absorb(results, type: type) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                EventLog.action("discovery.failed", ["type": type,
                                                     "error": "\(error)"])
                Task { @MainActor in self?.isBrowsing = false }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
        EventLog.action("discovery.start", ["types": Self.serviceTypes.count])
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        isBrowsing = false
    }

    private func absorb(_ results: Set<NWBrowser.Result>, type: String) {
        for result in results {
            guard case .service(let name, let serviceType, _, _) = result.endpoint else { continue }
            let key = "\(serviceType)/\(name)"
            guard !found.contains(where: { $0.id == key }) else { continue }
            found.append(Found(id: key, name: name, serviceType: serviceType))
            // A found camera is useless without an address, so resolve and probe
            // straight away rather than making the operator tap twice.
            resolveAndProbe(endpoint: result.endpoint, key: key)
        }
        // Drop anything that has gone off the network, but never a camera that
        // has already been proved to work — a brief mDNS gap should not make a
        // working address disappear from under the operator's finger.
        let live = Set(results.compactMap { r -> String? in
            guard case .service(let n, let t, _, _) = r.endpoint else { return nil }
            return "\(t)/\(n)"
        })
        found.removeAll { $0.serviceType == type && $0.workingURL == nil && !live.contains($0.id) }
    }

    /// Bonjour gives a service, not an address. Opening a connection is the
    /// supported way to make the system resolve one; the resolved host appears on
    /// the connection's path.
    private func resolveAndProbe(endpoint: NWEndpoint, key: String) {
        probing.insert(key)
        let connection = NWConnection(to: endpoint, using: .tcp)
        // The state handler runs on a network queue and can be called more than
        // once, including .ready and then .cancelled from the cancel below. A
        // plain captured Bool was being read and written from whichever thread
        // got there first, so both branches could pass their own guard and the
        // device would be probed twice and finished twice.
        let settled = OnceFlag()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard settled.claim() else { return }
                var host: String?
                var port: UInt16?
                if let remote = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let h, let p) = remote {
                    port = p.rawValue
                    switch h {
                    case .ipv4(let a): host = "\(a)".components(separatedBy: "%").first
                    case .ipv6(let a): host = "[\(a)]"
                    case .name(let n, _): host = n
                    @unknown default: host = nil
                    }
                }
                connection.cancel()
                Task { @MainActor in
                    self?.note(key: key, host: host, port: port)
                    if let host, let port { await self?.probePaths(key: key, host: host, port: port) }
                    else { self?.finishProbe(key: key, note: "Found, but its address could not be resolved.") }
                }
            case .failed, .cancelled:
                guard settled.claim() else { return }
                connection.cancel()
                Task { @MainActor in
                    self?.finishProbe(key: key, note: "Found, but it refused a connection.")
                }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func note(key: String, host: String?, port: UInt16?) {
        guard let index = found.firstIndex(where: { $0.id == key }) else { return }
        found[index].host = host
        found[index].port = port
    }

    private func finishProbe(key: String, note: String?) {
        probing.remove(key)
        guard let index = found.firstIndex(where: { $0.id == key }) else { return }
        if found[index].workingURL == nil { found[index].note = note }
    }

    /// Tries each known stream path until one answers with video.
    ///
    /// Content type is what decides, not the status code: plenty of cameras
    /// answer 200 with an HTML login page at every path, and treating that as a
    /// working stream is how the operator ends up staring at a black rectangle.
    private func probePaths(key: String, host: String, port: UInt16) async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        for path in FeedDirectory.commonPaths {
            guard let url = URL(string: "http://\(host):\(port)\(path)") else { continue }
            var request = URLRequest(url: url)
            // A HEAD is cheaper, but a streaming endpoint often refuses it or
            // answers without a content type, so ask for the stream and hang up
            // the moment the type is known.
            request.httpMethod = "GET"
            request.setValue("MotionSentry", forHTTPHeaderField: "User-Agent")
            do {
                let (bytes, response) = try await session.bytes(for: request)
                let type = ((response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                bytes.task.cancel()
                guard (200...299).contains(code) else { continue }
                if type.contains("multipart") || type.contains("mjpeg")
                    || type.contains("image/") || type.contains("mpegurl")
                    || type.contains("video/") {
                    await MainActor.run {
                        if let index = self.found.firstIndex(where: { $0.id == key }) {
                            self.found[index].workingURL = url
                            self.found[index].note = nil
                        }
                        self.probing.remove(key)
                    }
                    EventLog.action("discovery.probe.hit", ["path": path, "type": type])
                    return
                }
            } catch {
                continue
            }
        }
        await MainActor.run {
            self.finishProbe(key: key,
                             note: "This is on your network but does not serve video. If you know it has a camera, type its address below.")
        }
        EventLog.action("discovery.probe.miss", ["host": host])
    }
}

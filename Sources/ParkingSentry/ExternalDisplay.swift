import SwiftUI
import UIKit
import Combine
import MultipeerConnectivity

/// Drives a second physical screen — external display over USB-C, or AirPlay.
///
/// Without this an external screen only mirrors the phone, which wastes it: the
/// point of a big screen is every camera at once while the handheld device keeps
/// the controls. When a screen appears the wall moves to it automatically.
@MainActor
final class ExternalDisplayManager: ObservableObject {

    static let shared = ExternalDisplayManager()

    @Published private(set) var attached = false

    private var window: UIWindow?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func begin() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: UIScene.willConnectNotification,
                                            object: nil, queue: .main) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            Task { @MainActor in ExternalDisplayManager.shared.adopt(scene) }
        })
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification,
                                            object: nil, queue: .main) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            Task { @MainActor in ExternalDisplayManager.shared.release(scene) }
        })

        // A display can already be connected before the app launches.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            adopt(scene)
        }
    }

    private func adopt(_ scene: UIWindowScene) {
        guard window == nil else { return }
        // The device's own screen is not an external display.
        guard scene.screen !== UIScreen.main else { return }

        let host = UIHostingController(rootView: ExternalWallView())
        host.view.backgroundColor = .black
        let w = UIWindow(windowScene: scene)
        w.rootViewController = host
        w.isHidden = false
        window = w
        attached = true
    }

    private func release(_ scene: UIWindowScene) {
        guard window?.windowScene === scene else { return }
        window?.isHidden = true
        window = nil
        attached = false
    }
}

/// What the big screen shows: every camera, no controls, nothing to tap.
struct ExternalWallView: View {
    @ObservedObject private var mesh = PeerMesh.shared
    @ObservedObject private var engine = DetectionEngine.sharedOrPlaceholder

    var body: some View {
        let tiles = mesh.peers.count + 1
        let cols = tiles <= 1 ? 1 : (tiles <= 4 ? 2 : 3)
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols),
                      spacing: 4) {
                localTile
                ForEach(mesh.peers, id: \.self) { peerTile($0) }
            }
            .padding(4)
        }
        .background(Color.black)
    }

    private var localTile: some View {
        ZStack(alignment: .bottomLeading) {
            CameraPreview(session: engine.session, overlays: engine.overlays)
            caption("This device", engine.isArmed ? engine.status : "idle")
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func peerTile(_ p: MCPeerID) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let img = mesh.frames[p] {
                Image(uiImage: img).resizable().scaledToFill().clipped()
            } else {
                Rectangle().fill(Color(white: 0.08))
                    .overlay(Text("waiting for video")
                        .font(.caption).foregroundStyle(.white.opacity(0.4)))
            }
            caption(p.displayName, mesh.statusLines[p] ?? "")
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func caption(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline)
            if !sub.isEmpty {
                Text(sub).font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(7)
        .background(.black.opacity(0.5))
        .foregroundStyle(.white)
    }
}

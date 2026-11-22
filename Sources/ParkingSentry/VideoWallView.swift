import SwiftUI
import MultipeerConnectivity

/// The wall: every connected device's live camera. Tap a tile to enlarge,
/// press and hold it to talk into that device, and arm or disarm it remotely.
/// Stealth blacks out THIS screen only — every other node keeps running.
struct VideoWallView: View {
    @ObservedObject private var mesh = PeerMesh.shared
    @ObservedObject private var data = MeshClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var stealth = false
    @State private var focused: MCPeerID?
    @State private var priorBrightness: CGFloat = UIScreen.main.brightness

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if mesh.peers.isEmpty {
                waiting
            } else if let focused, mesh.peers.contains(focused) {
                bigTile(focused)
            } else {
                grid
            }

            if stealth { stealthCurtain }
        }
        .onAppear { mesh.start(); mesh.setWatching(true) }
        .onDisappear { mesh.setWatching(false); restoreBrightnessIfNeeded() }
        .overlay(alignment: .topTrailing) { if !stealth { closeButton } }
        .overlay(alignment: .bottom) { if !stealth { bottomBar } }
        .statusBarHidden(stealth)
        .persistentSystemOverlays(stealth ? .hidden : .automatic)
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white)
            Text("Looking for your other devices…")
                .foregroundStyle(.white.opacity(0.75)).font(Style.body)
            Text("Open MotionSentry on the device doing the watching and press Start watching. Both devices need Wi-Fi on — they'll find each other even without a network.")
                .font(Style.footnote).foregroundStyle(.white.opacity(Style.dim))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private var grid: some View {
        let cols = mesh.peers.count <= 1 ? 1 : 2
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols),
                      spacing: 6) {
                ForEach(mesh.peers, id: \.self) { p in
                    tile(p).onTapGesture { focused = p }
                }
            }
            .padding(6)
        }
    }

    private func bigTile(_ p: MCPeerID) -> some View {
        VStack(spacing: 0) {
            tile(p, big: true)
            Button { focused = nil } label: {
                Label("All cameras", systemImage: "chevron.left")
                    .font(Style.body)
                    .padding(12).foregroundStyle(.white)
            }
        }
    }

    private func tile(_ p: MCPeerID, big: Bool = false) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let img = mesh.frames[p] {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Rectangle().fill(Color(white: 0.1)).aspectRatio(16.0/10.0, contentMode: .fit)
                    .overlay(
                        VStack(spacing: 6) {
                            ProgressView().tint(.white.opacity(0.5))
                            Text(mesh.isStreaming(p) ? "decoding…" : "connected — waiting for video")
                                .font(.caption2)
                        }.foregroundStyle(.white.opacity(0.5))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(p.displayName).font(Style.headline)
                if let s = mesh.statusLines[p], !s.isEmpty {
                    Text(s).font(Style.footnote).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .foregroundStyle(.white)
            .sentryGlass(RoundedRectangle(cornerRadius: Style.radiusSmall, style: .continuous))
            .padding(7)

            if mesh.talkingTo == p {
                Text("TALKING").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.red, in: Capsule()).foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: big ? 0 : 10))
        .contentShape(Rectangle())
        .overlay(alignment: .bottomTrailing) { armButton(p) }
    }

    private func armButton(_ p: MCPeerID) -> some View {
        // Reported by the peer itself in its video packet. Inferring it from the
        // status text read "armed" for any device with something in frame, and for
        // every device in tinted-glass mode, so the shield offered to disarm
        // cameras that were only previewing.
        let armed = mesh.peerArmed[p] ?? false
        return HStack(spacing: 6) {
            Button { mesh.send(command: armed ? "disarm" : "arm", to: p) } label: {
                Image(systemName: armed ? "shield.slash.fill" : "shield.fill")
                    .padding(9).sentryGlass(Circle(), interactive: true)
            }
            Button { mesh.send(command: "flip", to: p) } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .padding(9).sentryGlass(Circle(), interactive: true)
            }
            Menu {
                Button("Blackout that screen") { mesh.send(command: "stealthOn", to: p) }
                Button("Wake that screen") { mesh.send(command: "stealthOff", to: p) }
            } label: {
                Image(systemName: "moon.circle")
                    .padding(9).sentryGlass(Circle(), interactive: true)
            }

            Image(systemName: mesh.talkingTo == p ? "mic.fill" : "mic")
                .padding(9)
                .background(mesh.talkingTo == p ? AnyShapeStyle(Color.red)
                                                : AnyShapeStyle(Color.clear),
                            in: Circle())
                .sentryGlass(Circle(), interactive: true)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if mesh.talkingTo != p { mesh.beginTalking(to: p) } }
                        .onEnded { _ in mesh.endTalking() }
                )
        }
        .foregroundStyle(.white).padding(8)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").padding(10)
                .sentryGlass(Circle(), interactive: true)
        }
        .foregroundStyle(.white).padding()
    }

    private var bottomBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Hold the mic button to talk", systemImage: "mic.fill")
                    .font(Style.caption).foregroundStyle(.white.opacity(0.6))
                Text("sent \(mesh.framesSent) · received \(mesh.framesReceived)")
                    .font(Style.total)
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            Button { enterStealth() } label: {
                Label("Stealth", systemImage: "moon.fill")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .sentryGlass(Capsule(), interactive: true)
            }
            .foregroundStyle(.white)
        }
        .padding()
    }

    // MARK: Stealth

    /// Blacks out THIS device only. The camera, detector, peer connection and
    /// alerts all keep running underneath — nothing is signalled to any other
    /// node, so the device doing the watching never notices. Screen brightness
    /// goes to zero and a black curtain covers everything, so it reads as a
    /// locked phone in a pocket. Double-tap or swipe to bring it back.
    private var stealthCurtain: some View {
        Color.black.ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { exitStealth() }
            .gesture(DragGesture(minimumDistance: 50).onEnded { _ in exitStealth() })
            .overlay(alignment: .bottom) {
                Text("double-tap to wake")
                    .font(.caption2).foregroundStyle(.white.opacity(0.05))
                    .padding(.bottom, 34)
            }
            .transition(.opacity)
    }

    private func enterStealth() {
        priorBrightness = UIScreen.main.brightness
        withAnimation(.easeInOut(duration: 0.45)) { stealth = true }
        UIScreen.main.brightness = 0
    }

    /// Safety net: leaving this screen while blacked out used to leave the
    /// display at zero brightness with nothing on screen explaining why.
    private func restoreBrightnessIfNeeded() {
        if stealth { UIScreen.main.brightness = priorBrightness }
    }

    private func exitStealth() {
        UIScreen.main.brightness = priorBrightness
        withAnimation(.easeInOut(duration: 0.25)) { stealth = false }
    }
}

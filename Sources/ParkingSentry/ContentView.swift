import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var engine: DetectionEngine
    @EnvironmentObject var settings: Settings
    @ObservedObject private var peers = PeerMesh.shared
    @ObservedObject private var router = AlertRouter.shared
    @State private var showSettings = false
    @State private var showLog = false
    @State private var showMesh = false
    @State private var showClips = false
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "hasSeenWelcome")
    @State private var showWall = false
    @State private var showSource = false
    @ObservedObject private var remote = RemoteControl.shared
    @ObservedObject private var power = PowerManager.shared
    @State private var pinchStart: CGFloat = 1
    @State private var drawingGlassRegion = false
    @State private var showLayers = false
    @ObservedObject private var layers = LayerRegistry.shared
    @State private var drawMode: DrawMode?
    @State private var statusExpanded = false
    @State private var panelFocus: LayerGroup?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // While a privacy layer is compositing, the raw preview comes off
            // screen entirely and the redacted frames are shown in its place.
            // Drawing the blur on top would leave the unredacted feed underneath,
            // visible on any dropped frame.
            // Also used for a feed that is not this device's camera: a capture
            // preview layer can only display a capture session, so an outside
            // camera's frames are shown through the same renderer.
            if engine.composedFrame != nil || engine.feedDescription != nil {
                RenderedPreview()
                    .environmentObject(engine)
                    // Flipping is meaningless on an outside feed, and silently
                    // switching to the local camera on a double tap would be
                    // alarming rather than helpful.
                    .onTapGesture(count: 2) {
                        if engine.feedDescription == nil { engine.flipCamera() }
                    }
            } else {
                CameraPreview(session: engine.session, overlays: engine.overlays)
                    .ignoresSafeArea()
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                engine.setZoom(pinchStart * value)
                            }
                            .onEnded { _ in pinchStart = engine.zoom }
                    )
                    .onTapGesture(count: 2) { engine.flipCamera() }
            }

            if let problem = engine.cameraProblem {
                VStack(spacing: 14) {
                    Image(systemName: "video.slash.fill").font(.largeTitle)
                    Text(problem)
                        .font(.callout).multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                    HStack(spacing: 12) {
                        Button("Try again") { engine.startPreview() }
                            .buttonStyle(.bordered)
                        Button("Open Settings") {
                            if let u = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(u)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .foregroundStyle(.white)
            } else if !engine.previewLive {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Starting camera…")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }

            // Every active layer draws through one renderer, in normalized
            // bottom-left coordinates, so a new layer lands correctly with no
            // drawing code of its own.
            if !layers.activeIDs.isEmpty {
                LayerOverlayView()
                    .environmentObject(engine)
            }

            if drawMode != nil {
                LayerDrawOverlay(mode: $drawMode)
                    .environmentObject(engine)
                    .environmentObject(settings)
            }

            if settings.glassMode {
                GlassRegionOverlay(editing: $drawingGlassRegion)
                    .environmentObject(engine)
                    .environmentObject(settings)
            }

            // Chrome: status on top, tools down the right edge, the layer dock
            // and the one big control at the bottom. Nothing important lives in
            // a menu any more.
            VStack(spacing: Style.gap) {
                StatusBar(expanded: $statusExpanded)
                    .environmentObject(engine)

                HStack(alignment: .top) {
                    Spacer()
                    ToolRail(drawMode: $drawMode,
                             onFlip: { engine.flipCamera(); pinchStart = 1 },
                             onStealth: { enterStealth() },
                             onWall: { showWall = true },
                             onSource: { showSource = true })
                        .environmentObject(engine)
                        .environmentObject(settings)
                }

                Spacer(minLength: 0)

                if settings.glassMode {
                    GlassPanel(editing: $drawingGlassRegion)
                        .environmentObject(engine)
                        .environmentObject(settings)
                }

                LayerDock { group in
                    panelFocus = group
                    showLayers = true
                }

                controls
            }
            .padding(.horizontal, Style.inset)
            .padding(.vertical, 8)

            if remote.stealth {
                // Blacks out this device only. Detection, alerts and the peer
                // link all keep running underneath.
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
        }
        .onAppear { engine.startPreview() }
        .statusBarHidden(remote.stealth)
        .persistentSystemOverlays(remote.stealth ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings).environmentObject(engine)
        }
        .sheet(isPresented: $showLog) {
            EventLogView().environmentObject(engine)
        }
        .sheet(isPresented: $showMesh) {
            MeshView().environmentObject(engine)
        }
        .fullScreenCover(isPresented: $showWall) { VideoWallView() }
        .sheet(isPresented: $showClips) { ClipLibraryView().environmentObject(engine) }
        .sheet(isPresented: $showSource) {
            FeedPickerView()
                .environmentObject(engine)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showLayers) {
            LayerPanelView(focus: panelFocus).environmentObject(engine)
        }
        .fullScreenCover(isPresented: $showWelcome) { WelcomeView() }
        .onChange(of: router.openRecordings) { _, open in
            if open { showClips = true; router.openRecordings = false }
        }
    }

    private func enterStealth() {
        withAnimation(.easeInOut(duration: 0.45)) { RemoteControl.shared.stealth = true }
    }

    private func exitStealth() {
        withAnimation(.easeInOut(duration: 0.25)) { RemoteControl.shared.stealth = false }
    }

    private var controls: some View {
        HStack(spacing: Style.gap) {
            ArmButton().environmentObject(engine)

            SentryToolButton(icon: "film", label: "Recordings",
                             badge: engine.clipURLs.count) { showClips = true }

            SentryToolButton(icon: "list.bullet.rectangle", label: "Detections",
                             badge: engine.events.count) { showLog = true }

            Menu {
                Button { showMesh = true } label: {
                    Label("Devices", systemImage: "square.grid.2x2")
                }
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                Button { engine.relearnBackground() } label: {
                    Label("Relearn background", systemImage: "arrow.clockwise")
                }
                Button { showWelcome = true } label: {
                    Label("How this works", systemImage: "questionmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: Style.control, height: Style.control)
                    .foregroundStyle(.white)
                    .sentryGlass(Circle(), interactive: true)
            }
            .accessibilityLabel("More")
        }
    }

}

struct EventLogView: View {
    @EnvironmentObject var engine: DetectionEngine
    @Environment(\.dismiss) private var dismiss
    @State private var playing: URL?

    var body: some View {
        NavigationStack {
            List(engine.events) { e in
                HStack(alignment: .top, spacing: 12) {
                    if let img = e.thumbnail {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 84, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.date.formatted(date: .omitted, time: .standard)).font(.headline)
                        Text(e.text).font(.caption).foregroundStyle(.secondary)
                        if let url = e.clipURL {
                            Button { playing = url } label: {
                                Label("Watch recording", systemImage: "play.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .sheet(item: $playing) { url in
                VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
            }
            .navigationTitle("Detections")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { engine.clearEvents() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

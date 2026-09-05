import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: DetectionEngine
    @EnvironmentObject var settings: Settings
    @ObservedObject private var peers = PeerMesh.shared
    @State private var showSettings = false
    @State private var showLog = false
    @State private var showMesh = false
    @State private var showClips = false
    @State private var showWall = false
    @State private var stealth = false
    @State private var priorBrightness: CGFloat = UIScreen.main.brightness

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: engine.session, overlays: engine.overlays)
                .ignoresSafeArea()

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

            VStack {
                telemetry
                Spacer()
                controls
            }
            .padding()

            if stealth {
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
        .statusBarHidden(stealth)
        .persistentSystemOverlays(stealth ? .hidden : .automatic)
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
    }

    private func enterStealth() {
        priorBrightness = UIScreen.main.brightness
        withAnimation(.easeInOut(duration: 0.45)) { stealth = true }
        UIScreen.main.brightness = 0
    }

    private func exitStealth() {
        UIScreen.main.brightness = priorBrightness
        withAnimation(.easeInOut(duration: 0.25)) { stealth = false }
    }

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isArmed ? Color.red : (engine.isRunning ? Color.yellow : Color.gray))
                    .frame(width: 10, height: 10)
                Text(engine.isRunning
                     ? (engine.isArmed ? engine.status : "Arming in \(engine.armCountdown)s")
                     : "Ready")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if engine.depthAvailable {
                    Image(systemName: "sensor.tag.radiowaves.forward").font(.caption2)
                }
                if !peers.peers.isEmpty {
                    Label("\(peers.peers.count)", systemImage: "link")
                        .font(.caption2)
                }
            }

            // Two short rows rather than one long one: six fields on a single
            // line wrapped and overlapped on a phone.
            HStack(spacing: 12) {
                stat("motion", String(format: "%.3f", engine.motionScore))
                stat("shadow", String(format: "%.0f%%", engine.shadowRejectFraction * 100))
                stat("rate", String(format: "%.0fHz", engine.visionHz))
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                stat("sound", String(format: "%.0fdB", engine.soundLevelDB))
                stat("range", engine.rangeSourceLabel)
                stat("model", engine.modelStatus.hasPrefix("model failed") ? "failed" : engine.modelStatus)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Text(value).foregroundStyle(.white.opacity(0.9))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                engine.isRunning ? engine.stop() : engine.start()
            } label: {
                Label(engine.isRunning ? "Stop" : "Arm",
                      systemImage: engine.isRunning ? "stop.fill" : "shield.lefthalf.filled")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(engine.isRunning ? Color.red : Color.green, in: Capsule())
            .foregroundStyle(.white)

            circleButton("rectangle.on.rectangle") { showWall = true }
            circleButton("moon.fill") { enterStealth() }

            Menu {
                Button { engine.relearnBackground() } label: {
                    Label("Relearn background", systemImage: "arrow.clockwise")
                }
                Button { showLog = true } label: {
                    Label("Detections (\(engine.events.count))", systemImage: "list.bullet.rectangle")
                }
                Button { showClips = true } label: {
                    Label("Recordings (\(engine.clipURLs.count))", systemImage: "film")
                }
                Button { showMesh = true } label: {
                    Label("Devices", systemImage: "square.grid.2x2")
                }
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if !engine.events.isEmpty {
                            Text("\(engine.events.count)")
                                .font(.caption2.bold())
                                .padding(5)
                                .background(Color.red, in: Circle())
                                .foregroundStyle(.white)
                                .offset(x: 4, y: -4)
                        }
                    }
            }
        }
        .foregroundStyle(.white)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

struct EventLogView: View {
    @EnvironmentObject var engine: DetectionEngine
    @Environment(\.dismiss) private var dismiss

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
                    }
                }
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

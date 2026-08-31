import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: DetectionEngine
    @EnvironmentObject var settings: Settings
    @State private var showSettings = false
    @State private var showLog = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: engine.session, overlays: engine.overlays)
                .ignoresSafeArea()

            VStack {
                telemetry
                Spacer()
                controls
            }
            .padding()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings).environmentObject(engine)
        }
        .sheet(isPresented: $showLog) {
            EventLogView().environmentObject(engine)
        }
    }

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(engine.isArmed ? Color.red : (engine.isRunning ? Color.yellow : Color.gray))
                    .frame(width: 12, height: 12)
                Text(engine.isRunning
                     ? (engine.isArmed ? engine.status : "Arming in \(engine.armCountdown)s")
                     : "Idle")
                    .font(.headline)
                Spacer()
                if engine.depthAvailable {
                    Label("LiDAR", systemImage: "sensor.tag.radiowaves.forward")
                        .font(.caption)
                }
            }
            HStack(spacing: 14) {
                Text(String(format: "motion %.3f", engine.motionScore))
                Text(String(format: "shadow-rejected %.0f%%", engine.shadowRejectFraction * 100))
                Text(String(format: "%.0f Hz", engine.visionHz))
                Text("range \(engine.rangeSourceLabel)")
                Text(engine.modelStatus)
                Text(String(format: "%.0f dB (amb %.0f)", engine.soundLevelDB, engine.ambientDB))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                engine.isRunning ? engine.stop() : engine.start()
            } label: {
                Label(engine.isRunning ? "Stop" : "Arm",
                      systemImage: engine.isRunning ? "stop.fill" : "shield.lefthalf.filled")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .background(engine.isRunning ? Color.red : Color.green, in: Capsule())
            .foregroundStyle(.white)

            Button { engine.relearnBackground() } label: {
                Image(systemName: "arrow.clockwise").padding(12)
            }
            .background(.ultraThinMaterial, in: Circle())

            Button { showLog = true } label: {
                Image(systemName: "list.bullet.rectangle").padding(12)
                    .overlay(alignment: .topTrailing) {
                        if !engine.events.isEmpty {
                            Text("\(engine.events.count)")
                                .font(.caption2).padding(4)
                                .background(Color.red, in: Circle())
                                .foregroundStyle(.white)
                                .offset(x: 6, y: -6)
                        }
                    }
            }
            .background(.ultraThinMaterial, in: Circle())

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").padding(12)
            }
            .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
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

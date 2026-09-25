import SwiftUI
import UIKit
import MultipeerConnectivity

/// The controller screen: every node in the mesh, and everything any of them has seen.
struct MeshView: View {
    @ObservedObject private var mesh = MeshClient.shared
    @ObservedObject private var peer = PeerMesh.shared
    @EnvironmentObject var engine: DetectionEngine
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var draftName = MeshClient.shared.deviceName

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    diag("Link running", peer.running ? "yes" : "NO")
                    diag("Devices seen nearby", "\(peer.found.count)")
                    diag("Connected", "\(peer.peers.count)")
                    if let e = peer.browseError {
                        Text("Discovery failed: \(e)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if let e = peer.advertiseError {
                        Text("Being findable failed: \(e)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if peer.found.isEmpty {
                        Text("Nothing seen yet. Both devices need MotionSentry open, Wi-Fi switched on, and Local Network permission allowed for MotionSentry in Settings → Privacy & Security → Local Network. They do not need to be on the same Wi-Fi network, but Wi-Fi must be on.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if peer.peers.isEmpty {
                        Text("Devices are visible but not connecting. Re-invites are sent every few seconds automatically.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Restart connection") { peer.restart() }
                    Button("Open Local Network settings") {
                        if let u = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(u)
                        }
                    }
                }

                if !peer.found.isEmpty {
                    Section("Seen nearby") {
                        ForEach(peer.found, id: \.self) { p in
                            HStack {
                                Circle()
                                    .fill(peer.peers.contains(p) ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(p.displayName).font(.subheadline)
                                Spacer()
                                Text(peer.peers.contains(p) ? "connected" : "connecting…")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("This device") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(mesh.deviceName).foregroundStyle(.secondary)
                        Button("Rename") { draftName = mesh.deviceName; renaming = true }
                            .font(.caption)
                    }
                    Text("Give each node a name you'll recognise in an alert — \"Office Mac\", \"Lot iPad\".")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Nodes") {
                    if mesh.devices.isEmpty {
                        Text("No other devices have checked in yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(mesh.devices) { d in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(d.isLive ? (d.isArmed ? Color.red : Color.green) : Color.gray)
                                .frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.headline)
                                Text(nodeDetail(d)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.hasLidar {
                                Image(systemName: "sensor.tag.radiowaves.forward")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Everything seen") {
                    if mesh.feed.isEmpty {
                        Text("Nothing detected yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(mesh.feed) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.deviceName).font(.subheadline).bold()
                                Spacer()
                                if let t = e.occurredAt {
                                    Text(t.formatted(date: .omitted, time: .standard))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(e.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Mesh")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("Device name", isPresented: $renaming) {
                TextField("Name", text: $draftName)
                Button("Save") {
                    mesh.deviceName = draftName
                    // Rebuild the peer identity so other devices see the new
                    // name now rather than after a force-quit.
                    PeerMesh.shared.renamed(to: draftName)
                    mesh.heartbeat(armed: engine.isArmed,
                                   soundDB: engine.soundLevelDB,
                                   ambientDB: engine.ambientDB)
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { mesh.beginPolling() }
            .onDisappear { mesh.endPolling() }
        }
    }

    private func diag(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func nodeDetail(_ d: MeshDevice) -> String {
        var parts: [String] = []
        parts.append(d.isLive ? (d.isArmed ? "armed" : "idle") : "offline")
        if let db = d.soundDb { parts.append(String(format: "%.0f dB", db)) }
        if let b = d.battery, b >= 0 { parts.append(String(format: "%.0f%%", b * 100)) }
        if let t = d.lastSeen, !d.isLive {
            parts.append("last seen " + t.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}

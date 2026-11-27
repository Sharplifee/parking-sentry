// FeedPickerView.swift — choosing which camera the layers run on.
//
// Everything the app can read video from, in one list, in the order someone
// would look for it: this device, a camera plugged into it, cameras found on the
// same network, an address typed by hand, and the paired devices already
// running MotionSentry.
//
// Whatever is chosen feeds the same pipeline. The motion gate, the detector, all
// fifty-nine layers, the privacy composite, clip recording and the stream to
// paired devices behave identically, because by the time a frame reaches them
// nothing records where it came from.

import SwiftUI
import AVFoundation
import MultipeerConnectivity

struct FeedPickerView: View {
    @EnvironmentObject var engine: DetectionEngine
    @EnvironmentObject var settings: Settings
    @ObservedObject private var peers = PeerMesh.shared
    @StateObject private var discovery = FeedDiscovery()
    @Environment(\.dismiss) private var dismiss

    @State private var typed = ""
    @State private var usbCameras: [AVCaptureDevice] = []

    var body: some View {
        NavigationStack {
            Form {
                thisDevice
                if !usbCameras.isEmpty { plugged }
                network
                byAddress
                paired
                about
            }
            .navigationTitle("Video source")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            discovery.start()
            refreshUSB()
        }
        .onDisappear { discovery.stop() }
    }

    // MARK: This device

    private var thisDevice: some View {
        Section("This device") {
            row(title: engine.usingFrontCamera ? "Front camera" : "Back camera",
                subtitle: engine.feedDescription == nil
                    ? "In use — full resolution, depth and lens data"
                    : "Tap to come back to this device's camera",
                icon: "iphone",
                selected: engine.feedDescription == nil) {
                engine.stopExternalFeed()
                dismiss()
            }
            if engine.feedDescription == nil {
                Toggle("Front camera", isOn: $settings.useFrontCamera)
            }
        }
    }

    // MARK: USB

    private var plugged: some View {
        Section("Plugged in") {
            ForEach(usbCameras, id: \.uniqueID) { device in
                row(title: device.localizedName,
                    subtitle: "USB camera — used automatically as the main camera",
                    icon: "cable.connector",
                    selected: false) { }
                    .disabled(true)
            }
            Text("A USB camera is picked up as this device's camera, so everything works exactly as the built-in one does. iPadOS is the only place Apple enables USB cameras; an iPhone will never list one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Network

    private var network: some View {
        Section {
            if discovery.found.isEmpty {
                HStack(spacing: 10) {
                    if discovery.isBrowsing { ProgressView().controlSize(.small) }
                    Text(discovery.isBrowsing
                         ? "Looking for cameras on this network…"
                         : "Not searching.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(discovery.found) { camera in
                row(title: camera.name,
                    subtitle: camera.subtitle,
                    icon: icon(for: camera.serviceType),
                    // Both sides are optional, so a camera with no working
                    // address compared equal to "no outside feed running" and
                    // every unusable device on the network drew a tick as if it
                    // were the one being watched.
                    selected: camera.workingURL != nil
                        && engine.feedDescription == camera.workingURL?.host,
                    busy: discovery.probing.contains(camera.id)) {
                    guard let url = camera.workingURL else { return }
                    engine.useExternalFeed(url: url)
                    dismiss()
                }
                .disabled(camera.workingURL == nil)
            }
        } header: {
            Text("On this network")
        } footer: {
            Text("Found by the name cameras broadcast on the network. Each one is then tried on the usual video paths until one answers, so what you tap is an address already known to work.")
        }
    }

    // MARK: Typed address

    private var byAddress: some View {
        Section {
            TextField("http://192.168.1.50/video", text: $typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(Style.body)
            Button("Use this address") {
                guard let url = URL(string: typed.trimmingCharacters(in: .whitespaces)),
                      FeedDirectory.isSupported(url) else { return }
                engine.useExternalFeed(url: url)
                dismiss()
            }
            .disabled(URL(string: typed.trimmingCharacters(in: .whitespaces))
                .map { !FeedDirectory.isSupported($0) } ?? true)
        } header: {
            Text("By address")
        } footer: {
            Text(FeedDirectory.note)
        }
    }

    // MARK: Paired devices

    private var paired: some View {
        Section {
            if peers.peers.isEmpty {
                Text("No paired devices connected. Open All devices to pair another phone or iPad running MotionSentry.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(peers.peers, id: \.self) { peer in
                row(title: peer.displayName,
                    subtitle: peers.frames[peer] == nil
                        ? "Connected, no video yet"
                        : "Run this device's layers on its camera",
                    icon: "iphone.radiowaves.left.and.right",
                    selected: engine.feedDescription == peer.displayName) {
                    engine.usePeerFeed(peer: peer)
                    dismiss()
                }
                .disabled(peers.frames[peer] == nil)
            }
        } header: {
            Text("Paired devices")
        } footer: {
            Text(PeerFeed.caveat)
        }
    }

    private var about: some View {
        Section {
            if let problem = engine.feedProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("Distances are measured from the lens data and depth sensor this device reports, which an outside camera does not have. On any source other than this device's own camera, ranges and measured heights fall back to an estimate from the field of view and are rougher.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("What changes on an outside feed")
        }
    }

    // MARK: Pieces

    private func icon(for serviceType: String) -> String {
        switch serviceType {
        case "_rtsp._tcp", "_onvif._tcp", "_axis-video._tcp": return "video"
        case "_msentry._tcp": return "iphone.radiowaves.left.and.right"
        default: return "network"
        }
    }

    private func row(title: String,
                     subtitle: String,
                     icon: String,
                     selected: Bool,
                     busy: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Style.headline)
                    Text(subtitle)
                        .font(Style.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if busy { ProgressView().controlSize(.small) }
                else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A USB camera is discovered, not configured, so the list is read each time
    /// the sheet opens rather than cached.
    private func refreshUSB() {
        usbCameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified).devices
    }
}

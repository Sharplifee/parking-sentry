import SwiftUI

/// The toggle board. Every layer the app knows about, grouped, with its live badge,
/// its measured cost, and — for the ones that cannot run here — the reason, stated
/// plainly rather than hidden.
struct LayerPanelView: View {
    @ObservedObject var registry = LayerRegistry.shared
    @ObservedObject var geometry = LayerGeometry.shared
    @ObservedObject var store = ModelStore.shared
    @EnvironmentObject var engine: DetectionEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("\(registry.activeIDs.count) on", systemImage: "square.stack.3d.up.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.1f ms/frame", registry.activeCostMS))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(costColor)
                    }
                    if let note = registry.governorNote {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                    Text("Every layer below stays loaded and warm, so flipping one on shows output within a frame. Only the ones switched on consume frames — running two dozen models at once would throttle the phone and stutter the feed, which is the one thing an overlay must never do.")
                        .font(.caption).foregroundStyle(.secondary)
                    if registry.activeIDs.count > 0 {
                        Button("Turn everything off") { registry.deactivateAll() }
                            .font(.caption)
                    }
                }

                ForEach(LayerGroup.allCases) { group in
                    let layers = registry.layers(in: group)
                    if !layers.isEmpty {
                        Section {
                            ForEach(layers, id: \.id) { layer in
                                row(layer)
                            }
                        } header: {
                            HStack {
                                Label(group.rawValue, systemImage: group.icon)
                                Spacer()
                                let n = registry.activeCount(in: group)
                                if n > 0 { Text("\(n) on").foregroundStyle(.cyan) }
                            }
                        }
                    }
                }

                Section("Downloaded models") {
                    Text("These capabilities have no Apple API, so they run on models downloaded once and compiled on this device. Switching the layer on starts the download; nothing is fetched until you do.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(ModelStore.manifest.keys).sorted(), id: \.self) { id in
                        modelRow(id)
                    }
                    if store.diskUsed > 0 {
                        Text("Using \(ByteCountFormatter.string(fromByteCount: store.diskUsed, countStyle: .file)) on disk")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Zones and lines") {
                    if geometry.zones.isEmpty && geometry.lines.isEmpty {
                        Text("Zones, dwell timers and crossing counts need a shape to work with. Close this and use Draw on the main screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(geometry.zones) { zone in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(zone.name).font(.subheadline)
                                Spacer()
                                Button(role: .destructive) {
                                    geometry.removeZone(zone.id)
                                    geometry.refreshCaches()
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                            }
                            Stepper("Alert at \(zone.alertAtCount == 0 ? "off" : "\(zone.alertAtCount) inside")",
                                    value: binding(for: zone.id, \.alertAtCount), in: 0...20)
                                .font(.caption)
                            Stepper("Loitering alert \(zone.alertAfterSeconds == 0 ? "off" : "\(Int(zone.alertAfterSeconds))s")",
                                    value: binding(for: zone.id, \.alertAfterSeconds), in: 0...600, step: 15)
                                .font(.caption)
                        }
                    }
                    ForEach(geometry.lines) { line in
                        HStack {
                            Text(line.name).font(.subheadline)
                            Spacer()
                            Button(role: .destructive) {
                                geometry.removeLine(line.id)
                                geometry.refreshCaches()
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                if !registry.feed.isEmpty {
                    Section("Layer output") {
                        ForEach(registry.feed.prefix(40)) { line in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.text).font(.caption)
                                Text(registry.layer(line.layer)?.title ?? line.layer)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("AI layers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ id: String) -> some View {
        let remote = ModelStore.manifest[id]
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(remote?.title ?? id).font(.subheadline)
                    Text("\((remote?.totalBytes ?? 0) / 1_000_000) MB · \(remote?.license ?? "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                switch store.state(id) {
                case .ready:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Button(role: .destructive) { store.remove(id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                case .absent:
                    Button("Download") { store.fetch(id) }
                        .font(.caption).buttonStyle(.bordered)
                case .downloading(let f):
                    Text(String(format: "%.0f%%", f * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.cyan)
                case .compiling:
                    Text("compiling").font(.caption).foregroundStyle(.cyan)
                case .failed:
                    Button("Retry") { store.fetch(id) }
                        .font(.caption).buttonStyle(.bordered).tint(.orange)
                }
            }
            if case .downloading(let f) = store.state(id) {
                ProgressView(value: f).tint(.cyan)
            }
            if case .failed(let why) = store.state(id) {
                Text(why).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var costColor: Color {
        let fps = Double(max(1, PowerManager.captureFPSSnapshot))
        let budget = (1000.0 / fps) * 0.55
        if registry.activeCostMS > budget { return .orange }
        if registry.activeCostMS > budget * 0.6 { return .yellow }
        return .secondary
    }

    private func binding<V>(for id: UUID,
                            _ path: WritableKeyPath<LayerGeometry.Zone, V>) -> Binding<V> {
        Binding(
            get: {
                guard let z = geometry.zones.first(where: { $0.id == id }) else {
                    return LayerGeometry.Zone(name: "", rect: .zero)[keyPath: path]
                }
                return z[keyPath: path]
            },
            set: { newValue in
                guard let i = geometry.zones.firstIndex(where: { $0.id == id }) else { return }
                geometry.zones[i][keyPath: path] = newValue
                geometry.refreshCaches()
            })
    }

    @ViewBuilder
    private func row(_ layer: AILayer) -> some View {
        let on = registry.isActive(layer.id)
        let output = registry.outputs[layer.id]
        let usable = layer.availability.isUsable

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(layer.title)
                            .font(.subheadline.weight(on ? .semibold : .regular))
                            .foregroundStyle(usable ? .primary : .secondary)
                        if let badge = output?.badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.cyan.opacity(0.22), in: Capsule())
                        }
                        if let stretched = registry.throttled[layer.id] {
                            Text("1/\(stretched)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(layer.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = layer.availability.reason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(usable ? .orange : .red.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Toggle("", isOn: Binding(
                        get: { on },
                        set: { registry.setActive(layer.id, $0) }))
                        .labelsHidden()
                        .disabled(!usable)
                    if on, let ms = registry.cost[layer.id], ms > 0.05 {
                        Text(String(format: "%.1f ms", ms))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}

/// The quick-access strip on the camera screen: the layers that are on, tappable to
/// turn off, so the common case never needs the full panel.
struct ActiveLayerStrip: View {
    @ObservedObject var registry = LayerRegistry.shared

    var body: some View {
        if !registry.activeIDs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(registry.all.filter { registry.activeIDs.contains($0.id) }, id: \.id) { layer in
                        Button {
                            registry.setActive(layer.id, false)
                        } label: {
                            HStack(spacing: 4) {
                                Text(layer.title).font(.system(size: 11, weight: .semibold))
                                if let b = registry.outputs[layer.id]?.badge {
                                    Text(b).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.cyan)
                                }
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }
}

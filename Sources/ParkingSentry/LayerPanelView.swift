import SwiftUI

/// The layer board.
///
/// Three things make forty-one layers usable rather than intimidating, and they are
/// the whole structure of this screen: a preset row that answers "which ones do I
/// want", an "on now" section so the current state is never in doubt, and search,
/// because scrolling nine groups to find one layer is not discovery.
///
/// Everything below uses one row shape, so a layer that needs a download, a layer
/// that needs a zone drawn, and a layer that cannot run on this device all read the
/// same way — title, one line of plain English, state, switch.
struct LayerPanelView: View {
    @ObservedObject var registry = LayerRegistry.shared
    @ObservedObject var geometry = LayerGeometry.shared
    @ObservedObject var store = ModelStore.shared
    @EnvironmentObject var engine: DetectionEngine
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var showUnavailable = false
    /// Set by the main screen when a category button opens this panel, so it
    /// lands on what was tapped.
    var focus: LayerGroup?

    private var matches: [AILayer] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return [] }
        return registry.all.filter {
            $0.title.lowercased().contains(term)
                || $0.detail.lowercased().contains(term)
                || $0.group.rawValue.lowercased().contains(term)
        }
    }

    private var activeLayers: [AILayer] {
        registry.all.filter { registry.activeIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !search.isEmpty {
                    Section("Matching “\(search)”") {
                        if matches.isEmpty {
                            Text("Nothing matches that.")
                                .foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(matches, id: \.id) { LayerRow(layer: $0) }
                    }
                } else {
                    presetSection
                    if !activeLayers.isEmpty { onNowSection }
                    ForEach(groupsToShow) { group in
                        groupSection(group)
                    }
                    modelSection
                    geometrySection
                    if !registry.feed.isEmpty { outputSection }
                    // The search field floats over the bottom of the list, so
                    // without this the last row of the last section can never be
                    // scrolled out from under it.
                    Color.clear
                        .frame(height: 44)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search layers")
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !activeLayers.isEmpty {
                        Button("All off") { registry.deactivateAll() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private var groupsToShow: [LayerGroup] {
        guard let focus else { return LayerGroup.allCases }
        // Focused group first, the rest still reachable below it.
        return [focus] + LayerGroup.allCases.filter { $0 != focus }
    }

    // MARK: Presets

    private var presetSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LayerPreset.all) { preset in
                        presetCard(preset)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
            Text("Start here")
        } footer: {
            Text("A preset switches on the handful of layers that do one job, and switches the rest off. You can adjust anything afterwards.")
        }
    }

    private func presetCard(_ preset: LayerPreset) -> some View {
        let isCurrent = LayerPreset.matching(registry.activeIDs)?.id == preset.id
        let mb = preset.downloadMB
        return Button {
            preset.apply()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: preset.icon).font(.headline)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                Text(preset.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(preset.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if mb > 0 {
                    Label("\(mb) MB", systemImage: "arrow.down.circle")
                        .font(.caption2).foregroundStyle(.cyan)
                } else {
                    Label("\(preset.layers.count) layers", systemImage: "square.stack.3d.up")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .frame(width: 164, height: 134, alignment: .topLeading)
            .background(isCurrent ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isCurrent ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: On now

    private var onNowSection: some View {
        Section {
            ForEach(activeLayers, id: \.id) { LayerRow(layer: $0) }
        } header: {
            HStack {
                Text("On now")
                Spacer()
                Text(String(format: "%.0f ms a frame", registry.activeCostMS))
                    .font(.caption.monospaced())
                    .foregroundStyle(costColor)
            }
        } footer: {
            if let note = registry.governorNote {
                Text(note).foregroundStyle(.orange)
            } else {
                Text("Every layer stays loaded, so switching one on shows output within a frame. Only the ones on here use any power.")
            }
        }
    }

    // MARK: Groups

    @ViewBuilder
    private func groupSection(_ group: LayerGroup) -> some View {
        let all = registry.layers(in: group)
        let usable = all.filter { $0.availability.isUsable }
        let blocked = all.filter { !$0.availability.isUsable }
        if !all.isEmpty {
            Section {
                ForEach(usable, id: \.id) { LayerRow(layer: $0) }
                if !blocked.isEmpty {
                    DisclosureGroup("Not available on this device (\(blocked.count))") {
                        ForEach(blocked, id: \.id) { LayerRow(layer: $0) }
                    }
                    .font(.caption)
                }
            } header: {
                HStack {
                    Label(group.rawValue, systemImage: group.icon)
                    Spacer()
                    let n = registry.activeCount(in: group)
                    if n > 0 {
                        Text("\(n) on")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
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

    // MARK: Models

    private var modelSection: some View {
        Section {
            ForEach(Array(ModelStore.manifest.keys).sorted(), id: \.self) { id in
                ModelRow(id: id)
            }
            if store.diskUsed > 0 {
                HStack {
                    Text("On this device").font(.caption)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: store.diskUsed, countStyle: .file))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Downloaded models", systemImage: "arrow.down.circle")
        } footer: {
            Text("A few capabilities have no Apple equivalent and run on a model downloaded once and compiled here. Nothing is fetched until you switch the layer on, and you can delete any of them.")
        }
    }

    // MARK: Zones

    private var geometrySection: some View {
        Section {
            if geometry.zones.isEmpty && geometry.lines.isEmpty {
                Label("Nothing drawn yet", systemImage: "rectangle.dashed")
                    .foregroundStyle(.secondary).font(.callout)
                Text("Close this and use Draw on the camera screen to add a zone to watch, a line to count crossings, or an area to never record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(geometry.zones) { zone in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(zone.name, systemImage: "rectangle.dashed")
                            .font(.subheadline)
                        Spacer()
                        Button(role: .destructive) {
                            geometry.removeZone(zone.id)
                            geometry.refreshCaches()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    Stepper(zone.alertAtCount == 0
                            ? "Alert when crowded: off"
                            : "Alert at \(zone.alertAtCount) inside",
                            value: binding(for: zone.id, \.alertAtCount), in: 0...20)
                        .font(.caption)
                    Stepper(zone.alertAfterSeconds == 0
                            ? "Alert on loitering: off"
                            : "Alert after \(Int(zone.alertAfterSeconds))s",
                            value: binding(for: zone.id, \.alertAfterSeconds),
                            in: 0...600, step: 15)
                        .font(.caption)
                }
            }
            ForEach(geometry.lines) { line in
                HStack {
                    Label(line.name, systemImage: "line.diagonal")
                        .font(.subheadline)
                    Spacer()
                    Button(role: .destructive) {
                        geometry.removeLine(line.id)
                        geometry.refreshCaches()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Label("Zones and lines", systemImage: "scope")
        }
    }

    // MARK: Output

    private var outputSection: some View {
        Section {
            ForEach(registry.feed.prefix(30)) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text).font(.callout)
                    Text(registry.layer(line.layer)?.title ?? line.layer)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("What the layers are saying", systemImage: "text.bubble")
        }
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
}

// MARK: - One row shape for every layer

/// Every layer reads the same way whatever its state: name, a line of plain
/// English, what it is currently reporting, and a switch. The state line is the
/// part that matters — a switch that does nothing because a model is missing or a
/// zone has not been drawn is the single most confusing thing this screen could do,
/// so the reason always sits right under the name.
private struct LayerRow: View {
    let layer: AILayer
    @ObservedObject private var registry = LayerRegistry.shared

    var body: some View {
        let on = registry.activeIDs.contains(layer.id)
        let output = registry.outputs[layer.id]
        let usable = layer.availability.isUsable

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(layer.title)
                        .font(.body)
                        .foregroundStyle(usable ? .primary : .secondary)
                    if let badge = output?.badge, on {
                        Text(badge)
                            .font(Style.readout)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .lineLimit(1)
                    }
                    // Session figures sit outside the pill and in the secondary
                    // colour, so there is never a question about which number
                    // describes the scene and which describes the session.
                    if let total = output?.total, on {
                        Text(total)
                            .font(Style.total)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let slower = registry.throttled[layer.id], on {
                        Label("1/\(slower)", systemImage: "tortoise")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }

                Text(layer.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = layer.availability.reason {
                    Label(reason, systemImage: statusIcon)
                        .font(.caption2)
                        .foregroundStyle(usable ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if on, let ms = registry.cost[layer.id], ms > 0.05 {
                    Text(String(format: "takes %.0f ms each time", ms))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { on },
                set: { registry.setActive(layer.id, $0) }))
                .labelsHidden()
                .disabled(!usable)
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        switch layer.availability {
        case .needsDownload:  return "arrow.down.circle"
        case .needsSetup:     return "pencil.and.outline"
        case .needsNetwork:   return "wifi"
        case .needsHardware:  return "exclamationmark.triangle"
        case .modelMissing:   return "exclamationmark.triangle"
        case .noPublicAPI:    return "info.circle"
        case .available:      return "checkmark"
        }
    }
}

// MARK: - Model row

private struct ModelRow: View {
    let id: String
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        let remote = ModelStore.manifest[id]
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(remote?.title ?? id).font(.body)
                    Text("\((remote?.totalBytes ?? 0) / 1_000_000) MB · \(remote?.license ?? "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                switch store.state(id) {
                case .ready:
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Button(role: .destructive) { store.remove(id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                case .absent:
                    Button("Get") { store.fetch(id) }
                        .buttonStyle(.bordered).font(.caption)
                case .downloading:
                    ProgressView().controlSize(.small)
                case .compiling:
                    Text("compiling").font(.caption).foregroundStyle(.tint)
                case .failed:
                    Button("Retry") { store.fetch(id) }
                        .buttonStyle(.bordered).font(.caption).tint(.orange)
                }
            }
            if case .downloading(let fraction) = store.state(id) {
                ProgressView(value: fraction)
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if case .failed(let why) = store.state(id) {
                Text(why).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SwiftUI

/// The pieces of the camera screen, pulled out of one long view.
///
/// The old screen put the app's main feature — the layers — behind an ellipsis
/// menu, three levels from the surface, and spent the top of the display on eight
/// monospaced numbers. This inverts that: state is one line, the layers that are
/// on are visible and one tap from off, and every tool is a button rather than a
/// menu item.

// MARK: - Status

/// One line that says what the app is doing, and expands when tapped.
///
/// The eight readouts the old screen showed permanently are still here, because
/// they matter when something looks wrong — but they are not what someone glancing
/// at a propped-up phone needs. Collapsed is the answer to "is it watching"; open
/// is the answer to "why is it behaving like that".
struct StatusBar: View {
    @EnvironmentObject var engine: DetectionEngine
    @ObservedObject var peers = PeerMesh.shared
    @ObservedObject var power = PowerManager.shared
    @ObservedObject var registry = LayerRegistry.shared
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle().stroke(stateColor.opacity(0.35), lineWidth: 5)
                                .scaleEffect(engine.isArmed ? 1.6 : 1)
                                .opacity(engine.isArmed ? 0.9 : 0)
                                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                                           value: engine.isArmed))

                    Text(headline)
                        .font(Style.headline)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if !peers.peers.isEmpty {
                        Label("\(peers.peers.count)", systemImage: "link")
                            .font(.caption2)
                    }
                    if engine.depthAvailable {
                        Image(systemName: "sensor.tag.radiowaves.forward").font(.caption2)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(.white.opacity(0.15))
                readouts
            }
        }
        .padding(.horizontal, Style.inset)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .sentryGlass(RoundedRectangle(cornerRadius: Style.radiusMedium, style: .continuous))
    }

    private var headline: String {
        if engine.cameraProblem != nil { return "Camera unavailable" }
        if !engine.previewLive { return "Starting camera…" }
        if !engine.isRunning { return "Ready — not watching" }
        if !engine.isArmed { return "Arming in \(engine.armCountdown)s" }
        return engine.status
    }

    private var stateColor: Color {
        if engine.cameraProblem != nil { return .red }
        if engine.isArmed { return .red }
        if engine.isRunning { return .yellow }
        return .gray
    }

    private var readouts: some View {
        // A grid rather than two hand-packed rows, so nothing overlaps at any
        // width and adding a readout does not mean re-balancing the layout.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)],
                  alignment: .leading, spacing: 6) {
            readout("motion", String(format: "%.3f", engine.motionScore))
            readout("shadow", String(format: "%.0f%%", engine.shadowRejectFraction * 100))
            readout("vision", String(format: "%.0f Hz", engine.visionHz))
            readout("sound", String(format: "%.0f dB", engine.soundLevelDB))
            readout("range", engine.rangeSourceLabel)
            readout("zoom", String(format: "%.1f×", engine.zoom))
            readout("camera", engine.usingFrontCamera ? "front" : "back")
            readout("power", power.summary)
            if !registry.activeIDs.isEmpty {
                readout("layers", String(format: "%.1f ms", registry.activeCostMS))
            }
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.white.opacity(Style.dimmer))
            Text(value).foregroundStyle(.white.opacity(0.9))
        }
        .sentryReadout()
    }
}

// MARK: - Layer dock

/// The layers that are on, and the way to the rest.
///
/// This is the change that matters most: what is running is now visible on the
/// camera screen, each one is a single tap from off, and the way to all of them is
/// a labelled button rather than the third item of a menu.
struct LayerDock: View {
    @ObservedObject var registry = LayerRegistry.shared
    let openPanel: (LayerGroup?) -> Void

    var body: some View {
        let active = registry.all.filter { registry.activeIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: 8) {
            if !active.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    SentryGlassGroup(spacing: 7) {
                        HStack(spacing: 7) {
                        ForEach(active, id: \.id) { layer in
                            SentryChip(
                                title: layer.title,
                                value: registry.outputs[layer.id]?.badge,
                                total: registry.outputs[layer.id]?.total,
                                icon: "xmark",
                                tone: .active) {
                                    registry.setActive(layer.id, false)
                                }
                        }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .frame(height: 34)
            }

            // Group shortcuts: a direct route into the part of the panel someone
            // actually wants, with the count of what is on in each.
            ScrollView(.horizontal, showsIndicators: false) {
                SentryGlassGroup(spacing: 7) {
                HStack(spacing: 7) {
                    SentryChip(title: active.isEmpty ? "Choose layers" : "All layers",
                               value: active.isEmpty ? nil : "\(active.count)",
                               icon: "square.stack.3d.up",
                               tone: active.isEmpty ? .warn : .neutral) {
                        openPanel(nil)
                    }
                    ForEach(LayerGroup.allCases) { group in
                        let n = registry.activeCount(in: group)
                        SentryChip(title: group.rawValue,
                                   value: n > 0 ? "\(n)" : nil,
                                   icon: group.icon,
                                   tone: n > 0 ? .active : .neutral) {
                            openPanel(group)
                        }
                    }
                }
                .padding(.horizontal, 2)
                }
            }
            .frame(height: 34)
        }
    }
}

// MARK: - Tool rail

/// The tools, as buttons down the right edge.
///
/// Everything here used to be a menu item. They are one-handed reachable, they
/// show their own state, and the count badges mean the screen tells you there are
/// recordings to look at instead of waiting to be asked.
struct ToolRail: View {
    @EnvironmentObject var engine: DetectionEngine
    @EnvironmentObject var settings: Settings
    @Binding var drawMode: DrawMode?
    let onFlip: () -> Void
    let onStealth: () -> Void
    let onWall: () -> Void

    var body: some View {
        SentryGlassGroup(spacing: 8) {
        VStack(spacing: 8) {
            SentryToolButton(icon: engine.usingFrontCamera
                             ? "arrow.triangle.2.circlepath.camera.fill"
                             : "arrow.triangle.2.circlepath.camera",
                             label: "Flip camera", action: onFlip)

            Menu {
                Button { drawMode = .zone } label: {
                    Label("Zone to watch", systemImage: "rectangle.dashed")
                }
                Button { drawMode = .line } label: {
                    Label("Line to count crossings", systemImage: "line.diagonal")
                }
                Button { drawMode = .redaction } label: {
                    Label("Area to never record", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: Style.control, height: Style.control)
                    .foregroundStyle(.white)
                    .sentryGlass(Circle(), interactive: true)
            }
            .accessibilityLabel("Draw on the feed")

            SentryToolButton(icon: settings.glassMode ? "car.fill" : "car",
                             label: "Tinted glass mode",
                             tone: settings.glassMode ? .alert : .neutral) {
                engine.setGlassMode(!settings.glassMode)
            }

            SentryToolButton(icon: "rectangle.on.rectangle",
                             label: "All devices", action: onWall)

            SentryToolButton(icon: "moon.fill", label: "Stealth", action: onStealth)
        }
        }
    }
}

// MARK: - Arm control

/// The one thing the app is for, sized accordingly.
struct ArmButton: View {
    @EnvironmentObject var engine: DetectionEngine

    var body: some View {
        Button {
            engine.isRunning ? engine.stop() : engine.start()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: engine.isRunning ? "stop.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 16, weight: .medium))
                // The one place in the app that carries weight, because it is the
                // one control the whole screen exists for.
                Text(engine.isRunning ? "Stop" : "Start watching")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.white)
            .background(engine.isRunning
                        ? AnyShapeStyle(Color.red.gradient)
                        : AnyShapeStyle(Color.green.gradient),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(engine.isRunning ? "Stop watching" : "Start watching")
    }
}

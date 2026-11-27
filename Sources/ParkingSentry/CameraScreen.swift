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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(Style.dim))
                }
                // The row is mostly empty space between the dot and the
                // chevron, and none of it was tappable — only the glyphs and
                // the text themselves were, so opening the detail meant hitting
                // a letter.
                .frame(minHeight: 32)
                .contentShape(Rectangle())
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
        // Which camera is being read comes before what is being read from it:
        // layers behaving oddly on a 480-pixel peer feed is confusing until you
        // know that is what you are looking at.
        if let source = engine.feedDescription {
            return engine.isArmed ? "Watching \(source)" : source
        }
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
            readout("movement", String(format: "%.3f", engine.motionScore))
            readout("shadows ignored", String(format: "%.0f%%", engine.shadowRejectFraction * 100))
            readout("checks a second", String(format: "%.0f", engine.visionHz))
            readout("sound", String(format: "%.0f dB", engine.soundLevelDB))
            readout("distance from", engine.rangeSourceLabel)
            readout("zoom", String(format: "%.1f×", engine.zoom))
            readout("camera", engine.usingFrontCamera ? "front" : "back")
            readout("power", power.summary)
            if !registry.activeIDs.isEmpty {
                readout("layer work", String(format: "%.0f ms a frame", registry.activeCostMS))
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

        // One row, not two. This was a row of active layers stacked on a second
        // row of seven group shortcuts — fourteen chips of furniture on top of
        // the camera, both scrolling sideways with their ends hidden. The groups
        // belong in the panel, which already filters by them; what belongs out
        // here is what is running and the way in.
        ScrollView(.horizontal, showsIndicators: false) {
            SentryGlassGroup(spacing: 7) {
                HStack(spacing: 7) {
                    SentryChip(title: active.isEmpty ? "Choose layers" : "Layers",
                               value: active.isEmpty ? nil : "\(active.count)",
                               icon: "square.stack.3d.up",
                               tone: active.isEmpty ? .warn : .neutral) {
                        openPanel(nil)
                    }

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
        // Tall enough to hold a 44pt touch target rather than clipping it.
        .frame(height: Style.touch + 6)
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
    let onSource: () -> Void

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
                    .contentShape(Circle())
            }
            .accessibilityLabel("Draw on the feed")

            SentryToolButton(icon: settings.glassMode ? "car.fill" : "car",
                             label: "Tinted glass mode",
                             tone: settings.glassMode ? .alert : .neutral) {
                engine.setGlassMode(!settings.glassMode)
            }

            // Which camera the layers run on. Tinted while reading anything
            // other than this device's own camera, because that is a state the
            // operator must never have to guess at.
            SentryToolButton(icon: engine.feedDescription == nil
                             ? "video" : "video.fill",
                             label: "Video source",
                             tone: engine.feedDescription == nil ? .neutral : .alert,
                             action: onSource)

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
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(engine.isRunning ? "Stop watching" : "Start watching")
    }
}

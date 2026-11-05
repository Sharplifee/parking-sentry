import SwiftUI

/// The window outline drawn over the live preview, plus the drag surface for
/// redrawing it. Inert unless the operator is editing, so pinch-to-zoom and
/// double-tap-to-flip keep working while watching.
struct GlassRegionOverlay: View {
    @EnvironmentObject var engine: DetectionEngine
    @EnvironmentObject var settings: Settings
    /// True while the operator is dragging out a new window.
    @Binding var editing: Bool

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let live = dragRect ?? boxRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                // Everything outside the window dimmed, so the eye goes where
                // the measurement is actually happening.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(live)
                }
                .fill(.black.opacity(editing ? 0.35 : 0.5), style: FillStyle(eoFill: true))

                Rectangle()
                    .strokeBorder(borderColor, lineWidth: 2)
                    .frame(width: max(0, live.width), height: max(0, live.height))
                    .offset(x: live.minX, y: live.minY)

                if editing {
                    Text("drag across the window")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: live.minX, y: max(0, live.minY - 24))
                }
            }
            .contentShape(Rectangle())
            .allowsHitTesting(editing)
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        if start == nil { start = v.startLocation }
                        current = v.location
                    }
                    .onEnded { v in
                        let s = start ?? v.startLocation
                        let r = CGRect(x: min(s.x, v.location.x),
                                       y: min(s.y, v.location.y),
                                       width: abs(v.location.x - s.x),
                                       height: abs(v.location.y - s.y))
                        start = nil
                        current = nil
                        guard r.width > 24, r.height > 24 else { return }
                        commit(r, in: geo.size)
                        editing = false
                    }
            )
        }
        .ignoresSafeArea()
    }

    private var borderColor: Color {
        if editing { return .yellow }
        return engine.glassOccupied ? .red : .cyan
    }

    private var dragRect: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    /// Stored region → screen. Through the preview layer when it is up, so the
    /// outline lands on the same pixels the analyzer reads; a plain
    /// proportional fallback before then, which is only ever briefly visible.
    private func boxRect(in size: CGSize) -> CGRect {
        let r = settings.glassRegion
        if let mapped = engine.layerRect(fromVisionRect: r), mapped.width > 1 {
            return mapped
        }
        return CGRect(x: r.minX * size.width,
                      y: (1 - r.maxY) * size.height,
                      width: r.width * size.width,
                      height: r.height * size.height)
    }

    private func commit(_ screen: CGRect, in size: CGSize) {
        if let v = engine.visionRect(fromLayerRect: screen), v.width > 0.01 {
            engine.setGlassRegion(v)
            return
        }
        engine.setGlassRegion(CGRect(x: screen.minX / size.width,
                                     y: 1 - screen.maxY / size.height,
                                     width: screen.width / size.width,
                                     height: screen.height / size.height))
    }
}

/// The readout: the verdict, the recovered picture of the window, and the three
/// numbers that say whether the measurement is trustworthy.
struct GlassPanel: View {
    @EnvironmentObject var engine: DetectionEngine
    @EnvironmentObject var settings: Settings
    @Binding var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.glassOccupied ? Color.red : Color.cyan)
                    .frame(width: 9, height: 9)
                Text(engine.glassVerdict)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
            }

            if let img = engine.glassImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.18), lineWidth: 1))
            }

            // The activity meter is the live reading; the verdict only moves
            // once the meter has been up for several seconds.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule()
                        .fill(engine.glassGlare ? Color.orange : Color.cyan)
                        .frame(width: max(2, g.size.width * CGFloat(engine.glassActivity)))
                    Capsule()
                        .fill(.white.opacity(0.5))
                        .frame(width: 2)
                        .offset(x: g.size.width * CGFloat(settings.glassOccupiedThreshold))
                }
            }
            .frame(height: 6)

            HStack(spacing: 12) {
                num("act", String(format: "%.2f", engine.glassActivity))
                num("held", String(format: "%.0f%%", engine.glassSustained * 100))
                num("light", String(format: "%.0f%%", engine.glassExposure * 100))
                num("detail", String(format: "%.0f%%", engine.glassContrast * 100))
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    editing = true
                } label: {
                    Label("Draw window", systemImage: "viewfinder.rectangular")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)

                Button {
                    engine.setGlassRegion(settings.glassRegion)
                } label: {
                    Label("Reset baseline", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button {
                    engine.setGlassMode(false)
                } label: {
                    Text("Exit").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
            .tint(.white)
        }
        .padding(11)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }

    private func num(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Text(value).foregroundStyle(.white.opacity(0.9))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }
}

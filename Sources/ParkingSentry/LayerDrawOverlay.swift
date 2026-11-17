import SwiftUI

/// Drawing zones, counting lines and redaction boxes directly on the feed.
///
/// All three go through one overlay because they are the same gesture with a
/// different destination, and because only one can sensibly be active at a time.
enum DrawMode: String, Identifiable {
    case zone, line, redaction
    var id: String { rawValue }

    var prompt: String {
        switch self {
        case .zone:      return "Drag a box over the area to watch"
        case .line:      return "Drag across the line people will cross"
        case .redaction: return "Drag a box over anything that must never be recorded"
        }
    }

    var tint: Color {
        switch self {
        case .zone:      return .cyan
        case .line:      return .yellow
        case .redaction: return .red
        }
    }
}

struct LayerDrawOverlay: View {
    @EnvironmentObject var engine: DetectionEngine
    @EnvironmentObject var settings: Settings
    @ObservedObject var geometry = LayerGeometry.shared
    @Binding var mode: DrawMode?

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)

                // What already exists, so a second zone is not drawn on top of the
                // first by accident.
                ForEach(geometry.zones) { zone in
                    let r = screenRect(zone.rect, geo.size)
                    Rectangle().strokeBorder(.cyan.opacity(0.6), lineWidth: 1.5)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                ForEach(settings.redactionRegions.indices, id: \.self) { i in
                    let r = screenRect(settings.redactionRegions[i], geo.size)
                    Rectangle().fill(.red.opacity(0.35))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }

                if let live = dragRect {
                    if mode == .line, let s = start, let c = current {
                        Path { p in p.move(to: s); p.addLine(to: c) }
                            .stroke(DrawMode.line.tint, lineWidth: 3)
                    } else {
                        Rectangle()
                            .strokeBorder(mode?.tint ?? .white, lineWidth: 2)
                            .frame(width: live.width, height: live.height)
                            .offset(x: live.minX, y: live.minY)
                    }
                }

                VStack {
                    Text(mode?.prompt ?? "")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Done") { mode = nil }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 44)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        if start == nil { start = v.startLocation }
                        current = v.location
                    }
                    .onEnded { v in
                        let s = start ?? v.startLocation
                        defer { start = nil; current = nil }
                        commit(from: s, to: v.location, in: geo.size)
                    }
            )
        }
        .ignoresSafeArea()
    }

    private var dragRect: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    /// Screen point to normalized bottom-left, through the preview layer so the
    /// shape lands on the pixels the layers actually read.
    private func normalized(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        if let video = engine.layerRect(fromVisionRect: CGRect(x: 0, y: 0, width: 1, height: 1)),
           video.width > 1, video.height > 1 {
            return CGPoint(x: (p.x - video.minX) / video.width,
                           y: 1 - (p.y - video.minY) / video.height)
        }
        return CGPoint(x: p.x / size.width, y: 1 - p.y / size.height)
    }

    private func screenRect(_ r: CGRect, _ size: CGSize) -> CGRect {
        if let mapped = engine.layerRect(fromVisionRect: r), mapped.width > 1 { return mapped }
        return CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height,
                      width: r.width * size.width, height: r.height * size.height)
    }

    private func commit(from a: CGPoint, to b: CGPoint, in size: CGSize) {
        let na = normalized(a, size), nb = normalized(b, size)
        switch mode {
        case .line:
            guard hypot(b.x - a.x, b.y - a.y) > 30 else { return }
            geometry.addLine(from: na, to: nb)
            geometry.refreshCaches()
        case .zone:
            let rect = rectBetween(na, nb)
            guard rect.width > 0.04, rect.height > 0.04 else { return }
            geometry.addZone(rect)
            geometry.refreshCaches()
        case .redaction:
            let rect = rectBetween(na, nb)
            guard rect.width > 0.02, rect.height > 0.02 else { return }
            settings.redactionRegions.append(rect)
            EventLog.action("layer.redaction.add", ["count": settings.redactionRegions.count])
        case .none:
            break
        }
        mode = nil
    }

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: max(0, min(a.x, b.x)), y: max(0, min(a.y, b.y)),
               width: min(1, abs(b.x - a.x)), height: min(1, abs(b.y - a.y)))
    }
}

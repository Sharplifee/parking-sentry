import SwiftUI
import CoreGraphics

/// One renderer for every layer.
///
/// Each layer emits normalized, bottom-left coordinates and nothing else, so adding a
/// layer never involves touching drawing code and a new layer's overlay is correctly
/// placed the first time. The mapping is taken from the preview layer itself — the
/// unit rect converted through it gives the on-screen video rect, which accounts for
/// aspect-fill cropping and rotation in one step.
///
/// Three things here are about legibility rather than correctness, and they are what
/// make a dozen simultaneous layers readable instead of a mess:
///
///   ORDER      Layers paint in a fixed order from the registry. Iterating the
///              outputs dictionary meant hash order, which changes between
///              iterations, so the overlay used to shimmer as boxes swapped depth.
///   LABELS     Labels are laid out with collision avoidance after all the geometry
///              is drawn. Six layers each tagging the same person used to stack six
///              plates on the same pixel.
///   RESTRAINT  A label plate is dark and translucent with a thin tinted edge, not a
///              saturated block. Colour identifies the layer; it does not have to
///              shout to do that.
struct LayerOverlayView: View {
    @EnvironmentObject var engine: DetectionEngine
    @ObservedObject var registry = LayerRegistry.shared

    /// Above this many labels the overlay stops being information and starts being
    /// texture, so the lowest-priority ones are dropped and the count is shown.
    private let labelBudget = 14

    var body: some View {
        GeometryReader { geo in
            let video = videoRect(in: geo.size)
            Canvas { ctx, _ in
                var pending: [PendingLabel] = []

                for (id, output) in ordered() {
                    let style = LayerStyle(id: id, registry: registry)
                    for shape in output.shapes {
                        draw(shape, layer: id, style: style,
                             in: &ctx, video: video, labels: &pending)
                    }
                }

                place(pending, in: &ctx, video: video)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// Active outputs in the registry's fixed paint order.
    private func ordered() -> [(String, LayerOutput)] {
        registry.outputs
            .filter { registry.isActive($0.key) }
            .sorted { a, b in
                let oa = registry.drawOrder[a.key] ?? Int.max
                let ob = registry.drawOrder[b.key] ?? Int.max
                return oa == ob ? a.key < b.key : oa < ob
            }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Geometry mapping

    /// The on-screen rectangle the video actually occupies. Falls back to the whole
    /// view before the preview layer exists.
    private func videoRect(in size: CGSize) -> CGRect {
        if let r = engine.layerRect(fromVisionRect: CGRect(x: 0, y: 0, width: 1, height: 1)),
           r.width > 1, r.height > 1 {
            return r
        }
        return CGRect(origin: .zero, size: size)
    }

    private func point(_ p: CGPoint, _ video: CGRect) -> CGPoint {
        CGPoint(x: video.minX + p.x * video.width,
                y: video.minY + (1 - p.y) * video.height)
    }

    private func rect(_ r: CGRect, _ video: CGRect) -> CGRect {
        let s = r.standardized
        return CGRect(x: video.minX + s.minX * video.width,
                      y: video.minY + (1 - s.maxY) * video.height,
                      width: s.width * video.width,
                      height: s.height * video.height)
    }

    // MARK: - Shapes

    private struct PendingLabel {
        let text: String
        /// Where the label wants to sit — normally the top-left of its box.
        let anchor: CGPoint
        /// The geometry it belongs to, so a displaced label can be kept adjacent.
        let owner: CGRect
        let tint: LayerTint
        let priority: Int
        let centred: Bool
    }

    private func draw(_ shape: LayerShape, layer: String, style: LayerStyle,
                      in ctx: inout GraphicsContext, video: CGRect,
                      labels: inout [PendingLabel]) {
        switch shape {
        case .box(let r, let label, let tint):
            let screen = rect(r, video)
            guard screen.width > 1, screen.height > 1 else { return }
            ctx.stroke(Path(roundedRect: screen, cornerRadius: 4),
                       with: .color(color(tint).opacity(0.95)),
                       style: style.stroke)
            if let label, !label.isEmpty {
                labels.append(PendingLabel(text: label,
                                           anchor: CGPoint(x: screen.minX, y: screen.minY),
                                           owner: screen, tint: tint,
                                           priority: style.priority, centred: false))
            }

        case .quad(let pts, let label, let tint):
            guard pts.count >= 3 else { return }
            var path = Path()
            path.move(to: point(pts[0], video))
            for p in pts.dropFirst() { path.addLine(to: point(p, video)) }
            path.closeSubpath()
            ctx.stroke(path, with: .color(color(tint).opacity(0.95)), style: style.stroke)
            if let label, !label.isEmpty {
                let bounds = path.boundingRect
                labels.append(PendingLabel(text: label,
                                           anchor: CGPoint(x: bounds.minX, y: bounds.minY),
                                           owner: bounds, tint: tint,
                                           priority: style.priority, centred: false))
            }

        case .points(let pts, let tint):
            let c = color(tint)
            for p in pts {
                let s = point(p, video)
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 1.75, y: s.y - 1.75,
                                                width: 3.5, height: 3.5)),
                         with: .color(c))
            }

        case .polyline(let pts, let tint):
            guard pts.count >= 2 else { return }
            var path = Path()
            path.move(to: point(pts[0], video))
            for p in pts.dropFirst() { path.addLine(to: point(p, video)) }
            ctx.stroke(path, with: .color(color(tint).opacity(0.9)), style: style.stroke)

        case .bones(let pairs, let tint):
            let c = color(tint)
            var path = Path()
            for (a, b) in pairs {
                path.move(to: point(a, video))
                path.addLine(to: point(b, video))
            }
            ctx.stroke(path, with: .color(c.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            // Joints are drawn once per unique position rather than twice per bone,
            // which previously stacked two fills on every shared joint and made the
            // skeleton look blobbed at the shoulders.
            var seen = Set<CGPoint>()
            for (a, b) in pairs {
                for j in [a, b] where seen.insert(j).inserted {
                    let s = point(j, video)
                    ctx.fill(Path(ellipseIn: CGRect(x: s.x - 2, y: s.y - 2,
                                                    width: 4, height: 4)),
                             with: .color(c))
                }
            }

        case .grid(let values, let cols, let rows, let tint):
            guard cols > 0, rows > 0, values.count == cols * rows else { return }
            let cw = video.width / CGFloat(cols)
            let ch = video.height / CGFloat(rows)
            let base = color(tint)
            for gy in 0..<rows {
                for gx in 0..<cols {
                    let v = values[gy * cols + gx]
                    guard v > 0.06 else { continue }
                    // Bottom-left grid origin to top-left screen.
                    let cell = CGRect(x: video.minX + CGFloat(gx) * cw,
                                      y: video.minY + CGFloat(rows - 1 - gy) * ch,
                                      width: cw + 0.5, height: ch + 0.5)
                    ctx.fill(Path(cell), with: .color(base.opacity(min(0.5, v * 0.5))))
                }
            }

        case .label(let text, let at, let tint):
            let p = point(at, video)
            labels.append(PendingLabel(text: text, anchor: p,
                                       owner: CGRect(origin: p, size: .zero),
                                       tint: tint, priority: style.priority,
                                       centred: true))
        }
    }

    // MARK: - Labels

    /// Lays every label out so none overlaps another, then draws them.
    ///
    /// Candidates are tried in order of how little they move the label from where
    /// it belongs: directly above its box, then below it, then inside its top edge,
    /// then beside it. A label with nowhere to go is dropped rather than stacked,
    /// because an unreadable pile of plates is worse than one missing caption — the
    /// box it belongs to is still drawn either way.
    private func place(_ labels: [PendingLabel], in ctx: inout GraphicsContext,
                       video: CGRect) {
        guard !labels.isEmpty else { return }

        let ranked = labels.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            // Larger things first: a caption on a big box matters more than one on
            // a speck, and placing it first gives it the spot it wants.
            return a.owner.height > b.owner.height
        }

        var taken: [CGRect] = []
        var drawn = 0
        var dropped = 0

        for label in ranked {
            guard drawn < labelBudget else { dropped += 1; continue }
            let resolved = resolve(label.text, in: &ctx)
            let size = resolved.measure(in: CGSize(width: 220, height: 40))
            let plate = CGSize(width: size.width + 10, height: size.height + 5)

            guard let origin = slot(for: label, plate: plate, taken: taken, video: video) else {
                dropped += 1
                continue
            }
            let frame = CGRect(origin: origin, size: plate)
            taken.append(frame.insetBy(dx: -2, dy: -1))
            drawn += 1

            ctx.fill(Path(roundedRect: frame, cornerRadius: 4),
                     with: .color(.black.opacity(0.62)))
            // A thin tinted edge rather than a tinted fill: the layer is still
            // identifiable at a glance and the text stays legible over anything.
            ctx.fill(Path(roundedRect: CGRect(x: frame.minX, y: frame.minY,
                                              width: 2, height: frame.height),
                          cornerRadius: 1),
                     with: .color(color(label.tint)))
            ctx.draw(resolved,
                     at: CGPoint(x: frame.minX + 7, y: frame.midY),
                     anchor: .leading)
        }

        if dropped > 0 {
            let note = resolve("+\(dropped) more", in: &ctx)
            let size = note.measure(in: CGSize(width: 140, height: 24))
            let frame = CGRect(x: video.minX + 8,
                               y: video.maxY - size.height - 14,
                               width: size.width + 10, height: size.height + 5)
            ctx.fill(Path(roundedRect: frame, cornerRadius: 4),
                     with: .color(.black.opacity(0.5)))
            ctx.draw(note, at: CGPoint(x: frame.minX + 5, y: frame.midY), anchor: .leading)
        }
    }

    private func resolve(_ text: String, in ctx: inout GraphicsContext) -> GraphicsContext.ResolvedText {
        // Regular weight, not semibold. At this size the plate behind it supplies
        // all the contrast that is needed, and heavy type over a camera feed reads
        // as clutter long before it reads as emphasis.
        var resolved = ctx.resolve(Text(text)
            .font(.system(size: 11, weight: .regular))
            .monospacedDigit())
        resolved.shading = .color(.white.opacity(0.95))
        return resolved
    }

    /// First free position for this label, or nil if every candidate collides.
    private func slot(for label: PendingLabel, plate: CGSize,
                      taken: [CGRect], video: CGRect) -> CGPoint? {
        let box = label.owner
        let gap: CGFloat = 3

        var candidates: [CGPoint] = []
        if label.centred {
            candidates = [
                CGPoint(x: label.anchor.x - plate.width / 2, y: label.anchor.y - plate.height / 2),
                CGPoint(x: label.anchor.x - plate.width / 2, y: label.anchor.y + gap),
                CGPoint(x: label.anchor.x - plate.width / 2, y: label.anchor.y - plate.height - gap)
            ]
        } else {
            candidates = [
                CGPoint(x: box.minX, y: box.minY - plate.height - gap),  // above
                CGPoint(x: box.minX, y: box.maxY + gap),                 // below
                CGPoint(x: box.minX + gap, y: box.minY + gap),           // inside top
                CGPoint(x: box.maxX + gap, y: box.minY),                 // right
                CGPoint(x: box.minX - plate.width - gap, y: box.minY),   // left
                CGPoint(x: box.minX + gap, y: box.maxY - plate.height - gap) // inside bottom
            ]
        }

        for var c in candidates {
            // Keep it on screen before testing collisions, or a clamped candidate
            // lands somewhere already measured as free.
            c.x = min(max(c.x, video.minX + 2), video.maxX - plate.width - 2)
            c.y = min(max(c.y, video.minY + 2), video.maxY - plate.height - 2)
            let frame = CGRect(origin: c, size: plate)
            if !taken.contains(where: { $0.intersects(frame) }) { return c }
        }
        return nil
    }

    // MARK: - Per-layer identity

    /// Stroke weight and dash, so two layers outlining the same person stay
    /// distinguishable when they share a tint or when the feed is monochrome at
    /// night. Colour alone is not enough to carry this.
    private struct LayerStyle {
        let stroke: StrokeStyle
        let priority: Int

        init(id: String, registry: LayerRegistry) {
            let group = registry.layer(id)?.group ?? .vision
            switch group {
            case .analytics:
                stroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [7, 4])
                priority = 4            // a zone breach outranks a caption
            case .sensors:
                stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 3])
                priority = 1
            case .privacy:
                stroke = StrokeStyle(lineWidth: 2.0, lineCap: .round)
                priority = 5            // a redaction must always be visibly marked
            case .multimodal, .language:
                stroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [12, 3])
                priority = 3
            default:
                stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                priority = 2
            }
        }
    }

    private func color(_ tint: LayerTint) -> Color {
        switch tint {
        case .primary:  return .cyan
        case .person:   return .green
        case .vehicle:  return .blue
        case .animal:   return .mint
        case .text:     return .yellow
        case .face:     return .pink
        case .hand:     return .purple
        case .flow:     return .teal
        case .heat:     return .orange
        case .warn:     return .orange
        case .alert:    return .red
        case .mask:     return .indigo
        case .neutral:  return .white
        }
    }
}

/// Replaces the live camera preview whenever a layer is producing a composited
/// image — which today means a privacy layer. Drawing a blurred frame *over*
/// AVCaptureVideoPreviewLayer would leave the raw feed underneath, visible on any
/// dropped frame, which is not a redaction. So the raw preview is taken off screen
/// entirely and these frames are shown instead.
struct RenderedPreview: View {
    @EnvironmentObject var engine: DetectionEngine

    var body: some View {
        ZStack {
            Color.black
            // A privacy composite always wins: if one exists, showing the
            // unredacted outside frame instead would defeat it.
            if let frame = engine.composedFrame ?? engine.externalFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .ignoresSafeArea()
    }
}

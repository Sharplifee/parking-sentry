import SwiftUI
import CoreGraphics

/// One renderer for every layer.
///
/// Each layer emits normalized, bottom-left coordinates and nothing else, so adding a
/// layer never involves touching drawing code and a new layer's overlay is correctly
/// placed the first time. The mapping is taken from the preview layer itself — the
/// unit rect converted through it gives the on-screen video rect, which accounts for
/// aspect-fill cropping and rotation in one step.
struct LayerOverlayView: View {
    @EnvironmentObject var engine: DetectionEngine
    @ObservedObject var registry = LayerRegistry.shared

    var body: some View {
        GeometryReader { geo in
            let video = videoRect(in: geo.size)
            Canvas { ctx, _ in
                for (id, output) in registry.outputs {
                    guard registry.isActive(id) else { continue }
                    for shape in output.shapes {
                        draw(shape, in: &ctx, video: video)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

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
        CGRect(x: video.minX + r.minX * video.width,
               y: video.minY + (1 - r.maxY) * video.height,
               width: r.width * video.width,
               height: r.height * video.height)
    }

    private func draw(_ shape: LayerShape, in ctx: inout GraphicsContext, video: CGRect) {
        switch shape {
        case .box(let r, let label, let tint):
            let screen = rect(r, video)
            ctx.stroke(Path(roundedRect: screen, cornerRadius: 3),
                       with: .color(color(tint)), lineWidth: 1.5)
            if let label { drawLabel(label, at: CGPoint(x: screen.minX, y: screen.minY - 7),
                                     tint: tint, in: &ctx) }

        case .quad(let pts, let label, let tint):
            guard pts.count >= 3 else { return }
            var path = Path()
            path.move(to: point(pts[0], video))
            for p in pts.dropFirst() { path.addLine(to: point(p, video)) }
            path.closeSubpath()
            ctx.stroke(path, with: .color(color(tint)), lineWidth: 1.5)
            if let label, let first = pts.first {
                let a = point(first, video)
                drawLabel(label, at: CGPoint(x: a.x, y: a.y - 7), tint: tint, in: &ctx)
            }

        case .points(let pts, let tint):
            for p in pts {
                let s = point(p, video)
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 2, y: s.y - 2, width: 4, height: 4)),
                         with: .color(color(tint)))
            }

        case .polyline(let pts, let tint):
            guard pts.count >= 2 else { return }
            var path = Path()
            path.move(to: point(pts[0], video))
            for p in pts.dropFirst() { path.addLine(to: point(p, video)) }
            ctx.stroke(path, with: .color(color(tint)), lineWidth: 2)

        case .bones(let pairs, let tint):
            var path = Path()
            for (a, b) in pairs {
                path.move(to: point(a, video))
                path.addLine(to: point(b, video))
            }
            ctx.stroke(path, with: .color(color(tint)), lineWidth: 2)
            for (a, b) in pairs {
                for j in [a, b] {
                    let s = point(j, video)
                    ctx.fill(Path(ellipseIn: CGRect(x: s.x - 2.5, y: s.y - 2.5,
                                                    width: 5, height: 5)),
                             with: .color(color(tint)))
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
                    guard v > 0.04 else { continue }
                    // Bottom-left grid origin to top-left screen.
                    let cell = CGRect(x: video.minX + CGFloat(gx) * cw,
                                      y: video.minY + CGFloat(rows - 1 - gy) * ch,
                                      width: cw + 0.5, height: ch + 0.5)
                    ctx.fill(Path(cell), with: .color(base.opacity(min(0.72, v * 0.72))))
                }
            }

        case .label(let text, let at, let tint):
            drawLabel(text, at: point(at, video), tint: tint, in: &ctx, centred: true)
        }
    }

    private func drawLabel(_ text: String, at p: CGPoint, tint: LayerTint,
                           in ctx: inout GraphicsContext, centred: Bool = false) {
        var resolved = ctx.resolve(Text(text).font(.system(size: 10, weight: .semibold)))
        resolved.shading = .color(.white)
        let size = resolved.measure(in: CGSize(width: 240, height: 40))
        let origin = centred ? CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
                             : CGPoint(x: p.x, y: p.y - size.height)
        let plate = CGRect(origin: CGPoint(x: origin.x - 3, y: origin.y - 1),
                           size: CGSize(width: size.width + 6, height: size.height + 2))
        ctx.fill(Path(roundedRect: plate, cornerRadius: 3),
                 with: .color(color(tint).opacity(0.85)))
        ctx.draw(resolved, at: origin, anchor: .topLeading)
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
            if let frame = engine.composedFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .ignoresSafeArea()
    }
}

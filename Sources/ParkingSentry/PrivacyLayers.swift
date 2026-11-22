import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import CoreVideo
import Vision

/// Privacy layers. These are the only layers that alter the image the operator sees
/// rather than drawing on top of it, because a redaction that can be peeked under is
/// not a redaction.
///
/// Worth being exact about what this does and does not do: it blurs the live
/// preview and anything the preview feeds, and when "apply to recordings" is on it
/// also blurs frames before they reach the clip writer and the peer stream, so a
/// redacted face never leaves the device. It does not retroactively redact clips
/// already on disk.

final class PrivacyBlurLayer: VideoAILayer {
    let id = "privacy.blur"
    let title = "Face & body blur"
    let detail = "Blurs detected faces, or whole people, in the preview and anything it feeds."
    let group = LayerGroup.privacy
    let modality = LayerModality.video
    let availability = LayerAvailability.available
    let preferredInterval = 1

    enum Target: String, CaseIterable { case faces, people, both }
    /// Read from settings each frame so flipping it takes effect immediately.
    var target: Target {
        Target(rawValue: Settings.shared.privacyBlurTarget) ?? .faces
    }

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Last known boxes, so a face that Vision drops for one frame does not flash
    /// unblurred. A redaction that flickers is a redaction that failed.
    private var sticky: [(rect: CGRect, until: Date)] = []

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var regions: [CGRect] = []

        if target != .people {
            // The frame's shared face detection, not a second handler over the same
            // pixels — this ran a whole extra image preparation and face pass every
            // frame, at interval 1, which made the privacy layer roughly twice as
            // expensive as it needed to be.
            for obs in try ctx.shared.faceRects() {
                // Pad generously: a tight face box leaves hairline, ears and jaw
                // visible, which is plenty to recognise someone by.
                regions.append(pad(obs.boundingBox, by: 0.35))
            }
        }
        if target != .faces {
            for subject in ctx.subjects where subject.category == .person {
                regions.append(pad(subject.boundingBox, by: 0.06))
            }
        }

        let now = Date()
        sticky.removeAll { $0.until < now }
        // Refresh an existing patch rather than appending a near-identical one.
        // Appending every frame put about thirty overlapping rectangles in the list
        // at 30 fps, and because they were then unioned the blur patch crept outward
        // for as long as anyone stood still — while the badge counted the list
        // rather than the faces.
        for r in regions {
            if let i = sticky.firstIndex(where: { $0.rect.intersects(r) }) {
                sticky[i] = (sticky[i].rect.union(r), now.addingTimeInterval(0.5))
            } else {
                sticky.append((r, now.addingTimeInterval(0.5)))
            }
        }
        let merged = mergeOverlapping(sticky.map(\.rect))

        var out = LayerOutput()
        out.badge = merged.isEmpty ? nil : "\(merged.count)"
        guard !merged.isEmpty else { return out }

        out.image = redact(ctx.pixelBuffer, regions: merged)
        // Drawn as well, so it is obvious the blur is deliberate and not a glitch.
        out.shapes = merged.map { .box($0, label: nil, tint: .mask) }
        return out
    }

    /// Clipped to the frame rather than clamped per-edge: widening a box near the
    /// right edge used to keep its origin and extend past 1.0, so the region the
    /// renderer drew and the region actually pixelated disagreed.
    private func pad(_ r: CGRect, by f: CGFloat) -> CGRect {
        let dx = r.width * f, dy = r.height * f
        return r.insetBy(dx: -dx, dy: -dy)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Overlapping blur patches produce visible seams where their edges cross, so
    /// they are merged into single regions first.
    ///
    /// Repeated until nothing merges: one pass leaves A∪B overlapping a C that was
    /// already placed, so two faces close together could still be emitted as
    /// overlapping patches with the seam this is meant to remove.
    private func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
        var result = rects
        var merged = true
        while merged {
            merged = false
            var next: [CGRect] = []
            for r in result {
                if let i = next.firstIndex(where: { $0.intersects(r) }) {
                    next[i] = next[i].union(r)
                    merged = true
                } else {
                    next.append(r)
                }
            }
            result = next
        }
        return result
    }

    /// Pixelate rather than Gaussian-blur: a strong enough mosaic cannot be undone
    /// by sharpening, and a light Gaussian often can.
    ///
    /// One filter pass for the whole frame, composited through the regions, rather
    /// than one pass per region. Pixellate renders over the entire input whatever
    /// you crop afterwards, so three faces meant three full-resolution filter
    /// passes every frame at interval 1 — the single most expensive thing the app
    /// could be asked to do, and it scaled with the number of people in view.
    private func redact(_ buffer: CVPixelBuffer, regions: [CGRect]) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let pixelRegions = regions.compactMap { r -> CGRect? in
            let p = CGRect(x: r.minX * extent.width, y: r.minY * extent.height,
                           width: r.width * extent.width, height: r.height * extent.height)
            return (p.width > 4 && p.height > 4) ? p : nil
        }
        guard !pixelRegions.isEmpty else { return nil }

        // Mosaic cell sized from the smallest region, so the smallest face is still
        // unrecognisable rather than merely softened.
        let smallest = pixelRegions.map { min($0.width, $0.height) }.min() ?? 40
        let mosaic = CIFilter.pixellate()
        mosaic.inputImage = source.clampedToExtent()
        mosaic.center = CGPoint(x: extent.midX, y: extent.midY)
        mosaic.scale = Float(max(8, smallest / 6))
        guard let blurred = mosaic.outputImage else { return nil }

        var composed = source
        for p in pixelRegions {
            composed = blurred.cropped(to: p).composited(over: composed)
        }
        return ciContext.createCGImage(composed, from: extent)
    }
}

/// A fixed rectangle the operator draws, blanked out entirely — for a neighbour's
/// window or a doorway that should never be recorded. Unlike face blur this needs no
/// detection to be correct, which makes it the one redaction that cannot fail.
final class RegionRedactionLayer: VideoAILayer {
    let id = "privacy.redact"
    let title = "Region redaction"
    let detail = "Blanks out fixed areas you draw, with no detection involved."
    let group = LayerGroup.privacy
    let modality = LayerModality.video
    var availability: LayerAvailability {
        Settings.shared.redactionRegions.isEmpty
            ? .needsSetup("Draw a region to blank out")
            : .available
    }
    let preferredInterval = 1

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        let regions = Settings.shared.redactionRegions
        guard !regions.isEmpty else { return nil }

        let source = CIImage(cvPixelBuffer: ctx.pixelBuffer)
        let extent = source.extent
        var composed = source
        for r in regions {
            let pixel = CGRect(x: r.minX * extent.width, y: r.minY * extent.height,
                               width: r.width * extent.width, height: r.height * extent.height)
            guard pixel.width > 2, pixel.height > 2 else { continue }
            let black = CIImage(color: .black).cropped(to: pixel)
            composed = black.composited(over: composed)
        }

        var out = LayerOutput()
        out.image = ciContext.createCGImage(composed, from: extent)
        out.badge = "\(regions.count)"
        return out
    }
}

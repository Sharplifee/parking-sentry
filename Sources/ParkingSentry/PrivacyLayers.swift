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

    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Last known boxes, so a face that Vision drops for one frame does not flash
    /// unblurred. A redaction that flickers is a redaction that failed.
    private var sticky: [(rect: CGRect, until: Date)] = []

    func process(_ ctx: FrameContext) throws -> LayerOutput? {
        var regions: [CGRect] = []

        if target != .people {
            let handler = VNImageRequestHandler(cvPixelBuffer: ctx.pixelBuffer,
                                                orientation: ctx.orientation,
                                                options: [:])
            try handler.perform([faceRequest])
            for obs in faceRequest.results ?? [] {
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
        for r in regions { sticky.append((r, now.addingTimeInterval(0.5))) }
        let merged = mergeOverlapping(sticky.map(\.rect))

        var out = LayerOutput()
        out.badge = merged.isEmpty ? nil : "\(merged.count)"
        guard !merged.isEmpty else { return out }

        out.image = redact(ctx.pixelBuffer, regions: merged)
        // Drawn as well, so it is obvious the blur is deliberate and not a glitch.
        out.shapes = merged.map { .box($0, label: nil, tint: .mask) }
        return out
    }

    private func pad(_ r: CGRect, by f: CGFloat) -> CGRect {
        let dx = r.width * f, dy = r.height * f
        return CGRect(x: max(0, r.minX - dx), y: max(0, r.minY - dy),
                      width: min(1, r.width + dx * 2),
                      height: min(1, r.height + dy * 2))
    }

    /// Overlapping blur patches produce visible seams where their edges cross, so
    /// they are merged into single regions first.
    private func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for r in rects {
            if let i = result.firstIndex(where: { $0.intersects(r) }) {
                result[i] = result[i].union(r)
            } else {
                result.append(r)
            }
        }
        return result
    }

    /// Pixelate rather than Gaussian-blur: a strong enough mosaic cannot be undone
    /// by sharpening, and a light Gaussian often can.
    private func redact(_ buffer: CVPixelBuffer, regions: [CGRect]) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let extent = source.extent
        var composed = source

        for r in regions {
            let pixel = CGRect(x: r.minX * extent.width,
                               y: r.minY * extent.height,
                               width: r.width * extent.width,
                               height: r.height * extent.height)
            guard pixel.width > 4, pixel.height > 4 else { continue }

            let mosaic = CIFilter.pixellate()
            mosaic.inputImage = source.clampedToExtent()
            mosaic.center = CGPoint(x: pixel.midX, y: pixel.midY)
            mosaic.scale = Float(max(8, min(pixel.width, pixel.height) / 6))
            guard let blurred = mosaic.outputImage?.cropped(to: pixel) else { continue }
            composed = blurred.composited(over: composed)
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

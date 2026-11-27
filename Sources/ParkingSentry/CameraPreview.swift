import SwiftUI
import AVFoundation
import UIKit

/// Live preview with detection boxes drawn in the preview layer's own coordinate space,
/// so the boxes stay glued to the subject regardless of aspect-fill cropping or rotation.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let overlays: [BoxOverlay]
    /// Whether this preview is the one on the device's own screen.
    ///
    /// The engine keeps a reference to *the* preview layer and converts every
    /// normalized rect through it — detection boxes, the layer overlay, drawn
    /// zones, the tinted-glass region. There is a second preview on the external
    /// display wall, and because it ran the same setup it overwrote that
    /// reference with the external screen's layer. From the moment a display or
    /// AirPlay receiver attached, every overlay on the phone was being mapped
    /// through a geometry belonging to a different screen, and the rotation
    /// coordinator was rebuilt against it too. The big screen never needs to own
    /// that reference, so it says so.
    var isPrimary: Bool = true

    func makeUIView(context: Context) -> PreviewContainer {
        let v = PreviewContainer()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        // Hand the layer to the engine so the rotation coordinator can drive it;
        // without this the preview never rotates and the overlay maths is wrong
        // on any device not held in the default orientation.
        if isPrimary { DetectionEngine.shared?.previewLayer = v.previewLayer }
        return v
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        uiView.apply(overlays)
    }
}

final class PreviewContainer: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let overlayView = OverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        addSubview(overlayView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlayView.frame = bounds
    }

    func apply(_ overlays: [BoxOverlay]) {
        overlayView.convert = { [weak self] visionRect in
            guard let self else { return .zero }
            // Vision: bottom-left origin. Metadata rect: top-left origin.
            let meta = CGRect(x: visionRect.minX,
                              y: 1 - visionRect.maxY,
                              width: visionRect.width,
                              height: visionRect.height)
            return self.previewLayer.layerRectConverted(fromMetadataOutputRect: meta)
        }
        overlayView.boxes = overlays
        overlayView.setNeedsDisplay()
    }
}

final class OverlayView: UIView {
    var boxes: [BoxOverlay] = []
    var convert: ((CGRect) -> CGRect)?

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let convert else { return }
        ctx.setLineWidth(2)

        for b in boxes {
            let r = convert(b.rect)
            guard r.width > 1, r.height > 1 else { continue }

            var color: UIColor
            switch b.category {
            case .person:  color = .systemRed
            case .vehicle: color = .systemOrange
            case .animal:  color = .systemTeal
            case .object:  color = .systemPurple
            case .unknown: color = .systemGray
            }
            if !b.confirmed { color = color.withAlphaComponent(0.55) }
            ctx.setStrokeColor(color.cgColor)
            ctx.stroke(r)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.black
            ]
            // The caption used to be pinned to the box's left edge with nothing
            // stopping it, so anything detected near the right of the frame had
            // its name run off the screen — the most common place to see a
            // detection is the edge, which is exactly where the label was
            // unreadable. It is now shortened to what will fit and then slid
            // back inside the view.
            var text = b.label as NSString
            var size = text.size(withAttributes: attrs)
            let widest = bounds.width - 12
            if size.width > widest {
                var shortened = b.label
                while !shortened.isEmpty,
                      ((shortened + "…") as NSString).size(withAttributes: attrs).width > widest {
                    shortened.removeLast()
                }
                text = (shortened + "…") as NSString
                size = text.size(withAttributes: attrs)
            }
            let width = size.width + 10
            let labelRect = CGRect(x: min(max(0, r.minX), bounds.width - width),
                                   y: max(0, r.minY - size.height - 6),
                                   width: width,
                                   height: size.height + 4)
            ctx.setFillColor(color.withAlphaComponent(0.9).cgColor)
            ctx.fill(labelRect)
            text.draw(at: CGPoint(x: labelRect.minX + 5, y: labelRect.minY + 2), withAttributes: attrs)
        }
    }
}

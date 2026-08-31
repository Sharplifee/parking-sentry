import SwiftUI
import AVFoundation
import UIKit

/// Live preview with detection boxes drawn in the preview layer's own coordinate space,
/// so the boxes stay glued to the subject regardless of aspect-fill cropping or rotation.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let overlays: [BoxOverlay]

    func makeUIView(context: Context) -> PreviewContainer {
        let v = PreviewContainer()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
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
        ctx.setLineWidth(3)

        for b in boxes {
            let r = convert(b.rect)
            guard r.width > 1, r.height > 1 else { continue }

            let color: UIColor = b.isAnimal ? .systemTeal : (b.confirmed ? .systemRed : .systemYellow)
            ctx.setStrokeColor(color.cgColor)
            ctx.stroke(r)

            let text = b.label as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            let size = text.size(withAttributes: attrs)
            let labelRect = CGRect(x: r.minX,
                                   y: max(0, r.minY - size.height - 6),
                                   width: size.width + 10,
                                   height: size.height + 4)
            ctx.setFillColor(color.withAlphaComponent(0.9).cgColor)
            ctx.fill(labelRect)
            text.draw(at: CGPoint(x: labelRect.minX + 5, y: labelRect.minY + 2), withAttributes: attrs)
        }
    }
}

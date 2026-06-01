import AppKit

/// Displays the composited beautify preview, aspect-fit on a neutral backdrop.
@MainActor
final class BeautifyView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        bounds.fill()
        guard let image, let cg = NSGraphicsContext.current?.cgContext else { return }
        let area = bounds.insetBy(dx: 20, dy: 20)
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(area.width / imageSize.width, area.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let rect = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                          width: size.width, height: size.height)
        cg.draw(image, in: rect)
    }
}

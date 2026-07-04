import AppKit

/// A small, self-contained view hosting the magnifier loupe + color readout. Kept deliberately
/// tiny so its layer backing store stays in the low megabytes — drawing the loupe from the
/// full-screen overlay view would force a screen-sized backing bitmap (~60 MB per Retina 5K
/// display) just to show a 135 pt circle.
@MainActor
final class LoupeView: NSView {
    /// Covers the farthest the loupe + readout can land from the anchor (offset gap + diameter +
    /// readout box + shadow blur), so MagnifierLoupe's own edge-flip logic always draws inside.
    private static let halfSide: CGFloat = 220

    private let image: CGImage
    private var anchor: CGPoint = .zero        // cursor, in the overlay view's coordinates
    private var pixelPoint: CGPoint = .zero
    private var overlayBounds: CGRect = .zero

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: Self.halfSide * 2, height: Self.halfSide * 2))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Mouse events must fall through to the overlay view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(anchor: CGPoint, pixelPoint: CGPoint, overlayBounds: CGRect) {
        self.anchor = anchor
        self.pixelPoint = pixelPoint
        self.overlayBounds = overlayBounds
        setFrameOrigin(CGPoint(x: anchor.x - Self.halfSide, y: anchor.y - Self.halfSide))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Translate the overlay's coordinates into this view's local space, then let MagnifierLoupe
        // run its normal positioning/clamping against the (translated) overlay bounds.
        let local = CGPoint(x: Self.halfSide, y: Self.halfSide)
        let localBounds = CGRect(
            x: overlayBounds.minX - frame.minX,
            y: overlayBounds.minY - frame.minY,
            width: overlayBounds.width,
            height: overlayBounds.height
        )
        MagnifierLoupe.draw(at: local, image: image, pixelPoint: pixelPoint, viewBounds: localBounds)
    }
}

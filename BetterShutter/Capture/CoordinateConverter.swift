import CoreGraphics

/// The single source of truth for coordinate math between the three spaces this app touches:
///
/// 1. **AppKit global points** — origin bottom-left of the primary screen, y up.
///    `NSScreen.frame`, `NSEvent.mouseLocation`, overlay selection rects live here.
/// 2. **CoreGraphics global points** — origin top-left of the primary screen, y down.
///    `CGDisplayBounds`, `SCDisplay.frame`, `SCWindow.frame` live here.
/// 3. **Image pixels** — a captured display bitmap, top-left origin, device pixels.
///
/// All math is centralized here (and unit-tested) so the points↔pixels and y-flip never
/// gets re-derived inline and silently wrong on a Retina or negative-origin secondary display.
nonisolated enum CoordinateConverter {

    // MARK: AppKit global point → image pixels (top-left)

    /// Map a point in AppKit global coordinates to top-left-origin pixel coordinates within
    /// the frozen bitmap of the display whose AppKit frame is `displayFrame` and whose
    /// captured size is `pixelSize`.
    static func pixelPoint(
        globalPoint p: CGPoint,
        displayFrame f: CGRect,
        pixelSize: CGSize
    ) -> CGPoint {
        let sx = pixelSize.width / f.width
        let sy = pixelSize.height / f.height
        let localX = (p.x - f.minX) * sx
        let localYFromTop = (f.maxY - p.y) * sy
        return CGPoint(x: localX, y: localYFromTop)
    }

    /// Map a rect in AppKit global coordinates to an **integer** pixel crop rect in the
    /// display bitmap's top-left coordinate space, clamped to the bitmap bounds.
    static func pixelCropRect(
        globalRect r: CGRect,
        displayFrame f: CGRect,
        pixelSize: CGSize
    ) -> CGRect {
        let sx = pixelSize.width / f.width
        let sy = pixelSize.height / f.height
        let x = (r.minX - f.minX) * sx
        let yFromTop = (f.maxY - r.maxY) * sy   // r.maxY is the selection's TOP edge in AppKit
        let raw = CGRect(x: x, y: yFromTop, width: r.width * sx, height: r.height * sy)
        return clamp(raw.integral, to: pixelSize)
    }

    // MARK: CoreGraphics global ↔ AppKit global (rects)

    /// Convert a rect in CoreGraphics global coordinates (top-left origin) to AppKit global
    /// coordinates (bottom-left origin). `primaryHeight` is the height in points of the
    /// primary screen (the one whose AppKit frame origin is `.zero`).
    static func appKitRect(fromCGGlobalRect r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Inverse of `appKitRect(fromCGGlobalRect:primaryHeight:)`.
    static func cgGlobalRect(fromAppKitRect r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Helpers

    /// Clamp a pixel rect so it never exceeds the bitmap bounds (a crop rect outside the
    /// image makes `CGImage.cropping(to:)` return nil).
    static func clamp(_ r: CGRect, to pixelSize: CGSize) -> CGRect {
        let minX = max(0, min(r.minX, pixelSize.width))
        let minY = max(0, min(r.minY, pixelSize.height))
        let maxX = max(0, min(r.maxX, pixelSize.width))
        let maxY = max(0, min(r.maxY, pixelSize.height))
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

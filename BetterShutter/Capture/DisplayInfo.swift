import CoreGraphics

/// A `Sendable` snapshot of a display, derived from `SCDisplay` + CoreGraphics.
/// Frames are in **points**, CoreGraphics global coordinates (top-left origin, y down).
nonisolated struct DisplayInfo: Sendable, Identifiable {
    let id: CGDirectDisplayID
    /// Bounds in points, CG global coordinates (top-left origin).
    let cgFrame: CGRect
    /// Pixels per point for this display.
    let scale: CGFloat

    var pixelSize: CGSize {
        CGSize(width: cgFrame.width * scale, height: cgFrame.height * scale)
    }
}

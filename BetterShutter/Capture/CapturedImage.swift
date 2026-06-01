import CoreGraphics

/// An immutable captured bitmap that can safely cross actor boundaries.
///
/// `CGImage` is not `Sendable` in Swift 6, but a `CGImage` is immutable once created,
/// so wrapping it as `@unchecked Sendable` is sound. Never mutate `cgImage` after init.
nonisolated struct CapturedImage: @unchecked Sendable {
    /// The bitmap, top-left origin, in device pixels.
    let cgImage: CGImage
    /// Size in device pixels (`cgImage.width` × `cgImage.height`).
    let pixelSize: CGSize
    /// Backing scale the capture was taken at (pixels per point).
    let scale: CGFloat
    /// The display this came from, when known (full-display / region). `nil` for window captures.
    let displayID: CGDirectDisplayID?

    init(cgImage: CGImage, scale: CGFloat, displayID: CGDirectDisplayID?) {
        self.cgImage = cgImage
        self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        self.scale = scale
        self.displayID = displayID
    }
}

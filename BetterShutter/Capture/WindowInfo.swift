import CoreGraphics

/// A `Sendable` snapshot of an on-screen window, derived from `SCWindow`.
/// `cgFrame` is in **points**, CoreGraphics global coordinates (top-left origin, y down).
nonisolated struct WindowInfo: Sendable, Identifiable {
    let id: CGWindowID
    let cgFrame: CGRect
    let title: String?
    let appName: String?
    /// Area in square points; used to pick the top-most/most-relevant window under the cursor.
    var area: CGFloat { cgFrame.width * cgFrame.height }
}

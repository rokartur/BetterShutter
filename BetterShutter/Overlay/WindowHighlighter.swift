import CoreGraphics

/// Maps capturable windows (CoreGraphics global coords) into a single overlay's **view
/// coordinates** and hit-tests the front-most window under the cursor — all from the cached
/// frame list, no live queries.
nonisolated struct WindowHighlighter {
    struct Hit {
        let id: CGWindowID
        /// Rect in the overlay view's coordinates (bottom-left origin, points).
        let rect: CGRect
    }

    /// Convert each window's CG global frame to this screen's view coordinates, preserving the
    /// front-to-back order of the source list.
    static func viewRects(
        windows: [WindowInfo],
        primaryHeight: CGFloat,
        screenGlobalFrame: CGRect
    ) -> [Hit] {
        windows.compactMap { w in
            let appKit = CoordinateConverter.appKitRect(fromCGGlobalRect: w.cgFrame, primaryHeight: primaryHeight)
            guard appKit.intersects(screenGlobalFrame) else { return nil }
            let local = CGRect(
                x: appKit.minX - screenGlobalFrame.minX,
                y: appKit.minY - screenGlobalFrame.minY,
                width: appKit.width,
                height: appKit.height
            )
            return Hit(id: w.id, rect: local)
        }
    }

    /// Front-most window containing the point (source list is front-to-back).
    static func window(at point: CGPoint, in hits: [Hit]) -> Hit? {
        hits.first { $0.rect.contains(point) }
    }
}

import CoreGraphics

/// Holds the in-progress / committed selection rectangle in **view coordinates** (bottom-left
/// origin, points) and provides keyboard-driven nudge / resize / move, clamped to the view bounds.
nonisolated struct SelectionModel {
    /// The committed selection (nil until the user drags one out).
    var rect: CGRect?

    /// Build a normalized rect from a drag anchor to the current point.
    static func rect(from anchor: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    mutating func nudge(dx: CGFloat, dy: CGFloat, in bounds: CGRect) {
        guard var r = rect else { return }
        r.origin.x += dx
        r.origin.y += dy
        rect = clampOrigin(r, in: bounds)
    }

    mutating func resize(dw: CGFloat, dh: CGFloat, in bounds: CGRect) {
        guard var r = rect else { return }
        r.size.width = max(1, r.size.width + dw)
        r.size.height = max(1, r.size.height + dh)
        rect = clampSize(r, in: bounds)
    }

    private func clampOrigin(_ r: CGRect, in bounds: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(bounds.minX, r.origin.x), bounds.maxX - r.width)
        r.origin.y = min(max(bounds.minY, r.origin.y), bounds.maxY - r.height)
        return r
    }

    private func clampSize(_ r: CGRect, in bounds: CGRect) -> CGRect {
        var r = r
        r.size.width = min(r.size.width, bounds.maxX - r.minX)
        r.size.height = min(r.size.height, bounds.maxY - r.minY)
        return r
    }
}

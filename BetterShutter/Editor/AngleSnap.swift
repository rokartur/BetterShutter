import CoreGraphics
import Foundation

/// Constrains a dragged segment to the nearest fixed angle (default 45°) while preserving its
/// length — used for Shift-drag on directional tools (line / arrow / measure).
nonisolated enum AngleSnap {
    static func snap(start: CGPoint, end: CGPoint, stepDegrees: CGFloat = 45) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = stepDegrees * .pi / 180
        let snappedAngle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(snappedAngle) * length,
                       y: start.y + sin(snappedAngle) * length)
    }
}

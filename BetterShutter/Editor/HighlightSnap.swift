import CoreGraphics

/// Snaps a freehand highlight to OCR-detected text lines (Snapzy's "smart highlighter"). All rects
/// are in image-pixel space, bottom-left origin — the editor's convention.
nonisolated enum HighlightSnap {

    /// Returns a rect that tightly covers the text lines the drawn rect overlaps, clamped
    /// horizontally to the drawn rect so a partial drag highlights only the portion swept. Each line
    /// must overlap the drawn rect vertically by at least `minVerticalOverlap` of its height to count.
    /// Returns `nil` when the drag covers no text (caller keeps the freehand rect).
    static func snap(drawn: CGRect, lines: [CGRect], minVerticalOverlap: CGFloat = 0.3) -> CGRect? {
        var result: CGRect?
        for line in lines {
            guard line.height > 0 else { continue }
            let overlapY = min(drawn.maxY, line.maxY) - max(drawn.minY, line.minY)
            guard overlapY > line.height * minVerticalOverlap else { continue }
            let x0 = max(line.minX, drawn.minX)
            let x1 = min(line.maxX, drawn.maxX)
            guard x1 > x0 else { continue }
            let piece = CGRect(x: x0, y: line.minY, width: x1 - x0, height: line.height)
            result = result?.union(piece) ?? piece
        }
        return result
    }
}

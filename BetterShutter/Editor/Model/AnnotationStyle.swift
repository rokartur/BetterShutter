import AppKit

/// Visual style shared by annotation elements. Stroke width and font size are in **image pixels**
/// so annotations stay proportional to the captured bitmap regardless of editor zoom.
nonisolated enum FillMode: String, Sendable { case stroke, strokeFill, fill }
nonisolated enum DashStyle: String, Sendable { case solid, dashed, dotted }

@MainActor
struct AnnotationStyle {
    var color: NSColor
    var strokeWidth: CGFloat
    var fontSize: CGFloat
    var fillMode: FillMode
    var dash: DashStyle

    /// Dash pattern for the current style (empty = solid line).
    var dashPattern: [CGFloat] {
        switch dash {
        case .solid: return []
        case .dashed: return [strokeWidth * 3, strokeWidth * 2]
        case .dotted: return [strokeWidth * 0.1, strokeWidth * 2]
        }
    }

    static func makeDefault(imageWidth: CGFloat) -> AnnotationStyle {
        // Scale defaults to the image so strokes/text read well on both small and 5K captures.
        let stroke = max(3, (imageWidth / 350).rounded())
        return AnnotationStyle(
            color: .systemRed,
            strokeWidth: stroke,
            fontSize: max(18, (imageWidth / 45).rounded()),
            fillMode: .stroke,
            dash: .solid
        )
    }
}

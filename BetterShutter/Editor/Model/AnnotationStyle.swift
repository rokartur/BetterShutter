import AppKit

/// Visual style shared by annotation elements. Stroke width and font size are in **image pixels**
/// so annotations stay proportional to the captured bitmap regardless of editor zoom.
@MainActor
struct AnnotationStyle {
    var color: NSColor
    var strokeWidth: CGFloat
    var fontSize: CGFloat
    var filled: Bool

    static func makeDefault(imageWidth: CGFloat) -> AnnotationStyle {
        // Scale defaults to the image so strokes/text read well on both small and 5K captures.
        let stroke = max(3, (imageWidth / 350).rounded())
        return AnnotationStyle(
            color: .systemRed,
            strokeWidth: stroke,
            fontSize: max(18, (imageWidth / 45).rounded()),
            filled: false
        )
    }
}

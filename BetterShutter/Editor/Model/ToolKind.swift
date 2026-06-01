import Foundation

/// The annotation tools available in the editor.
nonisolated enum ToolKind: String, CaseIterable, Sendable {
    case select
    case arrow
    case rectangle
    case ellipse
    case line
    case text
    case highlighter
    case pixelate
    case step
    case crop

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .pixelate: return "mosaic"
        case .step: return "1.circle.fill"
        case .crop: return "crop"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .text: return "Text"
        case .highlighter: return "Highlight"
        case .pixelate: return "Pixelate"
        case .step: return "Step"
        case .crop: return "Crop"
        }
    }

    /// Tools that draw by dragging from a start point to an end point.
    var isDragCreated: Bool {
        switch self {
        case .arrow, .rectangle, .ellipse, .line, .highlighter, .pixelate: return true
        case .select, .text, .step, .crop: return false
        }
    }
}

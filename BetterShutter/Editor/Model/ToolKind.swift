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
    case blur
    case blackout
    case spotlight
    case eyedropper
    case stamp
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
        case .blur: return "drop.fill"
        case .blackout: return "rectangle.fill"
        case .spotlight: return "rays"
        case .eyedropper: return "eyedropper"
        case .stamp: return "face.smiling"
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
        case .blur: return "Blur"
        case .blackout: return "Black Out"
        case .spotlight: return "Spotlight"
        case .eyedropper: return "Color Picker"
        case .stamp: return "Stamp"
        case .step: return "Step"
        case .crop: return "Crop"
        }
    }

    /// Single-key editor shortcut (no modifiers). Lowercase; matched against typed characters.
    var shortcutKey: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .text: return "t"
        case .highlighter: return "h"
        case .pixelate: return "p"
        case .blur: return "b"
        case .blackout: return "k"
        case .spotlight: return "s"
        case .eyedropper: return "i"
        case .stamp: return "g"
        case .step: return "n"
        case .crop: return "c"
        }
    }

    /// The active key for this tool (user override from Preferences, else the default).
    var effectiveShortcutKey: Character { Preferences.editorToolKey(for: self) }

    static func forShortcut(_ character: Character) -> ToolKind? {
        allCases.first { $0.effectiveShortcutKey == character }
    }

    /// Tools that draw by dragging from a start point to an end point.
    var isDragCreated: Bool {
        switch self {
        case .arrow, .rectangle, .ellipse, .line, .highlighter, .pixelate, .blur, .blackout, .spotlight:
            return true
        case .select, .text, .step, .crop, .eyedropper, .stamp:
            return false
        }
    }
}

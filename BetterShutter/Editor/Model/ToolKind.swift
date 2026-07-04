import Foundation
import BetterShortcuts

/// The annotation tools available in the editor.
nonisolated enum ToolKind: String, CaseIterable, Sendable {
    case select
    case arrow
    case rectangle
    case ellipse
    case line
    case pen
    case marker
    case measure
    case loupe
    case text
    case highlighter
    case pixelate
    case blur
    case blackout
    case erase
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
        case .pen: return "scribble.variable"
        case .marker: return "paintbrush.pointed.fill"
        case .measure: return "ruler"
        case .loupe: return "plus.magnifyingglass"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .pixelate: return "mosaic"
        case .blur: return "drop.fill"
        case .blackout: return "rectangle.fill"
        case .erase: return "eraser"
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
        case .pen: return "Pen"
        case .marker: return "Marker"
        case .measure: return "Measure"
        case .loupe: return "Loupe"
        case .text: return "Text"
        case .highlighter: return "Highlight"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .blackout: return "Black Out"
        case .erase: return "Erase"
        case .spotlight: return "Spotlight"
        case .eyedropper: return "Color Picker"
        case .stamp: return "Stamp"
        case .step: return "Step"
        case .crop: return "Crop"
        }
    }

    /// Default single-key editor shortcut (no modifiers).
    private var defaultShortcutKey: BetterShortcuts.Key {
        switch self {
        case .select: return .v
        case .arrow: return .a
        case .rectangle: return .r
        case .ellipse: return .o
        case .line: return .l
        case .pen: return .d
        case .marker: return .e
        case .measure: return .m
        case .loupe: return .z
        case .text: return .t
        case .highlighter: return .h
        case .pixelate: return .p
        case .blur: return .b
        case .blackout: return .k
        case .erase: return .x
        case .spotlight: return .s
        case .eyedropper: return .i
        case .stamp: return .g
        case .step: return .n
        case .crop: return .c
        }
    }

    /// BetterShortcuts name backing this tool's editor shortcut. Never registered as a global
    /// hotkey (no `onKeyDown`) — the editor canvas matches it against key events while focused.
    var shortcutName: BetterShortcuts.Name { Self.shortcutNames[self]! }

    private static let shortcutNames: [ToolKind: BetterShortcuts.Name] = Dictionary(
        uniqueKeysWithValues: allCases.map {
            ($0, BetterShortcuts.Name("editorTool_\($0.rawValue)", default: .init($0.defaultShortcutKey)))
        }
    )

    /// The active shortcut for this tool (user's recorded combo, else the default).
    var effectiveShortcut: BetterShortcuts.Shortcut? { shortcutName.shortcut }

    static func forShortcut(_ shortcut: BetterShortcuts.Shortcut) -> ToolKind? {
        allCases.first { $0.effectiveShortcut == shortcut }
    }

    /// Tools that draw by dragging from a start point to an end point.
    var isDragCreated: Bool {
        switch self {
        case .arrow, .rectangle, .ellipse, .line, .pen, .marker, .measure, .loupe, .highlighter, .pixelate, .blur, .blackout, .erase, .spotlight:
            return true
        case .select, .text, .step, .crop, .eyedropper, .stamp:
            return false
        }
    }
}

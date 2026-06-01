import Foundation

/// The user-invoked capture mode (one per hotkey / menu item).
///
/// - `region`: freeze the screen, let the user drag a selection rectangle.
/// - `window`: freeze the screen, highlight the window under the cursor, click to capture it.
/// - `fullDisplay`: capture the whole display under the cursor immediately (no overlay).
nonisolated enum CaptureMode: String, Sendable, CaseIterable {
    case region
    case window
    case fullDisplay

    var presentableName: String {
        switch self {
        case .region: return "Capture Region"
        case .window: return "Capture Window"
        case .fullDisplay: return "Capture Full Screen"
        }
    }

    /// Short suffix used by the filename template `{mode}` token.
    var fileTag: String {
        switch self {
        case .region: return "Region"
        case .window: return "Window"
        case .fullDisplay: return "Screen"
        }
    }
}

import Foundation

/// In-memory ring buffer of the most recent captures, surfaced in the menu's "Recent" submenu so
/// a capture is never lost if its float preview is dismissed.
@MainActor
final class CaptureHistory {
    static let shared = CaptureHistory()

    struct Item: Identifiable {
        let id = UUID()
        let image: CapturedImage
        let mode: CaptureMode
        let date: Date
    }

    private(set) var items: [Item] = []
    let limit = 10

    func add(_ image: CapturedImage, mode: CaptureMode, date: Date = Date()) {
        items.insert(Item(image: image, mode: mode, date: date), at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
    }

    func clear() { items.removeAll() }
}

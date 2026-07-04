import Foundation

/// The most recent capture, kept in memory so "Pin/Reopen/Upload Last" act instantly even after
/// the float preview is dismissed. Older captures live only in the on-disk history archive
/// (`CaptureHistoryStore`) — holding more full-resolution bitmaps here just burns RAM
/// (a Retina 5K frame is ~60 MB, so a 10-deep ring cost up to ~600 MB).
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
    let limit = 1

    func add(_ image: CapturedImage, mode: CaptureMode, date: Date = Date()) {
        items.insert(Item(image: image, mode: mode, date: date), at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        // Persist to the on-disk history archive (off the main thread — it encodes + writes PNG).
        Task.detached(priority: .utility) { CaptureHistoryStore.add(image.cgImage, mode: mode, date: date) }
    }

    func clear() { items.removeAll() }
}

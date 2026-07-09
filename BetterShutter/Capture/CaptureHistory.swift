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
    private var archiveTail: Task<Void, Never>?
    private var archiveGeneration: UInt64 = 0
    private(set) var pendingArchiveCount = 0
    /// Capture admission uses this as backpressure. Two 5K images can already represent roughly
    /// 120 MiB of source pixels; never allow an unbounded chain of closures retaining more.
    var isArchiveBackpressured: Bool { pendingArchiveCount >= 2 }

    func add(_ image: CapturedImage, mode: CaptureMode, date: Date = Date()) {
        remember(image, mode: mode, date: date)
        enqueueArchive(image, mode: mode, date: date)
    }

    /// Update the single in-memory "last capture" slot. Callers that already need PNG bytes use
    /// this and archive those same bytes through CaptureHistoryStore instead of encoding twice.
    func remember(_ image: CapturedImage, mode: CaptureMode, date: Date = Date()) {
        items.insert(Item(image: image, mode: mode, date: date), at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
    }

    private func enqueueArchive(_ image: CapturedImage, mode: CaptureMode, date: Date) {
        // Persist off-main, but chain jobs before detaching the next expensive PNG encode. A burst
        // is admission-limited by `isArchiveBackpressured`, while this chain keeps the accepted
        // encodes strictly one-at-a-time.
        let previous = archiveTail
        archiveGeneration &+= 1
        let generation = archiveGeneration
        pendingArchiveCount += 1
        archiveTail = Task.detached(priority: .utility) { [weak self] in
            if let previous { await previous.value }
            if let png = await ImageEncoder.encodeAsync(image.cgImage, as: .png) {
                CaptureHistoryStore.add(png: png, mode: mode, date: date)
            }
            await self?.archiveFinished(generation: generation)
        }
    }

    private func archiveFinished(generation: UInt64) {
        pendingArchiveCount = max(0, pendingArchiveCount - 1)
        if archiveGeneration == generation { archiveTail = nil }
    }

    func clear() { items.removeAll() }
}

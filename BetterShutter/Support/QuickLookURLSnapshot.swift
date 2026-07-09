import Foundation

/// Quick Look is an Objective-C API and may ask its data source for items from a context Swift
/// cannot prove is the main actor. Keep the small URL snapshot behind a lock instead of using
/// `nonisolated(unsafe)` mutable arrays in UI objects.
nonisolated final class QuickLookURLSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func replace(with urls: [URL]) {
        lock.withLock { self.urls = urls }
    }

    var count: Int {
        lock.withLock { urls.count }
    }

    func url(at index: Int) -> URL? {
        lock.withLock { urls.indices.contains(index) ? urls[index] : nil }
    }
}

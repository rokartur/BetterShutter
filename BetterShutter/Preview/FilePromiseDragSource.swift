import AppKit

/// Vends a real PNG file when the float preview is dragged into Finder / Slack / Mail, written
/// lazily off the main thread. Methods are `nonisolated` because `writePromise` is invoked on a
/// background operation queue; the delegate only holds immutable `Sendable` data.
nonisolated final class ImageFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let pngData: Data
    private let filename: String
    private let writeQueue = OperationQueue()

    init(pngData: Data, filename: String) {
        self.pngData = pngData
        self.filename = filename
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String {
        filename
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try pngData.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { writeQueue }
}

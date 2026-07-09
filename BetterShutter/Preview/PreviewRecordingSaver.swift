import Foundation
import Darwin

/// Atomically allocates and copies a recording into the user's save directory. Recording cards can
/// be requested concurrently, and `FileSaver.uniqueURL` by itself is only a check; a cancellable
/// single-flight permit plus exclusive rename closes the gap without replacing another file.
nonisolated enum PreviewRecordingSaver {
    private final class CopyPermit: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false

        func tryAcquire() -> Bool {
            lock.withLock {
                guard !busy else { return false }
                busy = true
                return true
            }
        }

        func release() { lock.withLock { busy = false } }
    }

    private static let permit = CopyPermit()

    @concurrent
    static func copy(_ source: URL, to directory: URL) async throws -> URL {
        while !permit.tryAcquire() {
            try await Task.sleep(for: .milliseconds(25))
        }
        defer { permit.release() }
        return try copySerially(source, to: directory)
    }

    private static func copySerially(_ source: URL, to directory: URL) throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".BetterShutter-copy-\(UUID().uuidString).partial",
            isDirectory: false
        )

        // Write a hidden same-volume temp file in bounded chunks. Unlike FileManager.copyItem,
        // every chunk observes Task cancellation, so dismissing a card stops a multi-GB copy
        // promptly instead of finishing it in the background and deleting it afterward.
        let input = try FileHandle(forReadingFrom: source)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            try? input.close()
            throw currentPOSIXError()
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var temporaryExists = true
        defer {
            try? input.close()
            try? output.close()
            if temporaryExists { try? fileManager.removeItem(at: temporary) }
        }

        let chunkSize = 4 * 1_024 * 1_024
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try Task.checkCancellation()
        try output.synchronize()
        try output.close()
        try input.close()

        // Publish the completed file atomically and without overwriting. `RENAME_EXCL` closes the
        // cross-process gap between uniqueURL's existence check and the rename; if another process
        // wins a candidate, reuse the already-copied temp file and try the next suffix.
        let filename = source.lastPathComponent
        while true {
            try Task.checkCancellation()
            let destination = FileSaver.uniqueURL(in: directory, filename: filename)
            if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                temporaryExists = false
                return destination
            }
            if errno == EEXIST { continue }
            throw currentPOSIXError()
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

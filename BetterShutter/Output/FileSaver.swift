import CoreGraphics
import Foundation

/// Writes encoded image data to the configured save directory, resolving name collisions.
nonisolated enum FileSaver {
    /// Saving is intentionally callable from detached utility tasks. Serialize the counter/name
    /// allocation and final write so two simultaneous captures cannot receive the same counter and
    /// both race to replace the same path.
    private final class WriteGate: @unchecked Sendable {
        private let lock = NSLock()
        func acquireBlocking() { lock.lock() }
        func tryAcquire() -> Bool { lock.try() }
        func release() { lock.unlock() }
    }
    private static let writeGate = WriteGate()
    private final class AsyncSavePermit: @unchecked Sendable {
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

    private static let asyncSavePermit = AsyncSavePermit()

    /// Encodes and saves a capture, returning the written file URL.
    static func save(_ cgImage: CGImage, mode: CaptureMode) throws -> URL {
        try Task.checkCancellation()
        let format = Preferences.format
        guard let data = ImageEncoder.encode(cgImage, as: format, quality: Preferences.jpegQuality) else {
            try Task.checkCancellation()
            throw CaptureError.emptyCapture
        }
        try Task.checkCancellation()
        return try write(data, format: format, mode: mode)
    }

    /// Background save path: all full-resolution encodes share ImageEncoder's async single-flight
    /// gate, so closing/replacing UI cannot leave overlapping ImageIO finalizers behind.
    @concurrent
    static func saveAsync(_ cgImage: CGImage, mode: CaptureMode) async throws -> URL {
        while !asyncSavePermit.tryAcquire() {
            try await Task.sleep(for: .milliseconds(25))
        }
        defer { asyncSavePermit.release() }
        try Task.checkCancellation()
        let format = Preferences.format
        guard let data = await ImageEncoder.encodeAsync(
            cgImage, as: format, quality: Preferences.jpegQuality) else {
            try Task.checkCancellation()
            throw CaptureError.emptyCapture
        }
        try Task.checkCancellation()
        return try await writeAsync(data, format: format, mode: mode)
    }

    /// Write already-encoded data with the standard directory/naming/collision handling — lets
    /// callers that encoded once (clipboard + upload + save) skip a redundant encode.
    static func write(_ data: Data, format: ImageFileFormat, mode: CaptureMode) throws -> URL {
        try Task.checkCancellation()
        writeGate.acquireBlocking()
        defer { writeGate.release() }
        return try writeUnlocked(data, format: format, mode: mode)
    }

    private static func writeUnlocked(
        _ data: Data, format: ImageFileFormat, mode: CaptureMode
    ) throws -> URL {
        try Task.checkCancellation()

        let directory = Preferences.saveDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = FilenameTemplate.render(
            Preferences.filenameTemplate,
            mode: mode,
            format: format,
            counter: Preferences.nextCaptureCounter()
        )
        var url = uniqueURL(in: directory, filename: filename)
        while true {
            try Task.checkCancellation()
            do {
                // The lock covers other FileSaver calls; withoutOverwriting also closes the
                // check-then-write gap against an external process creating the candidate.
                try data.write(to: url, options: [.atomic, .withoutOverwriting])
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                url = uniqueURL(in: directory, filename: filename)
            }
        }
    }

    @concurrent
    static func writeAsync(_ data: Data, format: ImageFileFormat, mode: CaptureMode) async throws -> URL {
        // A network/external save volume can stall the active writer. Poll cooperatively so
        // cancelled UI saves release their encoded Data instead of parking threads in NSLock.lock.
        while !writeGate.tryAcquire() {
            try await Task.sleep(for: .milliseconds(25))
        }
        defer { writeGate.release() }
        return try writeUnlocked(data, format: format, mode: mode)
    }

    /// Appends " (k)" before the extension if the target already exists.
    static func uniqueURL(in directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }
}

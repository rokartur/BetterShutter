import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The single CGImage → encoded `Data` path, shared by save-to-disk, drag-out, and copy.
nonisolated enum ImageEncoder {
    /// Nonblocking admission for background encoders. Waiters sleep cooperatively and observe task
    /// cancellation, so a cancelled Save does not remain as an actor-mailbox node retaining a 5K
    /// CGImage behind an uninterruptible ImageIO finalize.
    private final class AsyncPermit: @unchecked Sendable {
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

    private static let asyncPermit = AsyncPermit()

    @concurrent
    static func encodeAsync(
        _ cgImage: CGImage, as format: ImageFileFormat, quality: Double = 0.9
    ) async -> Data? {
        while !asyncPermit.tryAcquire() {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return nil
            }
        }
        defer { asyncPermit.release() }
        guard !Task.isCancelled else { return nil }
        return encode(cgImage, as: format, quality: quality)
    }

    static func encode(_ cgImage: CGImage, as format: ImageFileFormat, quality: Double = 0.9) -> Data? {
        guard !Task.isCancelled else { return nil }
        let type: UTType
        switch format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        case .webp: type = .webP
        }
        let data = NSMutableData()
        // WebP encoding requires ImageIO to advertise a writer for it; if the OS can't encode the
        // requested type, destination creation fails and this returns nil. Callers must surface that
        // (e.g. a "Save failed" toast) — there is no automatic format fallback.
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else { return nil }

        var properties: [CFString: Any] = [:]
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        // ImageIO's synchronous finalize call itself is not cancellable, but callers that were
        // dismissed while it ran must not retain or persist the now-unwanted encoded buffer.
        guard !Task.isCancelled else { return nil }
        return data as Data
    }
}

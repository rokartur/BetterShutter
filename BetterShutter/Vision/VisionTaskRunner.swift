import CoreImage
import Vision

/// Bridges synchronous Vision requests to Swift concurrency without blocking the caller's actor.
/// `nonisolated async` functions no longer necessarily hop to a generic executor, so each request
/// is explicitly detached. Cancellation reaches both the Swift task and `VNRequest.cancel()`.
nonisolated enum VisionTaskRunner {
    static func run<Result: Sendable>(
        priority: TaskPriority = .userInitiated,
        default fallback: Result,
        operation: @escaping @Sendable (VisionRequestCancellation) -> Result
    ) async -> Result {
        guard !Task.isCancelled else { return fallback }
        let cancellation = VisionRequestCancellation()
        let work = Task.detached(priority: priority) {
            guard !Task.isCancelled else { return fallback }
            return operation(cancellation)
        }

        return await withTaskCancellationHandler {
            let result = await work.value
            return Task.isCancelled ? fallback : result
        } onCancel: {
            // Mark the state first, covering cancellation before the detached task installs its
            // request; then cancel the Swift task so its between-pass checks also stop promptly.
            cancellation.cancel()
            work.cancel()
        }
    }
}

/// A VNRequest is not Sendable, but `cancel()` is specifically designed to be called while a
/// request is executing. The lock confines the only cross-executor reference and also handles the
/// cancellation-before-install race.
nonisolated final class VisionRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false

    func perform(_ request: VNRequest, with handler: VNImageRequestHandler) throws -> Bool {
        guard !Task.isCancelled, install(request) else { return false }
        defer { finish(request) }
        try handler.perform([request])
        return !Task.isCancelled && !isCancelled
    }

    func cancel() {
        let active: VNRequest? = lock.withLock {
            cancelled = true
            return request
        }
        active?.cancel()
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    private func install(_ request: VNRequest) -> Bool {
        let alreadyCancelled = lock.withLock {
            if cancelled { return true }
            self.request = request
            return false
        }
        if alreadyCancelled { request.cancel() }
        return !alreadyCancelled
    }

    private func finish(_ request: VNRequest) {
        lock.withLock {
            if self.request === request { self.request = nil }
        }
    }
}

/// CIContext is expensive and internally thread-safe. Reusing one context avoids creating a new
/// GPU/Metal cache on every OCR retry or subject cutout; the box documents that shared guarantee.
nonisolated enum VisionCIContext {
    private final class Box: @unchecked Sendable {
        let context = CIContext(options: [.cacheIntermediates: false])
    }

    private static let box = Box()

    static func createCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        box.context.createCGImage(image, from: rect)
    }
}

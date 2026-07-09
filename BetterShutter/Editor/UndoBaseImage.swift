import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Shared holder for an undo snapshot's base bitmap.
///
/// Snapshots taken while the base is unchanged share one box (zero extra RAM, same as sharing the
/// `CGImage` reference directly). Boxes evicted from the editor's recent-set are downgraded to
/// lossless PNG data (~5–15% of the raw bitmap) and re-decoded on demand when an undo reaches
/// them — capping the worst case (30 destructive ops on a 5K capture) at a few hundred MB instead
/// of ~1.8 GB of pinned bitmaps.
@MainActor
final class UndoBaseImage {

    /// Destructive edits can evict many 5K undo bases in quick succession. Serialize their PNG
    /// encodes so each eviction does not start another full-resolution encoder and multiply peak
    /// CPU/scratch-memory use. Queued jobs retain only their holder weakly, so closing the editor
    /// drops unneeded bitmaps instead of encoding the abandoned undo stack.
    private static var encodeTail: Task<Void, Never>?
    private static var encodeQueueGeneration: UInt64 = 0

    /// Crosses the encode task boundary; a CGImage is immutable, so this is sound.
    private struct ImageBox: @unchecked Sendable { let cg: CGImage }

    private var live: CGImage?
    private var encoded: Data?
    /// Bumped on every promotion; a finished encode only applies if nothing promoted meanwhile,
    /// so a downgrade racing an undo can never drop the bitmap the user just returned to.
    private var generation: UInt64 = 0
    /// Non-nil while a PNG encode for this generation is running. Besides preventing duplicate
    /// encodes, this lets `image` invalidate an encode when undo promotes the box mid-flight.
    private var encodingGeneration: UInt64?
    /// The box was evicted again after an in-flight encode was invalidated by a promotion. Retry with
    /// the current generation when the old encode returns, rather than leaving an old undo bitmap raw.
    private var retryDowngrade = false

    init(_ image: CGImage) { live = image }

    /// True once `downgrade()` finished and the box holds only PNG bytes (test/debug probe).
    var isDowngraded: Bool { live == nil && encoded != nil }
    /// Test/debug probe used to wait for the detached encoder without timing assumptions.
    var isDowngradeInFlight: Bool { encodingGeneration != nil }

    /// The bitmap, re-decoded (and promoted back to live) if it was downgraded to PNG. Returns
    /// the original pixels exactly — PNG is lossless for 8/16-bit RGBA and ImageIO round-trips
    /// the color space.
    var image: CGImage? {
        if let live {
            // `downgrade()` has already captured this image, but the user returned to the undo state
            // before its encode completed. Invalidate that result so it cannot immediately evict the
            // bitmap that was just promoted back into the recent set.
            if encodingGeneration != nil {
                generation &+= 1
                retryDowngrade = false
            }
            return live
        }
        guard let encoded,
              let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        live = decoded
        self.encoded = nil
        generation &+= 1
        return decoded
    }

    /// Compress the live bitmap to PNG off the main thread and drop it once encoded. On encode
    /// failure the bitmap stays live (never lose an undo state to save memory).
    func downgrade() {
        guard live != nil, encoded == nil else { return }
        if let encodingGeneration {
            if encodingGeneration != generation { retryDowngrade = true }
            return
        }
        let expected = generation
        encodingGeneration = expected
        let previous = Self.encodeTail
        Self.encodeQueueGeneration &+= 1
        let queueGeneration = Self.encodeQueueGeneration
        let task = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else {
                Self.finishQueueSlot(queueGeneration)
                return
            }
            // The box may have been promoted while waiting behind another encode. Do not even begin
            // expensive work for stale state; arrange a retry only if it was subsequently evicted.
            guard self.encodingGeneration == expected,
                  self.generation == expected,
                  let image = self.live else {
                if self.encodingGeneration == expected { self.encodingGeneration = nil }
                if self.retryDowngrade {
                    self.retryDowngrade = false
                    self.downgrade()
                }
                Self.finishQueueSlot(queueGeneration)
                return
            }
            let box = ImageBox(cg: image)
            let data = await Task.detached(priority: .utility) {
                Self.encodePNG(box.cg)
            }.value
            if self.encodingGeneration == expected { self.encodingGeneration = nil }
            guard let data, self.generation == expected, self.live != nil else {
                if self.retryDowngrade {
                    self.retryDowngrade = false
                    self.downgrade()
                }
                Self.finishQueueSlot(queueGeneration)
                return
            }
            self.retryDowngrade = false
            self.encoded = data
            self.live = nil
            Self.finishQueueSlot(queueGeneration)
        }
        Self.encodeTail = task
    }

    private static func finishQueueSlot(_ generation: UInt64) {
        if encodeQueueGeneration == generation { encodeTail = nil }
    }

    private nonisolated static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

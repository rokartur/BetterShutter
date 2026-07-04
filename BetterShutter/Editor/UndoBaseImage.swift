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

    /// Crosses the encode task boundary; a CGImage is immutable, so this is sound.
    private struct ImageBox: @unchecked Sendable { let cg: CGImage }

    private var live: CGImage?
    private var encoded: Data?
    /// Bumped on every promotion; a finished encode only applies if nothing promoted meanwhile,
    /// so a downgrade racing an undo can never drop the bitmap the user just returned to.
    private var generation = 0

    init(_ image: CGImage) { live = image }

    /// True once `downgrade()` finished and the box holds only PNG bytes (test/debug probe).
    var isDowngraded: Bool { live == nil && encoded != nil }

    /// The bitmap, re-decoded (and promoted back to live) if it was downgraded to PNG. Returns
    /// the original pixels exactly — PNG is lossless for 8/16-bit RGBA and ImageIO round-trips
    /// the color space.
    var image: CGImage? {
        if let live { return live }
        guard let encoded,
              let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        live = decoded
        self.encoded = nil
        generation += 1
        return decoded
    }

    /// Compress the live bitmap to PNG off the main thread and drop it once encoded. On encode
    /// failure the bitmap stays live (never lose an undo state to save memory).
    func downgrade() {
        guard let image = live, encoded == nil else { return }
        let expected = generation
        let box = ImageBox(cg: image)
        Task {
            let data = await Task.detached(priority: .utility) {
                Self.encodePNG(box.cg)
            }.value
            guard let data, self.generation == expected, self.live != nil else { return }
            self.encoded = data
            self.live = nil
        }
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

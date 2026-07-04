import AppKit

/// Copies a capture to the general pasteboard, offering both PNG and TIFF representations so
/// every destination app (Preview, browsers, chat apps) gets a format it understands.
///
/// The PNG is written eagerly; the TIFF is promised via a data provider and only materialized if
/// a destination actually asks for it. An eager TIFF is uncompressed (~60 MB for a Retina 5K
/// shot) and the pasteboard would pin it until the next copy.
@MainActor
enum PasteboardWriter {
    static func copy(_ cgImage: CGImage) {
        guard let png = ImageEncoder.encode(cgImage, as: .png) else { return }
        copy(png: png)
    }

    /// Write pre-encoded PNG data — callers on hot paths encode once off the main thread and
    /// share the bytes between pasteboard, upload, and save.
    static func copy(png: Data) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setDataProvider(LazyTIFFProvider(png: png), forTypes: [.tiff])

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Holds only the compressed PNG; decodes it to TIFF on demand.
    private nonisolated final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
        private let png: Data

        init(png: Data) { self.png = png }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff,
                  let rep = NSBitmapImageRep(data: png),
                  let tiff = rep.tiffRepresentation else { return }
            item.setData(tiff, forType: type)
        }
    }
}

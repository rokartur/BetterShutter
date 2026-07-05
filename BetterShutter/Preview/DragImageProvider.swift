import AppKit
import UniformTypeIdentifiers

/// Backs a float-preview drag with BOTH a file URL and the raw image bytes, so every drop target
/// gets the representation it prefers: Finder / file-upload inputs take the file, while image wells
/// and rich-text editors embed the actual PNG instead of pasting the file *path* as text (the bug
/// where "sometimes a path shows up instead of the image"). The receiver picks the type — offering
/// all three just means we never leave a capable target with only a path to fall back on.
///
/// `nonisolated` because AppKit reads these methods off the main actor during the drag; the object
/// only holds immutable `Sendable` data.
nonisolated final class DragImageProvider: NSObject, NSPasteboardWriting {
    private let url: URL
    private let pngData: Data

    init(url: URL, pngData: Data) {
        self.url = url
        self.pngData = pngData
    }

    // Image types FIRST: naive readers that just take the first representation then embed the actual
    // picture; file-oriented targets (Finder, uploads) still find `.fileURL` further down the list.
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.png, .tiff, .fileURL]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL:
            return (url as NSURL).pasteboardPropertyList(forType: .fileURL)
        case .png:
            return pngData
        case .tiff:
            return NSBitmapImageRep(data: pngData)?.representation(using: .tiff, properties: [:])
        default:
            return nil
        }
    }
}

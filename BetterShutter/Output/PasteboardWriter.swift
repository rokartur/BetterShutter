import AppKit

/// Copies a capture to the general pasteboard, offering both PNG and TIFF representations so
/// every destination app (Preview, browsers, chat apps) gets a format it understands.
@MainActor
enum PasteboardWriter {
    static func copy(_ cgImage: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let image = NSImage(cgImage: cgImage, size: .zero)
        pasteboard.writeObjects([image])

        if let png = ImageEncoder.encode(cgImage, as: .png) {
            pasteboard.setData(png, forType: .png)
        }
    }
}

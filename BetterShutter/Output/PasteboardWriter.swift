import AppKit

/// Copies a capture to the general pasteboard, offering both PNG and TIFF representations so
/// every destination app (Preview, browsers, chat apps) gets a format it understands.
@MainActor
enum PasteboardWriter {
    static func copy(_ cgImage: CGImage) {
        let pasteboard = NSPasteboard.general

        // Build both reps up front. Declaring the types first (then setData) is the reliable order —
        // mixing writeObjects + a later setData can silently drop the second type.
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: cgImage.width, height: cgImage.height)
        let tiff = rep.tiffRepresentation
        let png = rep.representation(using: .png, properties: [:]) ?? ImageEncoder.encode(cgImage, as: .png)

        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png { pasteboard.setData(png, forType: .png) }
        if let tiff { pasteboard.setData(tiff, forType: .tiff) }
    }
}

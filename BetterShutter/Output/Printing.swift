import AppKit

/// Prints a captured/edited image. A view sized to the full pixel dimensions lets AppKit paginate
/// tall (scrolling) captures across multiple pages automatically.
@MainActor
enum Printing {
    static func printImage(_ cgImage: CGImage) {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown

        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.run()
    }
}

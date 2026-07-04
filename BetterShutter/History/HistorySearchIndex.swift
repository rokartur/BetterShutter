import CoreGraphics
import Foundation
import ImageIO

/// Filename → recognized text for the history archive, so Capture History search matches what is
/// *in* a screenshot, not just its filename. Built lazily (one on-device OCR pass per image, in the
/// background) and persisted as a hidden JSON file next to the archive; entries for deleted files
/// are pruned alongside them. Empty strings are stored too — they mark "already scanned, no text"
/// so an image is never OCR'd twice.
nonisolated enum HistorySearchIndex {

    private static var fileURL: URL {
        CaptureHistoryStore.directory.appendingPathComponent(".search-index.json", isDirectory: false)
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func save(_ index: [String: String]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// OCR an archived image. Decoded via ImageIO's thumbnail path at a bounded size — plenty for
    /// Vision's text recognizer, and it avoids holding a full Retina 5K bitmap per indexed file.
    static func recognizeText(at url: URL) async -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "" }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2200,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return "" }
        return await TextRecognizer.recognize(CapturedImage(cgImage: cg, scale: 1, displayID: nil))
    }
}

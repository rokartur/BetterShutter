import CoreGraphics
import Foundation

/// Writes encoded image data to the configured save directory, resolving name collisions.
nonisolated enum FileSaver {
    /// Encodes and saves a capture, returning the written file URL.
    static func save(_ cgImage: CGImage, mode: CaptureMode) throws -> URL {
        let format = Preferences.format
        guard let data = ImageEncoder.encode(cgImage, as: format, quality: Preferences.jpegQuality) else {
            throw CaptureError.emptyCapture
        }
        return try write(data, format: format, mode: mode)
    }

    /// Write already-encoded data with the standard directory/naming/collision handling — lets
    /// callers that encoded once (clipboard + upload + save) skip a redundant encode.
    static func write(_ data: Data, format: ImageFileFormat, mode: CaptureMode) throws -> URL {
        let directory = Preferences.saveDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = FilenameTemplate.render(
            Preferences.filenameTemplate,
            mode: mode,
            format: format,
            counter: Preferences.nextCaptureCounter()
        )
        let url = uniqueURL(in: directory, filename: filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Appends " (k)" before the extension if the target already exists.
    static func uniqueURL(in directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }
}

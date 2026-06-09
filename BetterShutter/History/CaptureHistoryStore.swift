import CoreGraphics
import Foundation

/// A self-contained archive of past captures, kept in the app's Application Support folder — separate
/// from the user's save directory so the Capture History bar has its own data and retention can prune
/// it freely without ever touching the user's files.
nonisolated enum CaptureHistoryStore {

    /// `~/Library/Application Support/BetterShutter/History`.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "BetterShutter"
        return base.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Archive an image capture as PNG.
    static func add(_ cgImage: CGImage, mode: CaptureMode, date: Date = Date()) {
        ensureDirectory()
        guard let png = ImageEncoder.encode(cgImage, as: .png) else { return }
        let url = directory.appendingPathComponent(filename(tag: mode.fileTag, ext: "png", date: date))
        try? png.write(to: url, options: .atomic)
        prune()
    }

    /// Archive an already-written file (e.g. a recording's MP4/GIF) by copying it in.
    static func add(fileURL: URL, date: Date = Date()) {
        ensureDirectory()
        let ext = fileURL.pathExtension.isEmpty ? "dat" : fileURL.pathExtension
        let dest = directory.appendingPathComponent(filename(tag: "Recording", ext: ext, date: date))
        try? FileManager.default.copyItem(at: fileURL, to: dest)
        prune()
    }

    /// Delete archived captures older than the configured retention window (no-op when unlimited).
    static func prune(retention: CaptureHistoryRetention = Preferences.captureHistoryRetention) {
        guard let maxAge = retention.maxAge else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Unique, human-readable filename — a UUID suffix avoids same-second collisions.
    private static func filename(tag: String, ext: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(tag) \(formatter.string(from: date)) \(UUID().uuidString.prefix(4)).\(ext)"
    }
}

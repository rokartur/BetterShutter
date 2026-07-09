import CoreGraphics
import Darwin
import Foundation

/// A self-contained archive of past captures, kept in the app's Caches folder — separate from the
/// user's save directory so the Capture History bar has its own data and retention can prune it
/// freely without ever touching the user's files. Caches is the right home: the archive is
/// re-creatable convenience data, so the system (and cleanup tools) may reclaim it.
nonisolated enum CaptureHistoryStore {
    /// CaptureHistory and recording finalization archive from detached tasks. Serialize encoding,
    /// copies, and pruning so several full-resolution captures cannot spike CPU/RAM and a prune
    /// cannot enumerate/remove files halfway through an archive transaction.
    private static let archiveLock = NSLock()

    /// `~/Library/Caches/BetterShutter/History`. Resolved once; archives from the old
    /// Application Support location are migrated in on first access.
    ///
    /// A test host gets a throwaway per-process folder instead — unit tests archive tiny fixture
    /// images through `CaptureHistory`, and those must never land in (or prune) the user's real
    /// archive; they showed up in the Capture History bar as phantom solid-color captures.
    static let directory: URL = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "BetterShutter-TestHistory-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let bundle = Bundle.main.bundleIdentifier ?? "BetterShutter"
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        migrateLegacyStore(to: dir)
        return dir
    }()

    /// One-time move of the pre-Caches archive (`~/Library/Application Support/<bundle>/History`).
    private static func migrateLegacyStore(to dir: URL) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let bundle = Bundle.main.bundleIdentifier ?? "BetterShutter"
        let legacy = support.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fm.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        try? fm.removeItem(at: legacy)
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Archive an image capture as PNG.
    static func add(_ cgImage: CGImage, mode: CaptureMode, date: Date = Date()) {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        ensureDirectory()
        guard let png = ImageEncoder.encode(cgImage, as: .png) else { return }
        writePNGUnlocked(png, mode: mode, date: date)
    }

    /// Archive PNG bytes already produced for clipboard/upload/save. Sharing this buffer avoids a
    /// second full ImageIO encode of the same 5K capture solely for history.
    static func add(png: Data, mode: CaptureMode, date: Date = Date()) {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        ensureDirectory()
        writePNGUnlocked(png, mode: mode, date: date)
    }

    private static func writePNGUnlocked(_ png: Data, mode: CaptureMode, date: Date) {
        let url = directory.appendingPathComponent(filename(tag: mode.fileTag, ext: "png", date: date))
        do {
            try png.write(to: url, options: .atomic)
            // Encoding runs asynchronously; filesystem completion time is not capture time. Store
            // the semantic timestamp so history sorting cannot invert captures whose encodes finish
            // out of order. A metadata failure must not discard an otherwise valid archive.
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        } catch {}
        pruneUnlocked(retention: Preferences.captureHistoryRetention)
    }

    /// Archive an already-written file (e.g. a recording's MP4/GIF) by copying it in.
    @discardableResult
    static func add(fileURL: URL, date: Date = Date()) -> URL? {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        ensureDirectory()
        cleanupStagingUnlocked()
        let ext = fileURL.pathExtension.isEmpty ? "dat" : fileURL.pathExtension
        let dest = directory.appendingPathComponent(filename(tag: "Recording", ext: ext, date: date))
        let staging = directory.appendingPathComponent(
            ".BetterShutter-archive-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).partial",
            isDirectory: false)
        var stagingExists = false
        defer { if stagingExists { try? FileManager.default.removeItem(at: staging) } }
        do {
            // Copy under a hidden staging name. The history panel skips hidden files, so it can
            // never hand AVFoundation a half-written movie. Same-directory move publishes the
            // complete archive atomically.
            stagingExists = true
            try FileManager.default.copyItem(at: fileURL, to: staging)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: staging.path)
            try FileManager.default.moveItem(at: staging, to: dest)
            stagingExists = false
        } catch { return nil }
        pruneUnlocked(retention: Preferences.captureHistoryRetention)
        return dest
    }

    /// Delete archived captures older than the configured retention window (no-op when unlimited).
    static func prune(retention: CaptureHistoryRetention = Preferences.captureHistoryRetention) {
        // Reload/close/reopen can schedule several best-effort prunes. Never park cooperative-pool
        // threads behind a large movie copy or PNG encode; every successful add prunes under the
        // same lock, and the history UI independently filters expired entries meanwhile.
        guard archiveLock.try() else { return }
        defer { archiveLock.unlock() }
        cleanupStagingUnlocked()
        pruneUnlocked(retention: retention)
    }

    /// A process kill can strand a hidden staging file. `archiveLock` is process-local, so never
    /// delete another live BetterShutter instance's active copy; PID-tagged files are removed only
    /// when their owner no longer exists. Legacy untagged partials age out after seven days.
    private static func cleanupStagingUnlocked() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let prefix = ".BetterShutter-archive-"
        let legacyCutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for file in files where file.lastPathComponent.hasPrefix(".BetterShutter-archive-")
            && file.pathExtension == "partial" {
            let suffix = file.lastPathComponent.dropFirst(prefix.count)
            let pidText = suffix.prefix { $0 != "-" }
            if let pid = pid_t(pidText) {
                errno = 0
                let alive = Darwin.kill(pid, 0) == 0 || errno == EPERM
                if alive { continue }
                try? FileManager.default.removeItem(at: file)
            } else if let modified = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified < legacyCutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func pruneUnlocked(retention: CaptureHistoryRetention) {
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
        return "\(tag) \(formatter.string(from: date)) \(UUID().uuidString.prefix(8)).\(ext)"
    }
}

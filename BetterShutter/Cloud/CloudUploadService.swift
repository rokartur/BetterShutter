import AppKit

/// Orchestrates an upload: pick the configured provider, encode, upload, copy the share link, record
/// it in the link history, and surface progress/errors via the HUD.
@MainActor
enum CloudUploadService {
    /// Upload is latest-wins. Retaining every superseded PNG/multipart/network task allows repeated
    /// clicks to grow memory and saturate CPU/network without bound, so starting a new request
    /// cancels the previous one and only the live request may enter history or touch clipboard/HUD.
    private static var uploadGeneration: UInt = 0
    private static var uploadTask: Task<Void, Never>?
    private struct PendingUpload {
        let generation: UInt
        let pasteboardChangeCount: Int
        let perform: @Sendable () async throws -> URL
    }
    /// At most one request runs and one latest replacement waits. Repeated clicks replace this
    /// closure instead of spawning more non-cancellable ImageIO finalizations or network bodies.
    private static var pendingUpload: PendingUpload?

    static var isEnabled: Bool { Preferences.cloudProvider != .none }

    static func uploader() -> Uploader? {
        switch Preferences.cloudProvider {
        case .none: return nil
        case .s3: return S3Uploader(config: Preferences.s3Config, secretKey: Preferences.s3SecretKey)
        case .imgbb: return ImgbbUploader(apiKey: Preferences.imgbbAPIKey)
        case .zeroXZero: return ZeroXZeroUploader()
        case .catbox: return CatboxUploader(userHash: Preferences.catboxUserHash)
        case .litterbox: return LitterboxUploader(expiry: Preferences.litterboxExpiry)
        }
    }

    /// A safe, collision-resistant object key (pure, for testing).
    nonisolated static func makeKey(stamp: String, random: String, ext: String) -> String {
        "\(stamp)-\(random).\(ext)"
    }

    /// Upload pre-encoded PNG data and copy the resulting link.
    static func upload(png data: Data) {
        guard let uploader = uploader() else { HUD.show("Set up Cloud in Settings"); return }
        let key = currentKey(ext: "png")
        send { try await uploader.upload(data, key: key, contentType: "image/png") }
    }

    /// Upload an in-memory image (PNG) and copy the resulting link. Encoding a Retina frame is
    /// CPU-heavy (~60 MB bitmap), so it runs off the main thread inside the upload task.
    static func upload(_ image: CGImage) {
        guard let uploader = uploader() else { HUD.show("Set up Cloud in Settings"); return }
        let key = currentKey(ext: "png")
        let captured = CapturedImage(cgImage: image, scale: 1, displayID: nil)
        send {
            let data = await ImageEncoder.encodeAsync(captured.cgImage, as: .png)
            try Task.checkCancellation()
            guard let data else { throw CloudError.encodeFailed }
            return try await uploader.upload(data, key: key, contentType: "image/png")
        }
    }

    /// Upload an existing file (preserves the original format — GIF animation, video, etc.).
    /// Streamed from disk by providers that support it — recordings can be hundreds of MB, so
    /// they must never be read into memory whole.
    static func uploadFile(_ fileURL: URL) {
        guard let uploader = uploader() else { HUD.show("Set up Cloud in Settings"); return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { HUD.show("Couldn't read file"); return }
        let ext = fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension.lowercased()
        let key = currentKey(ext: ext)
        let type = contentType(forExtension: ext)
        // imgbb hosts images only; bail before its non-streaming fallback reads a whole
        // recording into memory just to have the server reject it.
        if uploader is ImgbbUploader, !type.hasPrefix("image/") {
            HUD.show("imgbb hosts images only")
            return
        }
        send { try await uploader.uploadFile(fileURL, key: key, contentType: type) }
    }

    private static func send(_ perform: @escaping @Sendable () async throws -> URL) {
        uploadGeneration &+= 1
        let generation = uploadGeneration
        // A share link may replace only the clipboard state that existed when this upload began.
        // This also protects copies made by other apps while the network request is in flight.
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        pendingUpload = PendingUpload(
            generation: generation,
            pasteboardChangeCount: pasteboardChangeCount,
            perform: perform)
        uploadTask?.cancel()
        HUD.show("Uploading…", duration: 1.0)
        startNextUploadIfNeeded()
    }

    private static func startNextUploadIfNeeded() {
        guard uploadTask == nil, let request = pendingUpload else { return }
        pendingUpload = nil
        uploadTask = Task {
            defer {
                uploadTask = nil
                startNextUploadIfNeeded()
            }
            do {
                let url = try await request.perform()
                try Task.checkCancellation()
                Preferences.cloudLinkHistory = [url.absoluteString] + Preferences.cloudLinkHistory
                guard request.generation == uploadGeneration,
                      NSPasteboard.general.changeCount == request.pasteboardChangeCount else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                HUD.show("Link copied")
            } catch {
                guard !Task.isCancelled, request.generation == uploadGeneration else { return }
                HUD.show(error.localizedDescription)
            }
        }
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    private static func currentKey(ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        let random = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return makeKey(stamp: stamp, random: random, ext: ext)
    }
}

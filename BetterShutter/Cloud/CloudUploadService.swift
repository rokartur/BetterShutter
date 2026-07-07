import AppKit

/// Orchestrates an upload: pick the configured provider, encode, upload, copy the share link, record
/// it in the link history, and surface progress/errors via the HUD.
@MainActor
enum CloudUploadService {
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
            guard let data = await Task.detached(operation: {
                ImageEncoder.encode(captured.cgImage, as: .png)
            }).value else { throw CloudError.encodeFailed }
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
        HUD.show("Uploading…", duration: 1.0)
        Task {
            do {
                let url = try await perform()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                Preferences.cloudLinkHistory = [url.absoluteString] + Preferences.cloudLinkHistory
                HUD.show("Link copied")
            } catch {
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

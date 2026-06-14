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
        }
    }

    /// A safe, collision-resistant object key (pure, for testing).
    nonisolated static func makeKey(stamp: String, random: String, ext: String) -> String {
        "\(stamp)-\(random).\(ext)"
    }

    /// Upload an in-memory image (PNG) and copy the resulting link.
    static func upload(_ image: CGImage) {
        guard let uploader = uploader() else { HUD.show("Set up Cloud in Settings"); return }
        guard let data = ImageEncoder.encode(image, as: .png) else { HUD.show("Encode failed"); return }
        send(data, key: currentKey(ext: "png"), contentType: "image/png", using: uploader)
    }

    /// Upload an existing file (preserves the original format — GIF animation, video, etc.).
    static func uploadFile(_ fileURL: URL) {
        guard let uploader = uploader() else { HUD.show("Set up Cloud in Settings"); return }
        guard let data = try? Data(contentsOf: fileURL) else { HUD.show("Couldn't read file"); return }
        let ext = fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension.lowercased()
        send(data, key: currentKey(ext: ext), contentType: contentType(forExtension: ext), using: uploader)
    }

    private static func send(_ data: Data, key: String, contentType: String, using uploader: Uploader) {
        HUD.show("Uploading…", duration: 1.0)
        Task {
            do {
                let url = try await uploader.upload(data, key: key, contentType: contentType)
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

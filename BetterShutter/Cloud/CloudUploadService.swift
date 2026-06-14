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

    /// Upload an image and copy the resulting link to the clipboard.
    static func upload(_ image: CGImage) {
        guard let uploader = uploader() else { HUD.show("Set up Cloud in Settings"); return }
        guard let data = ImageEncoder.encode(image, as: .png) else { HUD.show("Encode failed"); return }
        let key = currentKey(ext: "png")
        HUD.show("Uploading…", duration: 1.0)
        Task {
            do {
                let url = try await uploader.upload(data, key: key, contentType: "image/png")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                Preferences.cloudLinkHistory = [url.absoluteString] + Preferences.cloudLinkHistory
                HUD.show("Link copied")
            } catch {
                HUD.show(error.localizedDescription)
            }
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

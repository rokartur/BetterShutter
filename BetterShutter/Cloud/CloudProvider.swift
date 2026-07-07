import Foundation
import Security

/// Where uploaded captures go. CleanShot Cloud is a proprietary SaaS we can't replicate, so the
/// shipped options mirror macshot/Snapzy: bring-your-own S3-compatible storage, or a free host
/// (imgbb, 0x0.st, catbox.moe, litterbox).
nonisolated enum CloudProvider: String, CaseIterable, Sendable {
    case none
    case s3
    case imgbb
    case zeroXZero = "0x0"
    case catbox
    case litterbox

    var presentableName: String {
        switch self {
        case .none: return "Off"
        case .s3: return "S3 / R2 (S3-compatible)"
        case .imgbb: return "imgbb"
        case .zeroXZero: return "0x0.st"
        case .catbox: return "Catbox (permanent)"
        case .litterbox: return "Litterbox (temporary)"
        }
    }
}

/// How long litterbox.catbox.moe keeps a file. Raw values are the API's `time` parameter.
nonisolated enum LitterboxExpiry: String, CaseIterable, Sendable {
    case oneHour = "1h"
    case twelveHours = "12h"
    case oneDay = "24h"
    case threeDays = "72h"

    var presentableName: String {
        switch self {
        case .oneHour: return "1 hour"
        case .twelveHours: return "12 hours"
        case .oneDay: return "24 hours"
        case .threeDays: return "72 hours"
        }
    }
}

/// Non-secret S3 configuration (the secret access key lives in the Keychain, not here).
nonisolated struct S3Config: Codable, Sendable, Equatable {
    var accessKey = ""
    var region = "auto"            // R2 uses "auto"; S3 uses e.g. "us-east-1"
    var bucket = ""
    var endpointHost = ""          // e.g. "s3.amazonaws.com" or "<account>.r2.cloudflarestorage.com"
    var usePathStyle = true        // R2 / MinIO prefer path-style
    var publicBaseURL = ""         // e.g. "https://cdn.example.com" (key appended); empty = derive
    var setPublicACL = false       // S3 honors x-amz-acl: public-read; R2 ignores it

    /// The object URL for `key` (virtual-hosted or path-style), used both to PUT and to share.
    func objectURL(key: String) -> URL? {
        if !publicBaseURL.isEmpty {
            return URL(string: publicBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + key)
        }
        guard !endpointHost.isEmpty, !bucket.isEmpty else { return nil }
        let base = usePathStyle ? "https://\(endpointHost)/\(bucket)/\(key)"
                                : "https://\(bucket).\(endpointHost)/\(key)"
        return URL(string: base)
    }
}

/// Tiny Keychain wrapper (generic password) for cloud secrets.
nonisolated enum CloudKeychain {
    private static let service = "app.bettershutter.cloud"

    static func set(_ value: String, account: String) {
        delete(account: account)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Persistence (non-secrets in UserDefaults, secrets in Keychain)

extension Preferences {
    nonisolated private static var cloudDefaults: UserDefaults { .standard }

    static var cloudProvider: CloudProvider {
        get { CloudProvider(rawValue: cloudDefaults.string(forKey: "cloudProvider") ?? "") ?? .none }
        set { cloudDefaults.set(newValue.rawValue, forKey: "cloudProvider") }
    }

    static var s3Config: S3Config {
        get {
            guard let data = cloudDefaults.data(forKey: "cloudS3Config"),
                  let cfg = try? JSONDecoder().decode(S3Config.self, from: data) else { return S3Config() }
            return cfg
        }
        set { if let data = try? JSONEncoder().encode(newValue) { cloudDefaults.set(data, forKey: "cloudS3Config") } }
    }

    static var s3SecretKey: String {
        get { CloudKeychain.get(account: "s3.secretKey") }
        set { CloudKeychain.set(newValue, account: "s3.secretKey") }
    }

    static var imgbbAPIKey: String {
        get { CloudKeychain.get(account: "imgbb.apiKey") }
        set { CloudKeychain.set(newValue, account: "imgbb.apiKey") }
    }

    /// Optional catbox.moe account hash — anonymous uploads work without it. Trimmed on write:
    /// a value pasted from the catbox site often carries a trailing newline.
    static var catboxUserHash: String {
        get { CloudKeychain.get(account: "catbox.userHash") }
        set { CloudKeychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), account: "catbox.userHash") }
    }

    static var litterboxExpiry: LitterboxExpiry {
        get { LitterboxExpiry(rawValue: cloudDefaults.string(forKey: "cloudLitterboxExpiry") ?? "") ?? .oneDay }
        set { cloudDefaults.set(newValue.rawValue, forKey: "cloudLitterboxExpiry") }
    }

    /// Automatically upload after every capture and copy the link. Nonisolated (like the rest of
    /// `Preferences`) so the After-Capture matrix accessors can proxy it; UserDefaults is thread-safe.
    nonisolated static var uploadAfterCapture: Bool {
        get { cloudDefaults.bool(forKey: "cloudUploadAfterCapture") }
        set { cloudDefaults.set(newValue, forKey: "cloudUploadAfterCapture") }
    }

    /// Recently uploaded share links, newest first (capped).
    static var cloudLinkHistory: [String] {
        get { cloudDefaults.stringArray(forKey: "cloudLinkHistory") ?? [] }
        set { cloudDefaults.set(Array(newValue.prefix(50)), forKey: "cloudLinkHistory") }
    }
}

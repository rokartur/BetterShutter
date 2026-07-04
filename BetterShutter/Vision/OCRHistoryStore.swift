import Foundation
import Security

/// One recognized-text result kept in the OCR history.
nonisolated struct OCRHistoryEntry: Codable, Sendable, Equatable {
    let date: Date
    let text: String
}

/// Recognized-text history persisted as a single generic-password item in the user's login
/// keychain, so past OCR results are encrypted at rest instead of sitting in plain text on disk.
/// The item is created by the app itself, which puts BetterShutter on the item's access list —
/// reads and writes never trigger a keychain password (or admin) prompt.
nonisolated enum OCRHistoryStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "BetterShutter") + ".ocr-history"
    private static let account = "recognized-text"

    /// Keychain items should stay small — keep only the most recent results.
    static let maxEntries = 50

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Prepend a result (newest first), honoring the settings toggle and the entry cap.
    static func add(_ text: String, date: Date = Date()) {
        guard Preferences.ocrHistoryEnabled, !text.isEmpty else { return }
        var entries = all()
        entries.insert(OCRHistoryEntry(date: date, text: text), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save(entries)
    }

    /// All stored results, newest first. Empty when the history is off or was never written.
    static func all() -> [OCRHistoryEntry] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return [] }
        return (try? JSONDecoder().decode([OCRHistoryEntry].self, from: data)) ?? []
    }

    /// Remove a single result (index into `all()`, newest first).
    static func remove(at index: Int) {
        var entries = all()
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        entries.isEmpty ? clear() : save(entries)
    }

    /// Delete the keychain item entirely.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static func save(_ entries: [OCRHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

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
    /// A FIFO queue preserves *invocation* order, not merely mutual exclusion. Thus an OCR add
    /// enqueued before the user presses Clear completes first and Clear is the final operation;
    /// a detached task racing for an NSLock could otherwise resurrect the cleared entry afterward.
    private static let queue = DispatchQueue(label: "app.bettershutter.ocr-history")

    /// Keychain items should stay small — keep only the most recent results.
    static let maxEntries = 50

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Enqueue a result without doing a Keychain round-trip on MainActor. FIFO ordering with the
    /// synchronous remove/clear calls below gives UI actions a deterministic happens-before order.
    static func enqueueAdd(_ text: String, date: Date = Date()) {
        queue.async {
            guard Preferences.ocrHistoryEnabled, !text.isEmpty else { return }
            var entries = loadUnlocked()
            entries.insert(OCRHistoryEntry(date: date, text: text), at: 0)
            if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
            saveUnlocked(entries)
        }
    }

    /// All stored results, newest first. Empty when the history is off or was never written.
    static func all() -> [OCRHistoryEntry] {
        queue.sync { loadUnlocked() }
    }

    private static func loadUnlocked() -> [OCRHistoryEntry] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return [] }
        return (try? JSONDecoder().decode([OCRHistoryEntry].self, from: data)) ?? []
    }

    /// Remove the stable entry selected by the UI snapshot. A concurrent prepend must not shift an
    /// integer index and cause deletion of the wrong OCR result.
    static func remove(_ entry: OCRHistoryEntry) {
        queue.sync {
            var entries = loadUnlocked()
            guard let index = entries.firstIndex(of: entry) else { return }
            entries.remove(at: index)
            entries.isEmpty ? clearUnlocked() : saveUnlocked(entries)
        }
    }

    /// Delete the keychain item entirely.
    static func clear() {
        queue.sync { clearUnlocked() }
    }

    private static func clearUnlocked() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static func saveUnlocked(_ entries: [OCRHistoryEntry]) {
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

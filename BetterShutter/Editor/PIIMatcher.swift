import Foundation

/// Detects personally-identifiable / secret strings in OCR text so the editor can auto-redact them.
/// Pure and unit-tested; matching is per-line (an OCR observation), so a whole line containing PII
/// is redacted.
nonisolated enum PIIMatcher {
    private static let patterns: [String] = [
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,        // email
        #"\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b"#,                       // phone
        #"\b(?:\d[ -]?){13,16}\b"#,                                  // credit card
        #"\b\d{3}-\d{2}-\d{4}\b"#,                                   // US SSN
        #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#,                             // IPv4
        #"(?:AKIA|ASIA)[A-Z0-9]{16}"#,                               // AWS access key
        #"(?i)\bbearer\s+[A-Za-z0-9._\-]+"#,                         // bearer token
        #"(?i)\b(?:api[_-]?key|token|secret)\b\s*[:=]\s*\S+"#,       // key=value secrets
    ]

    static func containsPII(_ text: String) -> Bool {
        for pattern in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

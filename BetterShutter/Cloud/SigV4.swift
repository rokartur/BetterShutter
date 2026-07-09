import Foundation
import CryptoKit

/// Minimal AWS Signature Version 4 signer for S3-compatible PUT uploads (AWS S3, Cloudflare R2,
/// MinIO, DigitalOcean Spaces, Backblaze B2). Pure and unit-tested against AWS's published vectors.
nonisolated enum SigV4 {
    /// Inputs for signing one request.
    struct Request {
        var method: String          // "PUT"
        var host: String            // URL host (becomes the Host header)
        var path: String            // canonical URI, percent-encoded, e.g. "/bucket/key.png"
        var query: String           // canonical query string ("" if none)
        var headers: [String: String]  // header name (any case) → value; MUST include host + x-amz-date + x-amz-content-sha256
        var payloadHashHex: String  // hex SHA-256 of the body
        var date: Date
        var region: String
        var service: String         // "s3"
        var secretKey: String
        var accessKey: String
    }

    // MARK: Public

    /// The full `Authorization` header value for `request`.
    static func authorizationHeader(_ r: Request) -> String {
        let (canonicalHeaders, signedHeaders) = canonicalHeaders(r.headers)
        let canonicalRequest = [
            r.method, r.path, r.query, canonicalHeaders, signedHeaders, r.payloadHashHex,
        ].joined(separator: "\n")

        let amzDate = amzDateString(r.date)
        let dateStamp = dateStampString(r.date)
        let scope = "\(dateStamp)/\(r.region)/\(r.service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        let signingKey = self.signingKey(secret: r.secretKey, dateStamp: dateStamp,
                                         region: r.region, service: r.service)
        let signature = hex(hmac(key: signingKey, data: Data(stringToSign.utf8)))

        return "AWS4-HMAC-SHA256 Credential=\(r.accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    static func amzDateString(_ date: Date) -> String { formatter("yyyyMMdd'T'HHmmss'Z'").string(from: date) }
    static func dateStampString(_ date: Date) -> String { formatter("yyyyMMdd").string(from: date) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// SHA-256 of a file, hashed in 1 MB chunks so signing a multi-hundred-MB recording never
    /// loads the whole file into memory.
    static func sha256HexOfFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            // Hashing a recording can take seconds. Let cancellation stop both this CPU work and
            // the subsequent upload instead of finishing the entire file unconditionally.
            try Task<Never, Never>.checkCancellation()
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    // MARK: Internals

    /// The SigV4 derived signing key (HMAC chain: date → region → service → "aws4_request").
    static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// Lowercased, sorted "name:trimmedValue\n" block plus the ";"-joined signed-header list.
    private static func canonicalHeaders(_ headers: [String: String]) -> (canonical: String, signed: String) {
        let sorted = headers
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
        let canonical = sorted.map { "\($0.0):\($0.1)\n" }.joined()
        let signed = sorted.map { $0.0 }.joined(separator: ";")
        return (canonical, signed)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
}

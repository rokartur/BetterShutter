import Foundation

enum CloudError: LocalizedError {
    case notConfigured
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud upload isn't configured."
        case .http(let code): return "Upload failed (HTTP \(code))."
        case .badResponse: return "The server returned an unexpected response."
        }
    }
}

/// Uploads image data and returns a shareable URL.
protocol Uploader: Sendable {
    func upload(_ data: Data, key: String, contentType: String) async throws -> URL
}

/// PUT an object to any S3-compatible endpoint (AWS S3, Cloudflare R2, MinIO, Spaces, B2), signed
/// with SigV4. Returns the object's public URL (custom domain / derived).
struct S3Uploader: Uploader {
    let config: S3Config
    let secretKey: String

    func upload(_ data: Data, key: String, contentType: String) async throws -> URL {
        guard !config.accessKey.isEmpty, !secretKey.isEmpty,
              let url = config.objectURL(key: key), let host = url.host else { throw CloudError.notConfigured }

        let now = Date()
        let payloadHash = SigV4.sha256Hex(data)
        var headers: [String: String] = [
            "host": host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": SigV4.amzDateString(now),
            "content-type": contentType,
        ]
        if config.setPublicACL { headers["x-amz-acl"] = "public-read" }

        // Canonical URI = the URL's already-encoded path (keys are generated as safe slugs).
        let canonicalPath = url.path.isEmpty ? "/" : url.path
        let auth = SigV4.authorizationHeader(SigV4.Request(
            method: "PUT", host: host, path: canonicalPath, query: "", headers: headers,
            payloadHashHex: payloadHash, date: now, region: config.region, service: "s3",
            secretKey: secretKey, accessKey: config.accessKey))

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(auth, forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw CloudError.http(http.statusCode) }
        return url
    }
}

/// Upload to imgbb (free image host). Requires the user's API key.
struct ImgbbUploader: Uploader {
    let apiKey: String

    func upload(_ data: Data, key: String, contentType: String) async throws -> URL {
        guard !apiKey.isEmpty, var comps = URLComponents(string: "https://api.imgbb.com/1/upload") else {
            throw CloudError.notConfigured
        }
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let endpoint = comps.url else { throw CloudError.notConfigured }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("image=\(encoded)".utf8)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw CloudError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let urlString = payload["url"] as? String, let url = URL(string: urlString) else {
            throw CloudError.badResponse
        }
        return url
    }
}

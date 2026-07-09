import Foundation

enum CloudError: LocalizedError {
    case notConfigured
    case encodeFailed
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud upload isn't configured."
        case .encodeFailed: return "Couldn't encode the image."
        case .http(let code): return "Upload failed (HTTP \(code))."
        case .badResponse: return "The server returned an unexpected response."
        }
    }
}

/// Uploads image data and returns a shareable URL.
protocol Uploader: Sendable {
    func upload(_ data: Data, key: String, contentType: String) async throws -> URL
    /// Upload an existing file. Providers that can should stream from disk instead of loading
    /// the whole file into memory (recordings run to hundreds of MB).
    func uploadFile(_ fileURL: URL, key: String, contentType: String) async throws -> URL
}

extension Uploader {
    /// Fallback for providers without a streaming path. Only imgbb uses it, and imgbb accepts
    /// images only (a few MB), so reading the whole file is acceptable here.
    func uploadFile(_ fileURL: URL, key: String, contentType: String) async throws -> URL {
        try await upload(Data(contentsOf: fileURL), key: key, contentType: contentType)
    }
}

/// PUT an object to any S3-compatible endpoint (AWS S3, Cloudflare R2, MinIO, Spaces, B2), signed
/// with SigV4. Returns the object's public URL (custom domain / derived).
nonisolated struct S3Uploader: Uploader {
    let config: S3Config
    let secretKey: String

    @concurrent
    func upload(_ data: Data, key: String, contentType: String) async throws -> URL {
        let (request, url) = try signedPutRequest(
            key: key, contentType: contentType, payloadHash: SigV4.sha256Hex(data))
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        try Self.validate(response)
        return url
    }

    /// Stream the file from disk: the payload hash is computed in chunks and URLSession reads the
    /// body from the file, so memory stays flat regardless of file size.
    @concurrent
    func uploadFile(_ fileURL: URL, key: String, contentType: String) async throws -> URL {
        let (request, url) = try signedPutRequest(
            key: key, contentType: contentType, payloadHash: SigV4.sha256HexOfFile(fileURL))
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        try Self.validate(response)
        return url
    }

    private func signedPutRequest(key: String, contentType: String,
                                  payloadHash: String) throws -> (URLRequest, URL) {
        guard !config.accessKey.isEmpty, !secretKey.isEmpty,
              let url = config.objectURL(key: key), let host = url.host else { throw CloudError.notConfigured }

        let now = Date()
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
        return (request, url)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw CloudError.http(http.statusCode) }
    }
}

/// Upload to imgbb (free image host). Requires the user's API key.
nonisolated struct ImgbbUploader: Uploader {
    let apiKey: String

    /// Multipart body: prefix + the raw payload bytes + suffix. Peak memory is ~2× the payload
    /// (data + body), versus ~4× for the previous urlencoded-base64 path (data + base64 string
    /// + percent-encoded copy + body).
    nonisolated static func multipartBody(data: Data, boundary: String, filename: String, contentType: String) -> Data {
        var body = Data()
        body.reserveCapacity(data.count + 256)
        body.append(Data((
            "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n" +
            "Content-Type: \(contentType)\r\n\r\n"
        ).utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    @concurrent
    func upload(_ data: Data, key: String, contentType: String) async throws -> URL {
        guard !apiKey.isEmpty, var comps = URLComponents(string: "https://api.imgbb.com/1/upload") else {
            throw CloudError.notConfigured
        }
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let endpoint = comps.url else { throw CloudError.notConfigured }

        let boundary = "bettershutter-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = Self.multipartBody(data: data, boundary: boundary, filename: key, contentType: contentType)

        let (respData, response) = try await URLSession.shared.upload(for: request, from: body)
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

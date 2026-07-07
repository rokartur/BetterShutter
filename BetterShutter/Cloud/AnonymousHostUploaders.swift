import Foundation

/// Shared plumbing for the anonymous multipart hosts (0x0.st, catbox.moe, litterbox): POST a
/// multipart/form-data body (text fields + one file part) and read back a plain-text URL.
nonisolated enum MultipartUpload {
    enum Payload: Sendable {
        case data(Data)
        case file(URL)
    }

    static func fieldPart(name: String, value: String, boundary: String) -> Data {
        Data((
            "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n" +
            "\(value)\r\n"
        ).utf8)
    }

    static func fileHeader(fileField: String, filename: String, contentType: String, boundary: String) -> Data {
        Data((
            "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n" +
            "Content-Type: \(contentType)\r\n\r\n"
        ).utf8)
    }

    static func suffix(boundary: String) -> Data { Data("\r\n--\(boundary)--\r\n".utf8) }

    /// In-memory body for screenshot-sized payloads.
    static func body(fields: [(String, String)], fileField: String, filename: String,
                     contentType: String, fileData: Data, boundary: String) -> Data {
        var body = Data()
        body.reserveCapacity(fileData.count + 512)
        for (name, value) in fields { body.append(fieldPart(name: name, value: value, boundary: boundary)) }
        body.append(fileHeader(fileField: fileField, filename: filename, contentType: contentType, boundary: boundary))
        body.append(fileData)
        body.append(suffix(boundary: boundary))
        return body
    }

    /// The same body staged as a temp file, copying the payload in 1 MiB chunks so memory stays
    /// flat for multi-hundred-MB recordings. Caller deletes the returned file.
    static func writeBodyFile(fields: [(String, String)], fileField: String, filename: String,
                              contentType: String, payloadFile: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bettershutter-upload-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        defer { try? out.close() }

        var head = Data()
        for (name, value) in fields { head.append(fieldPart(name: name, value: value, boundary: boundary)) }
        head.append(fileHeader(fileField: fileField, filename: filename, contentType: contentType, boundary: boundary))
        try out.write(contentsOf: head)

        let input = try FileHandle(forReadingFrom: payloadFile)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: suffix(boundary: boundary))
        return bodyURL
    }

    /// `@concurrent` so the body staging (a full read+rewrite of a possibly multi-hundred-MB
    /// recording) runs off the caller's actor — the uploaders are MainActor by project default.
    @concurrent
    static func send(endpoint: URL, fields: [(String, String)], fileField: String,
                     filename: String, contentType: String, payload: Payload) async throws -> URL {
        let boundary = "bettershutter-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let respData: Data
        let response: URLResponse
        switch payload {
        case .data(let data):
            let body = body(fields: fields, fileField: fileField, filename: filename,
                            contentType: contentType, fileData: data, boundary: boundary)
            (respData, response) = try await URLSession.shared.upload(for: request, from: body)
        case .file(let payloadFile):
            let bodyFile = try writeBodyFile(fields: fields, fileField: fileField, filename: filename,
                                             contentType: contentType, payloadFile: payloadFile, boundary: boundary)
            defer { try? FileManager.default.removeItem(at: bodyFile) }
            (respData, response) = try await URLSession.shared.upload(for: request, fromFile: bodyFile)
        }

        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw CloudError.http(http.statusCode) }
        guard let text = String(data: respData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              text.lowercased().hasPrefix("http"), let url = URL(string: text) else {
            throw CloudError.badResponse
        }
        return url
    }
}

/// 0x0.st — anonymous host, no account. Retention scales from 30 days up to a year with file
/// size; hard cap 512 MB.
struct ZeroXZeroUploader: Uploader {
    static let endpoint = URL(string: "https://0x0.st")!

    func upload(_ data: Data, key: String, contentType: String) async throws -> URL {
        try await MultipartUpload.send(endpoint: Self.endpoint, fields: [], fileField: "file",
                                       filename: key, contentType: contentType, payload: .data(data))
    }

    func uploadFile(_ fileURL: URL, key: String, contentType: String) async throws -> URL {
        try await MultipartUpload.send(endpoint: Self.endpoint, fields: [], fileField: "file",
                                       filename: key, contentType: contentType, payload: .file(fileURL))
    }
}

/// catbox.moe — permanent free host (max 200 MB). Anonymous by default; an optional account
/// userhash ties uploads to the user's catbox account.
struct CatboxUploader: Uploader {
    static let endpoint = URL(string: "https://catbox.moe/user/api.php")!
    let userHash: String

    private var fields: [(String, String)] {
        var fields = [("reqtype", "fileupload")]
        // Trim — a hash pasted from the catbox site often carries a trailing newline, and a raw
        // CR/LF inside a multipart field value would corrupt the body framing.
        let hash = userHash.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hash.isEmpty { fields.append(("userhash", hash)) }
        return fields
    }

    func upload(_ data: Data, key: String, contentType: String) async throws -> URL {
        try await MultipartUpload.send(endpoint: Self.endpoint, fields: fields, fileField: "fileToUpload",
                                       filename: key, contentType: contentType, payload: .data(data))
    }

    func uploadFile(_ fileURL: URL, key: String, contentType: String) async throws -> URL {
        try await MultipartUpload.send(endpoint: Self.endpoint, fields: fields, fileField: "fileToUpload",
                                       filename: key, contentType: contentType, payload: .file(fileURL))
    }
}

/// litterbox.catbox.moe — temporary sibling of catbox (max 1 GB); files expire after 1–72 hours.
struct LitterboxUploader: Uploader {
    static let endpoint = URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!
    let expiry: LitterboxExpiry

    private var fields: [(String, String)] {
        [("reqtype", "fileupload"), ("time", expiry.rawValue)]
    }

    func upload(_ data: Data, key: String, contentType: String) async throws -> URL {
        try await MultipartUpload.send(endpoint: Self.endpoint, fields: fields, fileField: "fileToUpload",
                                       filename: key, contentType: contentType, payload: .data(data))
    }

    func uploadFile(_ fileURL: URL, key: String, contentType: String) async throws -> URL {
        try await MultipartUpload.send(endpoint: Self.endpoint, fields: fields, fileField: "fileToUpload",
                                       filename: key, contentType: contentType, payload: .file(fileURL))
    }
}

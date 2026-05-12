import Foundation

struct HostedBammClient: Sendable {
    let baseUrl: String

    private let session: URLSession

    init(baseUrl: String) {
        var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseUrl = trimmed
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 120
        cfg.timeoutIntervalForResource = 240
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: cfg)
    }

    func ping() async -> Bool {
        guard let url = URL(string: baseUrl + "/") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Falls back to `/generate` on 404 (MMM doesn't expose `/generate-motion`).
    func generate(textPrompt: String, temperature: Float = 1.0) async throws -> String {
        let prompt = textPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw BammError.http(status: 0, body: "Empty prompt") }

        let body: [String: Any] = [
            "text_prompt": prompt,
            "temperature": Double(temperature),
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        let (status, raw) = try await post(path: "/generate-motion", body: bodyData)
        if status == 404 {
            let (s2, raw2) = try await post(path: "/generate", body: bodyData)
            if s2 >= 400 {
                throw BammError.http(status: s2, body: snippet(raw2))
            }
            return try decodeBvh(from: raw2, status: s2)
        }
        if status >= 400 {
            throw BammError.http(status: status, body: snippet(raw))
        }
        return try decodeBvh(from: raw, status: status)
    }

    private func post(path: String, body: Data) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: baseUrl + path) else { throw BammError.badUrl }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/plain",      forHTTPHeaderField: "Accept")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BammError.badResponse }
        return (http.statusCode, data)
    }

    /// Accepts raw BVH (BAMM-style) or JSON with `bvh_base64` (MMM-style).
    private func decodeBvh(from data: Data, status: Int) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BammError.http(status: status, body: "Non-text response")
        }
        let trimmed = text.drop(while: { $0.isWhitespace || $0.isNewline })
        if trimmed.hasPrefix("HIERARCHY") {
            return String(trimmed)
        }
        if trimmed.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let b64 = obj["bvh_base64"] as? String,
           let bvhBytes = Data(base64Encoded: b64),
           let bvh = String(data: bvhBytes, encoding: .utf8) {
            return bvh
        }
        throw BammError.http(status: status, body: "Response is not a BVH document (\(snippet(data)))")
    }

    private func snippet(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return String(s.prefix(200))
    }
}

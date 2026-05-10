import Foundation

struct BammClient: Sendable {
    let baseUrl: String

    private let session: URLSession

    init(baseUrl: String) {
        var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseUrl = trimmed
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: cfg)
    }

    func ping() async -> Bool {
        guard let url = URL(string: "\(baseUrl)/api/status?session_id=ping") else { return false }
        do {
            let (_, resp) = try await session.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func start(sessionId: String, text: String, force: Bool = true) async throws {
        try await postEmpty("/api/start", body: [
            "session_id": sessionId,
            "text": text,
            "force": force,
        ])
    }

    func updateText(sessionId: String, text: String) async throws {
        try await postEmpty("/api/update_text", body: [
            "session_id": sessionId,
            "text": text,
        ])
    }

    func reset(sessionId: String) async throws {
        try await postEmpty("/api/reset", body: ["session_id": sessionId])
    }

    /// Returns `[]` while the worker is warming up (server replies `status="waiting"`).
    func getFrame(sessionId: String, count: Int = 8) async throws -> [JointFrame] {
        guard let url = URL(string: "\(baseUrl)/api/get_frame?session_id=\(sessionId)&count=\(count)") else {
            throw BammError.badUrl
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BammError.badResponse }
        if http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BammError.http(status: http.statusCode, body: body)
        }
        let obj = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = obj["status"] as? String
        guard status == "success" else { return [] }
        guard let frames = obj["frames"] as? [[Any]] else { return [] }
        return frames.compactMap { frame -> JointFrame? in
            guard frame.count == 22 else { return nil }
            var flat = [Float](repeating: 0, count: 66)
            for i in 0..<22 {
                guard let xyz = frame[i] as? [Any], xyz.count >= 3 else { return nil }
                flat[i * 3]     = floatFrom(xyz[0])
                flat[i * 3 + 1] = floatFrom(xyz[1])
                flat[i * 3 + 2] = floatFrom(xyz[2])
            }
            return JointFrame(flat)
        }
    }

    private func postEmpty(_ path: String, body: [String: Any]) async throws {
        guard let url = URL(string: baseUrl + path) else { throw BammError.badUrl }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BammError.badResponse }
        if http.statusCode >= 400 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw BammError.http(status: http.statusCode, body: text)
        }
    }

    private func floatFrom(_ any: Any) -> Float {
        if let n = any as? NSNumber { return n.floatValue }
        if let d = any as? Double { return Float(d) }
        if let f = any as? Float { return f }
        if let i = any as? Int { return Float(i) }
        if let s = any as? String, let d = Double(s) { return Float(d) }
        return 0
    }
}

enum BammError: Error, CustomStringConvertible {
    case badUrl
    case badResponse
    case http(status: Int, body: String)

    var description: String {
        switch self {
        case .badUrl: return "Bad URL"
        case .badResponse: return "Bad response"
        case .http(let s, let b): return "HTTP \(s): \(b)"
        }
    }
}

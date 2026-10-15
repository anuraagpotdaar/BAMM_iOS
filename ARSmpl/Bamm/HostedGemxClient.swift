import Foundation

struct HostedGemxResult: Sendable {
    let bvh: String
    let bvhIncam: String?
    let camera: GemxCamera?
}

struct GemxProgress: Sendable, Equatable {
    let state: String
    let elapsedSeconds: Int
    let etaSeconds: Int?
    let fraction: Double

    var text: String {
        switch state {
        case "running":
            if let eta = etaSeconds {
                return "Generating… \(Int((fraction * 100).rounded()))% · ~\(Self.mmss(eta)) left"
            }
            return "Generating… \(Self.mmss(elapsedSeconds)) elapsed"
        case "done":    return "Done"
        case "error":   return "Server error"
        default:        return "Generating… \(Self.mmss(elapsedSeconds)) elapsed"
        }
    }

    static func mmss(_ s: Int) -> String {
        let s = max(s, 0)
        return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)s"
    }
}

struct HostedGemxClient: Sendable {
    let baseUrl: String

    private let session: URLSession

    init(baseUrl: String, requestTimeout: TimeInterval = 1200) {
        var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseUrl = trimmed
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = requestTimeout
        cfg.timeoutIntervalForResource = requestTimeout + 300
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: cfg)
    }

    func ping() async -> Bool {
        guard let url = URL(string: baseUrl + "/") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }

            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String {
                return name.lowercased().contains("gem")
            }
            return true
        } catch {
            return false
        }
    }

    func generate(
        videoURL: URL,
        options: GemxOptions = .defaults,
        onProgress: (@Sendable (GemxProgress) -> Void)? = nil
    ) async throws -> HostedGemxResult {
        guard let url = URL(string: baseUrl + "/generate") else { throw BammError.badUrl }
        let jobId = "ios" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)

        let boundary = "----ARSmplGemx\(UUID().uuidString)"
        let bodyFile = try Self.writeMultipartBody(
            videoURL: videoURL, boundary: boundary,
            fields: [
                "static_cam": options.staticCam ? "true" : "false",
                "no_imgfeat": options.noImgfeat ? "true" : "false",
                "denoiser": options.hostedDenoiser.rawValue,
                "frames": "global,incam",
                "job_id": String(jobId),
            ]
        )
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")

        let poller: Task<Void, Never>? = onProgress.map { cb in
            Task.detached(priority: .utility) { [self] in
                let start = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    if let p = await self.progress(jobId: String(jobId)) {
                        if p.state == "unknown" {

                            cb(GemxProgress(state: "uploading", elapsedSeconds: Int(-start.timeIntervalSinceNow),
                                            etaSeconds: nil, fraction: 0))
                        } else {
                            cb(p)
                        }
                        if p.state == "done" || p.state == "error" { return }
                    }
                }
            }
        }
        defer { poller?.cancel() }

        let (data, resp) = try await session.upload(for: req, fromFile: bodyFile)
        guard let http = resp as? HTTPURLResponse else { throw BammError.badResponse }
        if http.statusCode >= 400 {
            throw BammError.http(status: http.statusCode, body: Self.errorDetail(data))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BammError.http(status: http.statusCode, body: "Non-text response")
        }
        let trimmed = text.drop(while: { $0.isWhitespace || $0.isNewline })
        if trimmed.hasPrefix("{") {
            return try Self.parseJsonResult(data, status: http.statusCode)
        }
        guard trimmed.hasPrefix("HIERARCHY") else {
            throw BammError.http(status: http.statusCode, body: "Response is not a BVH document (\(String(trimmed.prefix(120))))")
        }

        return HostedGemxResult(bvh: String(trimmed), bvhIncam: nil, camera: nil)
    }

    private static func parseJsonResult(_ data: Data, status: Int) throws -> HostedGemxResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var bvh = obj["bvh"] as? String, bvh.contains("HIERARCHY") else {
            throw BammError.http(status: status, body: "JSON response has no BVH")
        }

        bvh.makeContiguousUTF8()
        var camera: GemxCamera? = nil
        if let w = (obj["width"] as? NSNumber)?.intValue, let h = (obj["height"] as? NSNumber)?.intValue, w > 0, h > 0 {
            if let rows = obj["K"] as? [[NSNumber]], rows.count == 3, rows.allSatisfy({ $0.count == 3 }) {
                camera = GemxCamera(width: w, height: h, K: rows.flatMap { $0.map { $0.floatValue } })
            } else {
                camera = .estimated(width: w, height: h)
            }
        }
        let incam: String? = (obj["bvh_incam"] as? String).flatMap { s0 in
            guard s0.contains("HIERARCHY") else { return nil }
            var s1 = s0; s1.makeContiguousUTF8(); return s1
        }
        return HostedGemxResult(bvh: bvh, bvhIncam: incam, camera: camera)
    }

    func progress(jobId: String) async -> GemxProgress? {
        guard let url = URL(string: baseUrl + "/progress/" + jobId) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let state = obj["state"] as? String ?? "unknown"
        let elapsed = (obj["elapsed_s"] as? NSNumber)?.intValue ?? 0
        let eta = (obj["eta_s"] as? NSNumber)?.intValue
        let fraction = (obj["fraction"] as? NSNumber)?.doubleValue ?? 0
        return GemxProgress(state: state, elapsedSeconds: elapsed, etaSeconds: eta, fraction: fraction)
    }

    private static func writeMultipartBody(videoURL: URL, boundary: String, fields: [String: String]) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemx_upload_\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let fh = try FileHandle(forWritingTo: out)
        defer { try? fh.close() }

        func write(_ s: String) throws { try fh.write(contentsOf: Data(s.utf8)) }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let ext = videoURL.pathExtension.lowercased()
        let filename = videoURL.lastPathComponent.isEmpty ? "video.\(ext.isEmpty ? "mp4" : ext)" : videoURL.lastPathComponent
        let mime: String
        switch ext {
        case "mov":  mime = "video/quicktime"
        case "m4v":  mime = "video/x-m4v"
        case "webm": mime = "video/webm"
        case "mkv":  mime = "video/x-matroska"
        case "avi":  mime = "video/x-msvideo"
        default:     mime = "video/mp4"
        }
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: videoURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try fh.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        return out
    }

    private static func errorDetail(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = obj["detail"] as? String { return d }
            if let d = obj["detail"] { return String(describing: d).prefix(200).description }
        }
        return String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
    }
}

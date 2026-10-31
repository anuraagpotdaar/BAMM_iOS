import Foundation
import UIKit

@MainActor
enum GemxBenchmark {

    struct Config: Codable, Sendable {
        var name: String
        var clip: String
        var poseModel: String
        var compute: String
        var flip: Bool
        var tier: String
        var step: Int
        var maxSide: Int = 1080
    }

    struct Result: Codable {
        var config: Config
        var ok: Bool
        var error: String?
        var device: String
        var system: String
        var totalSeconds: Double
        var timings: [String: Double]
        var frames: Int
        var sampledFrames: Int
        var poseLoadSeconds: Double
        var poseMsPerSampledFrame: Double
        var peakFootprintMB: Double
        var footprintBeforeMB: Double
        var thermalBefore: String
        var thermalAfter: String

        var thermalWaitSeconds: Double
        var batteryBefore: Float
        var batteryAfter: Float
        var lowPowerMode: Bool
        var startedAt: String
    }

    static func plan(_ kind: String) -> [Config] {
        let best = Config(name: "", clip: "test3", poseModel: "vitpose_w8.mlmodelc", compute: "auto", flip: true, tier: "fp16", step: 2)
        var out: [Config] = []
        func add(_ c: Config, _ name: String) { var c = c; c.name = name; out.append(c) }
        switch kind {
        case let value where value == "posecompare" || value.hasPrefix("posecompare:"):
            let clips = value.split(separator: ":", maxSplits: 1).dropFirst().first
                .map { $0.split(separator: ",").map(String.init) } ?? ["test3", "test2", "test"]
            let models = ["w8", "w8a8_clipped"]
            for clip in clips {
                for rep in 0...3 {
                    // Alternate the model order between measured rounds.
                    let offset = rep == 0 ? 0 : rep - 1
                    for j in 0..<models.count {
                        let model = models[(j + offset) % models.count]
                        var c = best; c.clip = clip; c.poseModel = "vitpose_\(model).mlmodelc"
                        add(c, "V_\(model)_\(clip)_\(rep == 0 ? "warmup" : "r\(rep)")")
                    }
                }
            }
        case let value where value == "posequant" || value.hasPrefix("posequant:"):
            let requested = value.split(separator: ":").dropFirst().first.map(String.init) ?? "w8a8_clipped"
            let candidate = requested == "w8a8" ? "w8a8_clipped" : requested
            for rep in 0...3 {
                let models = rep % 2 == 0 ? ["w8", candidate] : [candidate, "w8"]
                for model in models {
                    var c = best; c.poseModel = "vitpose_\(model).mlmodelc"
                    let suffix = rep == 0 ? "warmup" : "r\(rep)"
                    add(c, "P_\(model)_test3_\(suffix)")
                }
            }
        case let value where value.hasPrefix("poseone:"):
            let requested = value.split(separator: ":").dropFirst().first.map(String.init) ?? "w8"
            let candidate = requested == "w8a8" ? "w8a8_clipped" : requested
            var c = best; c.poseModel = "vitpose_\(candidate).mlmodelc"
            add(c, "T_\(candidate)_test3")
        case "quant":
            // One excluded warmup and three measured repeats for each tier.
            for rep in 0...3 {
                let tiers = rep % 2 == 0 ? ["fp16", "int8"] : ["int8", "fp16"]
                for tier in tiers {
                    var c = best; c.tier = tier
                    let suffix = rep == 0 ? "warmup" : "r\(rep)"
                    add(c, "Q_\(tier)_test3_\(suffix)")
                }
            }
        case "quick":
            add(best, "quick_w8_auto_flip_test3")
            var c = best; c.clip = "test3_demo_6fps"; add(c, "quick_w8_auto_flip_6fps")
        case "full":

            for model in ["vitpose_w8.mlmodelc"] {
                for flip in [false, true] {
                    var c = best; c.poseModel = model; c.compute = "auto"; c.flip = flip
                    add(c, "A_\(model.hasPrefix("vitpose_w8") ? "w8" : "fp16")_auto_flip\(flip ? 1 : 0)_test3")
                }
            }

            for clip in ["test3_demo_6fps", "test3", "test2", "test", "videoplayback"] {
                for tier in ["fp16", "int8"] {
                    var c = best; c.clip = clip; c.tier = tier
                    add(c, "B_\(tier)_\(clip)")
                }
            }

            for step in [1, 2, 3] { var c = best; c.step = step; add(c, "C_step\(step)_test3") }

            for r in 1...3 { add(best, "D_repeat\(r)_test3") }

            for model in ["vitpose_w8.mlmodelc"] {
                var c = best; c.poseModel = model; c.compute = "cpu"; c.flip = false
                add(c, "E_\(model.hasPrefix("vitpose_w8") ? "w8" : "fp16")_cpu_flip0_test3")
            }
        default:

            let wanted = Set(kind.split(separator: ",").map(String.init))
            out = (plan("full") + plan("posequant")).filter { wanted.contains($0.name) }
        }
        return out
    }

    static func run(kind: String, resume: String? = nil, log: @escaping (String) -> Void) async {
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        var configs = plan(kind)
        let runId = resume ?? ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gemx_bench").appendingPathComponent(runId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resultsURL = dir.appendingPathComponent("results.jsonl")
        if kind == "posedebug" {
            log("[GemxBench] START \(runId) plan=posedebug results=\(resultsURL.path)")
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await GemxPoseLayerDebug.run(directory: dir) { message in
                        Task { @MainActor in log(message) }
                    }
                }.value
            } catch { log("[GemxBench] ERROR \(error)") }
            log("[GemxBench] DONE \(runId)")
            return
        }
        if kind == "posemicro" || kind.hasPrefix("posemicro:") {
            let variants = kind.split(separator: ":", maxSplits: 1).dropFirst().first
                .map { $0.split(separator: ",").map { $0 == "w8a8" ? "w8a8_clipped" : String($0) } } ?? ["w8a8_clipped"]
            log("[GemxBench] START \(runId) plan=\(kind) results=\(resultsURL.path)")
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await GemxPoseMicrobenchmark.run(directory: dir, variants: variants) { message in
                        Task { @MainActor in log(message) }
                    }
                }.value
            } catch { log("[GemxBench] ERROR \(error)") }
            log("[GemxBench] DONE \(runId)")
            return
        }
        if resume != nil, let done = try? String(contentsOf: resultsURL, encoding: .utf8) {
            let doneNames = Set(done.split(separator: "\n").compactMap { line -> String? in
                guard let d = line.data(using: .utf8), let r = try? JSONDecoder().decode(Result.self, from: d) else { return nil }
                return r.config.name
            })
            configs.removeAll { doneNames.contains($0.name) }
            log("[GemxBench] resuming \(runId): \(doneNames.count) done, \(configs.count) left")
        }
        let devInfo = "\(deviceModel()) iOS \(UIDevice.current.systemVersion) cores=\(ProcessInfo.processInfo.activeProcessorCount) ram=\(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB"
        log("[GemxBench] START \(runId) plan=\(kind) runs=\(configs.count) device=\(devInfo) results=\(resultsURL.path)")
        let enc = JSONEncoder()
        for (i, cfg) in configs.enumerated() {
            log("[GemxBench] run \(i + 1)/\(configs.count) \(cfg.name): \(cfg.poseModel) \(cfg.compute) flip=\(cfg.flip) tier=\(cfg.tier) step=\(cfg.step) clip=\(cfg.clip)")

            let tw = Date()
            // Wait for the same starting thermal category in pose comparisons.
            func needsCooling() -> Bool {
                let state = ProcessInfo.processInfo.thermalState
                return (kind.hasPrefix("posecompare") || kind.hasPrefix("posequant"))
                    ? state != .nominal : [.serious, .critical].contains(state)
            }
            while needsCooling(), Date().timeIntervalSince(tw) < 300 {
                log("[GemxBench]   thermal \(thermal()), waiting…")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
            var r = await runOne(cfg, directory: dir, exportComparison: kind.hasPrefix("posecompare"), log: log)
            r.thermalWaitSeconds = Date().timeIntervalSince(tw) - r.totalSeconds
            if let line = try? enc.encode(r), let s = String(data: line, encoding: .utf8), let h = FileHandle(forWritingAtPath: resultsURL.path) ?? create(resultsURL) {
                h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close()
            }
            let t = r.timings
            log(String(format: "[GemxBench] RESULT %@ ok=%d total=%.1fs vitpose=%.1fs (%.0f ms/sampled frame, load %.1fs) detect=%.1fs denoise=%.2fs post=%.2fs frames=%d sampled=%d peakMB=%.0f thermal=%@→%@ (waited %.0fs) battery=%.2f→%.2f %@",
                       cfg.name, r.ok ? 1 : 0, r.totalSeconds, t["vitpose"] ?? 0, r.poseMsPerSampledFrame, r.poseLoadSeconds, t["detect"] ?? 0, t["denoise"] ?? 0, t["post"] ?? 0,
                       r.frames, r.sampledFrames, r.peakFootprintMB, r.thermalBefore, r.thermalAfter, max(0, r.thermalWaitSeconds), r.batteryBefore, r.batteryAfter, r.error ?? ""))
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        log("[GemxBench] DONE \(runId)")
    }

    private static func create(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return FileHandle(forWritingAtPath: url.path)
    }

    private static func runOne(_ cfg: Config, directory: URL, exportComparison: Bool,
                               log: @escaping (String) -> Void) async -> Result {
        let started = ISO8601DateFormatter().string(from: Date())
        let thermalBefore = thermal(), batteryBefore = UIDevice.current.batteryLevel
        let footBefore = footprintMB()
        var r = Result(config: cfg, ok: false, error: nil, device: deviceModel(), system: UIDevice.current.systemVersion,
                       totalSeconds: 0, timings: [:], frames: 0, sampledFrames: 0, poseLoadSeconds: 0, poseMsPerSampledFrame: 0,
                       peakFootprintMB: footBefore, footprintBeforeMB: footBefore, thermalBefore: thermalBefore, thermalAfter: thermalBefore,
                       thermalWaitSeconds: 0, batteryBefore: batteryBefore, batteryAfter: batteryBefore, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, startedAt: started)
        guard let url = Bundle.main.url(forResource: cfg.clip, withExtension: "mp4", subdirectory: "BenchClips") else {
            r.error = "clip \(cfg.clip) not bundled"; return r
        }
        let sampler = FootprintSampler()
        sampler.start()
        let t0 = Date()
        let monotonicStart = DispatchTime.now().uptimeNanoseconds
        do {
            let client = try OnDeviceGemxClient()
            if exportComparison { client.comparisonEpochNanoseconds = monotonicStart }
            let opts = GemxOptions(staticCam: true, noImgfeat: false, hostedDenoiser: .pytorch,
                                   tier: GemxTier(rawValue: cfg.tier) ?? .fp16, sampleStep: cfg.step, maxSide: cfg.maxSide,
                                   poseBackend: .coreml, poseCompute: GemxPoseCompute(rawValue: cfg.compute) ?? .auto,
                                   flipTest: cfg.flip, poseModel: cfg.poseModel)
            var lastLog = Date()
            let res = try await client.generate(videoURL: url, options: opts) { text in
                if Date().timeIntervalSince(lastLog) > 5 { lastLog = Date(); log("[GemxBench]   \(text)") }
            }
            r.totalSeconds = Date().timeIntervalSince(t0)
            r.timings = res.timings
            r.frames = res.motion.frames.count
            r.sampledFrames = res.sampledFrames
            r.poseLoadSeconds = res.poseLoadSeconds
            let vp = (res.timings["vitpose"] ?? 0) - res.poseLoadSeconds
            r.poseMsPerSampledFrame = res.sampledFrames > 0 ? vp * 1000 / Double(res.sampledFrames) : 0
            r.ok = true
            try res.bvh.write(to: directory.appendingPathComponent("\(cfg.name).bvh"), atomically: true, encoding: .utf8)
            if exportComparison {
                try saveComparison(res, client: client, totalSeconds: r.totalSeconds,
                                   directory: directory.appendingPathComponent(cfg.name))
            }
        } catch {
            r.ok = false
            r.totalSeconds = Date().timeIntervalSince(t0)
            r.error = String(describing: error)
        }
        sampler.stop()
        r.peakFootprintMB = max(sampler.peakMB, footprintMB())
        r.thermalAfter = thermal()
        r.batteryAfter = UIDevice.current.batteryLevel
        return r
    }

    private static func saveComparison(_ res: OnDeviceGemxClient.RunResult, client: OnDeviceGemxClient,
                                        totalSeconds: Double, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func floats(_ values: [Float], _ name: String) throws {
            try values.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent(name)) }
        }
        try floats(res.kp2d, "kp2d.f32")
        try floats(res.bbxXys, "boxes.f32")
        try floats(res.joints77.map(Float.init), "joints_global.f32")
        try floats(res.jointsIncam.map(Float.init), "joints_incam.f32")
        let camera = res.camera.camera
        let events: [[String: Any]] = client.comparisonEvents.map { e in
            ["phase": e.phase, "seconds": e.seconds, "sourceFrame": e.sourceFrame ?? -1,
             "completedSamples": e.completedSamples ?? 0]
        }
        let metadata: [String: Any] = ["frames": res.motion.frames.count,
            "frameTime": res.motion.frameTime, "width": camera.width, "height": camera.height,
            "K": camera.K, "sourceFPS": client.comparisonInputFPS,
            "sourceFrames": client.comparisonSourceFrames, "sampledFrames": res.sampledFrames,
            "totalSeconds": totalSeconds, "events": events,
            "scope": "Device outputs; timestamps measured during sequential runs. Artifact writes occur after the pipeline timer stops."]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("comparison.json"))
    }

    static func deviceModel() -> String {
        var s = utsname(); uname(&s)
        return withUnsafePointer(to: &s.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"; case .fair: return "fair"; case .serious: return "serious"; case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    final class FootprintSampler: @unchecked Sendable {
        private(set) var peakMB: Double = 0
        private var timer: DispatchSourceTimer?
        func start() {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "gemx.bench.footprint"))
            t.schedule(deadline: .now(), repeating: .milliseconds(50))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let f = GemxBenchmark.footprintMB()
                if f > self.peakMB { self.peakMB = f }
            }
            t.resume(); timer = t
        }
        func stop() { timer?.cancel(); timer = nil }
    }
}

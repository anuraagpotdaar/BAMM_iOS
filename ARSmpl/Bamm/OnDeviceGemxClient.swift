import Foundation
import OnnxRuntimeBindings

final class OnDeviceGemxClient {

    struct RunResult {
        let motion: BvhMotion
        let bvh: String
        let joints77: [Double]

        let camera: CameraMotion
        let bvhIncam: String
        let jointsIncam: [Double]
        let kp2d: [Float]
        let bbxXys: [Float]
        let predX: [Float]
        let predCam: [Float]
        let timings: [String: Double]
        let sampledFrames: Int
        let poseLoadSeconds: Double
    }

    struct Finished {
        let motion: BvhMotion
        let bvh: String
        let joints77: [Double]
        let camera: CameraMotion
        let bvhIncam: String
        let jointsIncam: [Double]
    }

    private let env: ORTEnv
    private let modelsDir: URL
    let tables: GemxTables
    private var vitposeSess: ORTSession?
    private var vitposeCoreML: GemxVitPoseCoreML?
    private(set) var lastPoseLoadSeconds: Double = 0

    var preferredPoseBackend: GemxPoseBackend = .coreml
    private var denoiserSess: ORTSession?
    private var denoiserTier: GemxTier?
    private(set) var lastResult: RunResult?

    var vitposeThreads: Int = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount))
    var denoiserThreads: Int = 2

    init(modelsDirectory: URL? = nil) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let dir = modelsDirectory
            ?? Bundle.main.url(forResource: "Gemx", withExtension: nil)
            ?? Bundle.main.resourceURL?.appendingPathComponent("Gemx")
        guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("x_mean.f32").path) else {
            throw OnDeviceError.resourceMissing("Gemx/ (models + tables)")
        }
        modelsDir = dir
        tables = try GemxTables.load(from: dir)
    }

    func generate(videoURL: URL, options: GemxOptions = .defaults,
                  onProgress: (@Sendable (String) -> Void)? = nil) async throws -> RunResult {
        let reader = try await GemxVideoReader(url: videoURL, maxSide: options.maxSide)
        let result = try await Task.detached(priority: .userInitiated) { [self] in
            try self.run(reader: reader, options: options, onProgress: onProgress)
        }.value
        lastResult = result
        return result
    }

    func run(reader: GemxVideoReader, options: GemxOptions,
             onProgress: (@Sendable (String) -> Void)? = nil,
             oracleBoxes: [Float]? = nil, oracleKp2d: [Float]? = nil) throws -> RunResult {
        var T: [String: Double] = [:]
        let W = reader.info.width, H = reader.info.height
        let K = GemxPipeline.estimateK(width: W, height: H)
        let fps = reader.info.fps
        let resampling = options.resampleFps.map { abs(fps - $0) >= 1 } ?? false
        let step = GemxPipeline.frameStride(stride30: options.sampleStep, fps: fps, resampling: resampling)

        var t0 = Date()
        onProgress?("Detecting person…")
        let (n, idx, bbxSampled) = try detectBoxes(reader: reader, step: step, onProgress: onProgress)
        T["detect"] = Date().timeIntervalSince(t0)
        try Task.checkCancellation()
        guard n > 0 else { throw OnDeviceError.shapeMismatch("video decoded to 0 frames") }

        var bbxS = bbxSampled
        if let ob = oracleBoxes {
            bbxS = idx.map { SIMD3<Float>(ob[$0 * 3], ob[$0 * 3 + 1], ob[$0 * 3 + 2]) }
        }

        t0 = Date()
        let kpSampled: [Float]
        if let ok = oracleKp2d {
            var tmp = [Float](repeating: 0, count: idx.count * 77 * 3)
            for (k, i) in idx.enumerated() { for c in 0..<(77 * 3) { tmp[k * 231 + c] = ok[i * 231 + c] } }
            kpSampled = tmp
        } else {
            kpSampled = try runVitPose(reader: reader, idx: idx, boxes: bbxS, threads: vitposeThreads, backend: options.poseBackend,
                                       compute: options.poseCompute, flipTest: options.flipTest, poseModel: options.poseModel, onProgress: onProgress)
        }
        T["vitpose"] = Date().timeIntervalSince(t0)

        vitposeSess = nil; vitposeCoreML = nil
        try Task.checkCancellation()

        let tl = GemxPipeline.outputTimeline(n: n, idx: idx, fps: fps, resampleFps: options.resampleFps)
        let L = tl.L
        let kp2d = GemxPipeline.interpolate(sampled: kpSampled, positions: tl.positions, n: L, stride: 77 * 3)
        let bbxFlat = bbxS.flatMap { [$0.x, $0.y, $0.z] }
        let bbxXys = GemxPipeline.interpolate(sampled: bbxFlat, positions: tl.positions, n: L, stride: 3)

        t0 = Date()
        onProgress?("Denoising \(L) frames…")
        let (predX, predCam) = try denoise(kp2d: kp2d, bbxXys: bbxXys, K: K, L: L, tier: options.tier)
        T["denoise"] = Date().timeIntervalSince(t0)
        try Task.checkCancellation()

        t0 = Date()
        onProgress?("Building skeleton…")
        let out = finish(predX: predX, predCam: predCam, bbxXys: bbxXys, camera: GemxCamera(width: W, height: H, K: K), L: L, fps: tl.fps)
        T["post"] = Date().timeIntervalSince(t0)
        return RunResult(motion: out.motion, bvh: out.bvh, joints77: out.joints77,
                         camera: out.camera, bvhIncam: out.bvhIncam, jointsIncam: out.jointsIncam,
                         kp2d: kp2d, bbxXys: bbxXys, predX: predX, predCam: predCam, timings: T,
                         sampledFrames: idx.count, poseLoadSeconds: lastPoseLoadSeconds)
    }

    func detectBoxes(reader: GemxVideoReader, step: Int, onProgress: (@Sendable (String) -> Void)?) throws -> (n: Int, idx: [Int], bbxXys: [SIMD3<Float>]) {
        var raw: [SIMD4<Float>?] = []
        var sampledIdx: [Int] = []
        let est = max(reader.info.estimatedFrames, 1)
        var last = Date()
        let n = try reader.forEachFrame(wanted: { $0 % step == 0 }) { frame in
            try Task.checkCancellation()
            raw.append(GemxDetector.largestPerson(frame)); sampledIdx.append(frame.index)
            if Date().timeIntervalSince(last) > 0.5 {
                last = Date()
                onProgress?("Detecting person… \(min(frame.index + 1, est))/\(est)")
            }
            return true
        }

        if n > 0, sampledIdx.last != n - 1 {
            raw.append(raw.last ?? nil); sampledIdx.append(n - 1)
        }
        let W = reader.info.width, H = reader.info.height
        let filled = GemxPipeline.fillMissingBoxes(raw, width: W, height: H)
        let smoothed = GemxPipeline.smoothBoxes(filled)
        return (n, sampledIdx, GemxPipeline.xyxyToXys(smoothed, width: W, height: H))
    }

    func runVitPose(reader: GemxVideoReader, idx: [Int], boxes: [SIMD3<Float>], threads: Int,
                    backend: GemxPoseBackend = .coreml, compute: GemxPoseCompute = .auto, flipTest: Bool = false,
                    poseModel: String? = nil, onProgress: (@Sendable (String) -> Void)?) throws -> [Float] {
        let coreml: GemxVitPoseCoreML?
        lastPoseLoadSeconds = 0
        if backend == .coreml, GemxVitPoseCoreML.modelURL(in: modelsDir, preferred: poseModel) != nil {
            onProgress?("Preparing pose model…")
            coreml = try vitposeCoreMLModel(compute: compute, preferred: poseModel)
        } else {
            coreml = nil
        }
        let sess = try coreml == nil ? vitposeSession(threads: threads) : nil
        let cropCount = 3 * GemxConst.cropH * GemxConst.cropW
        let hmCount = GemxConst.numJoints * GemxConst.hmH * GemxConst.hmW
        let cropBuf = UnsafeMutablePointer<Float>.allocate(capacity: 2 * cropCount)
        let flipBuf = UnsafeMutablePointer<Float>.allocate(capacity: cropCount)
        let hmBuf = UnsafeMutablePointer<Float>.allocate(capacity: 2 * hmCount)
        let hmFlip = UnsafeMutablePointer<Float>.allocate(capacity: hmCount)
        defer { cropBuf.deallocate(); flipBuf.deallocate(); hmBuf.deallocate(); hmFlip.deallocate() }
        var out = [Float](repeating: 0, count: idx.count * 77 * 3)

        func runModel(_ crop: UnsafePointer<Float>, _ hm: UnsafeMutablePointer<Float>) throws {
            if let coreml {
                try coreml.run(crop: crop, into: hm)
            } else if let sess {
                let input = try ORTValue(tensorData: NSMutableData(bytes: crop, length: cropCount * 4), elementType: .float,
                                         shape: [1, 3, NSNumber(value: GemxConst.cropH), NSNumber(value: GemxConst.cropW)])
                let res = try sess.run(withInputs: ["imgs": input], outputNames: ["heatmaps"], runOptions: nil)
                guard let hmv = res["heatmaps"] else { throw OnDeviceError.ortError("vitpose: no heatmaps output") }
                let hmData = try hmv.tensorData() as Data
                guard hmData.count == hmCount * 4 else { throw OnDeviceError.shapeMismatch("vitpose heatmaps \(hmData.count / 4) floats") }
                hmData.withUnsafeBytes { hm.update(from: $0.bindMemory(to: Float.self).baseAddress!, count: hmCount) }
            }
        }
        final class ErrorBox: @unchecked Sendable { var error: Error? }
        let errBox = ErrorBox()
        let queue = DispatchQueue(label: "gemx.vitpose", qos: .userInitiated)
        var pending: DispatchWorkItem? = nil
        func infer(slot: Int) {
            let c = cropBuf + slot * cropCount, h = hmBuf + slot * hmCount
            do {
                try runModel(c, h)
                if flipTest {
                    GemxPipeline.flipCrop(c, into: flipBuf)
                    try runModel(flipBuf, hmFlip)
                    GemxPipeline.mergeFlippedHeatmaps(hm: h, flipped: hmFlip)
                }
            } catch { errBox.error = error }
        }
        func finishPending(_ k: Int) throws {
            pending?.wait(); pending = nil
            if let e = errBox.error { throw e }
            out.withUnsafeMutableBufferPointer { op in
                GemxPipeline.heatmapsToKp2d(hm: hmBuf + (k % 2) * hmCount, box: boxes[k], into: op.baseAddress! + k * 231)
            }
        }

        var k = 0
        let tStart = Date()
        var lastReport = Date()
        let wanted = Set(idx)
        try reader.forEachFrame(wanted: { wanted.contains($0) }) { frame in
            guard k < idx.count else { return false }
            guard frame.index == idx[k] else { return true }
            try Task.checkCancellation()
            let slot = k % 2
            GemxPipeline.cropForVitPose(frame: frame, box: boxes[k], into: cropBuf + slot * cropCount)
            if k >= 1 { try finishPending(k - 1) }
            let item = DispatchWorkItem { infer(slot: slot) }
            pending = item
            queue.async(execute: item)
            k += 1
            if Date().timeIntervalSince(lastReport) > 0.5 || k == idx.count {
                lastReport = Date()
                let per = Date().timeIntervalSince(tStart) / Double(k)
                let left = Int(per * Double(idx.count - k))
                onProgress?("2D pose \(k)/\(idx.count) · ~\(GemxProgress.mmss(left)) left")
            }
            return k < idx.count
        }
        if k >= 1 { try finishPending(k - 1) }
        guard k == idx.count else { throw OnDeviceError.shapeMismatch("vitpose ran on \(k)/\(idx.count) sampled frames") }
        return out
    }

    nonisolated(unsafe) static var denoiseWindow = 900
    nonisolated(unsafe) static var denoiseOverlap = 180

    func denoise(kp2d: [Float], bbxXys: [Float], K: [Float], L: Int, tier: GemxTier) throws -> (predX: [Float], predCam: [Float]) {
        let win = max(Self.denoiseWindow, 2 * Self.denoiseOverlap + 1)
        guard L > win else { return try denoiseWindow(kp2d: kp2d, bbxXys: bbxXys, K: K, L: L, tier: tier) }
        let ov = Self.denoiseOverlap
        var predX = [Float](repeating: 0, count: L * GemxConst.xDim), predCam = [Float](repeating: 0, count: L * 3)
        var s = 0
        while true {
            let e = min(s + win, L)
            let n = e - s
            let (px, pc) = try denoiseWindow(kp2d: Array(kp2d[(s * 231)..<(e * 231)]), bbxXys: Array(bbxXys[(s * 3)..<(e * 3)]), K: K, L: n, tier: tier)
            let ks = s == 0 ? 0 : s + ov / 2
            let ke = e == L ? L : e - ov / 2
            for f in ks..<ke {
                for c in 0..<GemxConst.xDim { predX[f * GemxConst.xDim + c] = px[(f - s) * GemxConst.xDim + c] }
                for c in 0..<3 { predCam[f * 3 + c] = pc[(f - s) * 3 + c] }
            }
            if e == L { break }
            s = e - ov
            try Task.checkCancellation()
        }
        return (predX, predCam)
    }

    private func denoiseWindow(kp2d: [Float], bbxXys: [Float], K: [Float], L: Int, tier: GemxTier) throws -> (predX: [Float], predCam: [Float]) {
        let sess = try denoiserSession(tier: tier, threads: denoiserThreads)
        var kFull = [Float](repeating: 0, count: L * 9)
        var angvel = [Float](repeating: 0, count: L * 6)
        for t in 0..<L {
            for i in 0..<9 { kFull[t * 9 + i] = K[i] }
            for i in 0..<6 { angvel[t * 6 + i] = GemxConst.camAngvelStatic[i] }
        }
        let Ln = NSNumber(value: L)
        let mask = GemxPipeline.bandMask(L: L)
        let inputs: [String: ORTValue] = [
            "obs":          try Self.floatTensor(kp2d, shape: [1, Ln, 77, 3]),
            "bbx_xys":      try Self.floatTensor(bbxXys, shape: [1, Ln, 3]),
            "K_fullimg":    try Self.floatTensor(kFull, shape: [1, Ln, 3, 3]),
            "f_imgseq":     try Self.floatTensor([Float](repeating: 0, count: L * 1024), shape: [1, Ln, 1024]),
            "f_cam_angvel": try Self.floatTensor(angvel, shape: [1, Ln, 6]),
            "attn_mask_u8": try Self.uint8Tensor(mask, shape: [Ln, Ln]),
        ]
        let res = try sess.run(withInputs: inputs, outputNames: ["pred_x", "pred_cam"], runOptions: nil)
        guard let px = res["pred_x"], let pc = res["pred_cam"] else { throw OnDeviceError.ortError("denoiser outputs missing") }
        let predX = try Self.floats(px), predCam = try Self.floats(pc)
        guard predX.count == L * GemxConst.xDim, predCam.count == L * 3 else {
            throw OnDeviceError.shapeMismatch("pred_x \(predX.count), pred_cam \(predCam.count) for L=\(L)")
        }
        return (predX, predCam)
    }

    func finish(predX: [Float], predCam: [Float], bbxXys: [Float], camera: GemxCamera, L: Int, fps: Double) -> Finished {
        let d = GemxPipeline.decodeX(predX: predX, L: L, tables: tables)
        let (go, transl) = GemxPipeline.globalFrameStatic(d)
        let rest = GemxPipeline.restSkeleton(identity: d.identity, scale: d.scale, tables: tables)
        let joints = GemxPipeline.fk(rest: rest, globalOrient: go, bodyPose: d.bodyPose, transl: transl, parents78: tables.parents78, L: L)
        let translG = GemxPipeline.ground(transl: transl, joints: joints, L: L)
        let frames = GemxPipeline.jointFrames(joints: joints, transl: transl, groundedTransl: translG, L: L)
        let bvh = GemxPipeline.toBvh(globalOrient: go, bodyPose: d.bodyPose, transl: translG, rest: rest, tables: tables, L: L, fps: fps)
        var grounded = joints
        let J = GemxConst.numJoints
        for f in 0..<L {
            for c in 0..<3 {
                let dc = translG[f * 3 + c] - transl[f * 3 + c]
                for k in 0..<J { grounded[(f * J + k) * 3 + c] += dc }
            }
        }
        let frameTime = 1.0 / (fps > 0 ? fps : 30)

        let translC = GemxPipeline.incamTransl(predCam: predCam, bbxXys: bbxXys, K: camera.K, L: L)
        let jointsC = GemxPipeline.fk(rest: rest, globalOrient: d.globalOrientIncam, bodyPose: d.bodyPose, transl: translC, parents78: tables.parents78, L: L)
        let cameraMotion = CameraMotion(frames: GemxPipeline.cameraFrames(joints: jointsC, L: L), frameTime: frameTime, camera: camera)
        let bvhC = GemxPipeline.toBvh(globalOrient: d.globalOrientIncam, bodyPose: d.bodyPose, transl: translC, rest: rest, tables: tables, L: L, fps: fps)
        return Finished(motion: BvhMotion(frames: frames, frameTime: frameTime), bvh: bvh, joints77: grounded,
                        camera: cameraMotion, bvhIncam: bvhC, jointsIncam: jointsC)
    }

    func runVitPoseOnCrop(_ crop: [Float]) throws -> [Float] {
        if preferredPoseBackend == .coreml, GemxVitPoseCoreML.modelURL(in: modelsDir) != nil {
            let m = try vitposeCoreMLModel()
            var hm = [Float](repeating: 0, count: GemxConst.numJoints * GemxConst.hmH * GemxConst.hmW)
            try crop.withUnsafeBufferPointer { cp in try hm.withUnsafeMutableBufferPointer { hp in try m.run(crop: cp.baseAddress!, into: hp.baseAddress!) } }
            return hm
        }
        let sess = try vitposeSession(threads: vitposeThreads)
        let input = try Self.floatTensor(crop, shape: [1, 3, NSNumber(value: GemxConst.cropH), NSNumber(value: GemxConst.cropW)])
        let res = try sess.run(withInputs: ["imgs": input], outputNames: ["heatmaps"], runOptions: nil)
        guard let hmv = res["heatmaps"] else { throw OnDeviceError.ortError("vitpose: no heatmaps output") }
        return try Self.floats(hmv)
    }

    private func vitposeCoreMLModel(compute: GemxPoseCompute = .auto, preferred: String? = nil) throws -> GemxVitPoseCoreML {
        if let m = vitposeCoreML, m.computeUnits == compute.mlComputeUnits, preferred == nil || m.name == preferred { return m }
        guard let url = GemxVitPoseCoreML.modelURL(in: modelsDir, preferred: preferred) else { throw OnDeviceError.resourceMissing("Gemx/vitpose_*.mlmodelc") }
        let t0 = Date()
        let m = try GemxVitPoseCoreML(modelURL: url, computeUnits: compute.mlComputeUnits)
        lastPoseLoadSeconds = Date().timeIntervalSince(t0)
        NSLog("[Gemx] CoreML VitPose \(m.name) loaded in %.2f s", lastPoseLoadSeconds)
        vitposeCoreML = m
        return m
    }

    private func vitposeSession(threads: Int) throws -> ORTSession {
        if let s = vitposeSess { return s }
        let s = try makeSession("vitpose_int8.onnx", threads: threads)
        vitposeSess = s
        return s
    }

    private func denoiserSession(tier: GemxTier, threads: Int) throws -> ORTSession {
        if let s = denoiserSess, denoiserTier == tier { return s }
        let s = try makeSession(tier.denoiserResource + "_u8.onnx", threads: threads)
        denoiserSess = s; denoiserTier = tier
        return s
    }

    private func makeSession(_ file: String, threads: Int) throws -> ORTSession {
        let url = modelsDir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw OnDeviceError.resourceMissing("Gemx/\(file)") }
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(Int32(threads))
        try opts.setGraphOptimizationLevel(.all)
        do {
            return try ORTSession(env: env, modelPath: url.path, sessionOptions: opts)
        } catch {
            throw OnDeviceError.ortError("load \(file): \(error.localizedDescription)")
        }
    }

    private static func floatTensor(_ data: [Float], shape: [NSNumber]) throws -> ORTValue {
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return try ORTValue(tensorData: NSMutableData(data: bytes), elementType: .float, shape: shape)
    }
    private static func uint8Tensor(_ data: [UInt8], shape: [NSNumber]) throws -> ORTValue {
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return try ORTValue(tensorData: NSMutableData(data: bytes), elementType: .uInt8, shape: shape)
    }
    private static func floats(_ v: ORTValue) throws -> [Float] {
        let data = try v.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

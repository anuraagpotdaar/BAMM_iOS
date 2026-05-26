import Foundation
import simd
import OnnxRuntimeBindings

enum OnDeviceError: Error, CustomStringConvertible {
    case resourceMissing(String)
    case ortError(String)
    case shapeMismatch(String)
    var description: String {
        switch self {
        case .resourceMissing(let n): return "On-device: bundled resource missing — \(n)"
        case .ortError(let m):        return "On-device: ONNX Runtime error — \(m)"
        case .shapeMismatch(let m):   return "On-device: shape mismatch — \(m)"
        }
    }
}

private enum BammConst {
    static let seqLen = 49
    static let blockSize = seqLen + 1
    static let numTokens = 512
    static let endId = 512
    static let maskPadId = 513
    static let resPadId = 512
    static let clipDim = 512
    static let codeDim = 512
    static let numQuantizers = 6
    static let dimPose = 272
    static let maskCondScale1: Float = 4
    static let maskCondScale2: Float = 3
    static let resCondScale: Float = 5
    static let numJoints = 22
    static let frameTime: TimeInterval = 1.0 / 20.0
}

final class OnDeviceBammClient {

    func generate(textPrompt: String, sampling: Sampling = .production) async throws -> BvhMotion {
        if sampling.precision != loadedPrecision {
            try reloadSessions(precision: sampling.precision)
        }
        return try await Task.detached(priority: .userInitiated) { [self] in
            try self.runSync(textPrompt: textPrompt, sampling: sampling)
        }.value
    }

    private func reloadSessions(precision: Precision) throws {
        self.clipSess = try Self.loadSession("bamm2_clip_text",            precision: precision, env: env)
        self.lenSess  = try Self.loadSession("bamm2_length_estimator",     precision: precision, env: env)
        self.maskSess = try Self.loadSession("bamm2_mask_transformer",     precision: precision, env: env)
        self.resSess  = try Self.loadSession("bamm2_residual_transformer", precision: precision, env: env)
        self.vqSess   = try Self.loadSession("bamm2_vq_decoder",           precision: precision, env: env)
        self.loadedPrecision = precision
    }

    private let env: ORTEnv
    private var clipSess: ORTSession
    private var lenSess:  ORTSession
    private var maskSess: ORTSession
    private var resSess:  ORTSession
    private var vqSess:   ORTSession
    private(set) var loadedPrecision: Precision

    private let tokenizer: ClipBpeTokenizer
    private let vqMean: [Float]
    private let vqStd:  [Float]
    private let resTokenEmbed: [[Float]]

    private static func loadSession(_ baseName: String, precision: Precision, env: ORTEnv) throws -> ORTSession {
        let suffix = precision == .fp32 ? "_fp32" : "_int8"
        let name = baseName + suffix
        let url = Bundle.main.url(forResource: name, withExtension: "onnx", subdirectory: "Bamm2")
            ?? Bundle.main.url(forResource: name, withExtension: "onnx")
        guard let url else { throw OnDeviceError.resourceMissing("\(name).onnx") }
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(2)
        try opts.setGraphOptimizationLevel(.basic)
        return try ORTSession(env: env, modelPath: url.path, sessionOptions: opts)
    }

    init(precision: Precision = .fp32) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env
        self.loadedPrecision = precision

        self.clipSess = try Self.loadSession("bamm2_clip_text",            precision: precision, env: env)
        self.lenSess  = try Self.loadSession("bamm2_length_estimator",     precision: precision, env: env)
        self.maskSess = try Self.loadSession("bamm2_mask_transformer",     precision: precision, env: env)
        self.resSess  = try Self.loadSession("bamm2_residual_transformer", precision: precision, env: env)
        self.vqSess   = try Self.loadSession("bamm2_vq_decoder",           precision: precision, env: env)

        self.tokenizer = try ClipBpeTokenizer()

        self.vqMean = try Self.loadFloatBlob(named: "vq_mean", ext: "f32", expectedCount: BammConst.dimPose)
        self.vqStd  = try Self.loadFloatBlob(named: "vq_std",  ext: "f32", expectedCount: BammConst.dimPose)

        var embeds: [[Float]] = []
        for i in 1..<BammConst.numQuantizers {
            let n = (BammConst.numTokens + 1) * BammConst.codeDim
            let blob = try Self.loadFloatBlob(named: "res_token_embed_\(i - 1)", ext: "f32", expectedCount: n)
            embeds.append(blob)
        }
        self.resTokenEmbed = embeds
    }

    private func runSync(textPrompt: String, sampling: Sampling) throws -> BvhMotion {
        let tokens = tokenizer.tokenize(textPrompt)
        let condVector = try runClip(tokens: tokens)

        let tokenLens: Int
        if sampling.motionLengthTokens > 0 {
            tokenLens = min(max(sampling.motionLengthTokens, 1), BammConst.seqLen)
        } else {
            let lenLogits = try runLength(cond: condVector)
            tokenLens = max(1, Self.sampleCategorical(softmax(lenLogits)))
        }

        var ids = [Int32](repeating: Int32(BammConst.maskPadId), count: BammConst.blockSize)
        let condIdxNone = [Int32](repeating: Int32(BammConst.maskPadId), count: BammConst.blockSize)

        ids = try genOneCfg(motionIds: ids, cond: condVector, condIdx: condIdxNone,
                            condScale: BammConst.maskCondScale1, predLen: true, sampling: sampling)

        var (paddedIds, predLen) = Self.padAfterEnd(ids)
        if predLen < paddedIds.count { paddedIds[predLen] = Int32(BammConst.endId) }

        let paddingMask = Self.buildPaddingMask(length: predLen, total: BammConst.blockSize)
        let numTokenMasked = max(1, Int((Float(predLen) * 0.5).rounded()))
        var scores = [Float](repeating: 0, count: BammConst.blockSize)
        for i in 0..<BammConst.blockSize where paddingMask[i] { scores[i] = 1e5 }
        let sorted = scores.enumerated().sorted { $0.element < $1.element || ($0.element == $1.element && $0.offset < $1.offset) }
        var ranks = [Int](repeating: 0, count: BammConst.blockSize)
        for (rank, item) in sorted.enumerated() { ranks[item.offset] = rank }
        var isMask = [Bool](repeating: false, count: BammConst.blockSize)
        for i in 0..<BammConst.blockSize { isMask[i] = ranks[i] < numTokenMasked }
        var consPos = [Bool](repeating: false, count: BammConst.blockSize)
        for i in 0..<BammConst.blockSize {
            consPos[i] = (!isMask[i] && !paddingMask[i]) || paddedIds[i] == Int32(BammConst.endId)
        }
        var condIdx2 = [Int32](repeating: Int32(BammConst.maskPadId), count: BammConst.blockSize)
        for i in 0..<BammConst.blockSize where consPos[i] { condIdx2[i] = paddedIds[i] }

        ids = try genOneCfg(motionIds: paddedIds, cond: condVector, condIdx: condIdx2,
                            condScale: BammConst.maskCondScale2, predLen: false, sampling: sampling)
        for i in 0..<BammConst.blockSize where consPos[i] { ids[i] = condIdx2[i] }

        let allQids = try resGenerate(motionIds: ids, cond: condVector, tokenLens: tokenLens, sampling: sampling)

        let motion = try runVqDecoder(indices: allQids)
        let tFrames = motion.count / BammConst.dimPose
        var denorm = [Float](repeating: 0, count: motion.count)
        for f in 0..<tFrames {
            for d in 0..<BammConst.dimPose {
                let i = f * BammConst.dimPose + d
                denorm[i] = motion[i] * vqStd[d] + vqMean[d]
            }
        }

        let lengthFrames = min(tFrames, tokenLens * 4)
        let frames = Self.motion272ToWorldJoints(denorm, totalFrames: tFrames, useFrames: lengthFrames)

        return BvhMotion(frames: frames, frameTime: BammConst.frameTime)
    }

    private func runClip(tokens: [Int32]) throws -> [Float] {
        let shape: [NSNumber] = [1, NSNumber(value: ClipBpeTokenizer.contextLength)]
        let input = try makeInt32Tensor(tokens, shape: shape)
        let out = try clipSess.run(withInputs: ["token_ids": input], outputNames: ["features"], runOptions: nil)
        guard let v = out["features"], let arr = try? readFloatTensor(v) else { throw OnDeviceError.ortError("clip output") }
        guard arr.count == BammConst.clipDim else { throw OnDeviceError.shapeMismatch("clip features \(arr.count)") }
        return arr
    }

    private func runLength(cond: [Float]) throws -> [Float] {
        let input = try makeFloat32Tensor(cond, shape: [1, NSNumber(value: BammConst.clipDim)])
        let out = try lenSess.run(withInputs: ["text_emb": input], outputNames: ["len_logits"], runOptions: nil)
        guard let v = out["len_logits"], let arr = try? readFloatTensor(v) else { throw OnDeviceError.ortError("len output") }
        return arr
    }

    private func genOneCfg(motionIds: [Int32], cond: [Float], condIdx: [Int32],
                           condScale: Float, predLen: Bool, sampling: Sampling) throws -> [Int32] {
        var ids = motionIds
        let zerosCond = [Float](repeating: 0, count: BammConst.clipDim)
        let ntoken = BammConst.numTokens + 1
        // trans_forward prepends cond → output time dim is motionIds.count + 1, not BLOCK_SIZE.
        let tCol = motionIds.count + 1
        let invT = max(1e-3, 1.0 / sampling.temperature)
        for k in 0..<BammConst.seqLen {
            let logitsCond   = try runMask(motionIds: ids, cond: cond,      condIdx: condIdx)
            let logitsUncond = try runMask(motionIds: ids, cond: zerosCond, condIdx: condIdx)
            var logitsK = [Float](repeating: 0, count: ntoken)
            for t in 0..<ntoken {
                let i = t * tCol + k
                logitsK[t] = logitsUncond[i] + (logitsCond[i] - logitsUncond[i]) * condScale
            }
            let effectiveLen = predLen ? ntoken : (ntoken - 1)
            var sliced = Array(logitsK.prefix(effectiveLen))
            if sampling.temperature != 1.0 {
                for i in 0..<sliced.count { sliced[i] *= invT }
            }
            if sampling.topPMask < 1.0 {
                sliced = Self.topPFilter(sliced, threshold: sampling.topPMask)
            }
            if sampling.deterministic {
                var bestIdx = 0
                var bestVal = sliced[0]
                for i in 1..<sliced.count where sliced[i] > bestVal { bestVal = sliced[i]; bestIdx = i }
                ids[k] = Int32(bestIdx)
            } else {
                let probs = softmax(sliced)
                ids[k] = Int32(Self.sampleCategorical(probs))
            }
        }
        return ids
    }

    private func runMask(motionIds: [Int32], cond: [Float], condIdx: [Int32]) throws -> [Float] {
        let mShape: [NSNumber] = [1, NSNumber(value: motionIds.count)]
        let cShape: [NSNumber] = [1, NSNumber(value: BammConst.clipDim)]
        let mt = try makeInt64Tensor(motionIds.map(Int64.init), shape: mShape)
        let ct = try makeFloat32Tensor(cond, shape: cShape)
        let cit = try makeInt64Tensor(condIdx.map(Int64.init), shape: mShape)
        let out = try maskSess.run(withInputs: [
            "motion_ids": mt, "cond_vector": ct, "cond_idx": cit,
        ], outputNames: ["logits"], runOptions: nil)
        guard let v = out["logits"], let arr = try? readFloatTensor(v) else { throw OnDeviceError.ortError("mask logits") }
        return arr
    }

    private func resGenerate(motionIds: [Int32], cond: [Float], tokenLens: Int, sampling: Sampling) throws -> [Int32] {
        let T = motionIds.count
        var paddingMask = [Bool](repeating: false, count: T)
        for i in 0..<T where i >= tokenLens { paddingMask[i] = true }
        var q0 = motionIds.map { id -> Int32 in
            if Int(id) > BammConst.resPadId || Int(id) == BammConst.endId { return Int32(BammConst.resPadId) }
            return id
        }
        for i in 0..<T where paddingMask[i] { q0[i] = Int32(BammConst.resPadId) }

        var allQ: [[Int32]] = [q0]
        var historySum = [Float](repeating: 0, count: T * BammConst.codeDim)

        for i in 1..<BammConst.numQuantizers {
            let prev = allQ.last!
            let te = resTokenEmbed[i - 1]
            for t in 0..<T {
                let idx = Int(prev[t])
                let off = idx * BammConst.codeDim
                let base = t * BammConst.codeDim
                for d in 0..<BammConst.codeDim {
                    historySum[base + d] += te[off + d]
                }
            }

            let qids = [Int64(i)]
            let zerosCond = [Float](repeating: 0, count: BammConst.clipDim)
            let mc = try makeFloat32Tensor(historySum, shape: [1, NSNumber(value: T), NSNumber(value: BammConst.codeDim)])
            // padding_mask is int64 in the re-exported residual ONNX — Swift ORT binding lacks .bool.
            let pmInts: [Int64] = paddingMask.map { Int64($0 ? 1 : 0) }
            let pm = try makeInt64Tensor(pmInts, shape: [1, NSNumber(value: T)])
            let qt = try makeInt64Tensor(qids, shape: [1])

            let lc = try resSess.run(withInputs: [
                "motion_codes": mc, "qids": qt,
                "cond_vector": try makeFloat32Tensor(cond, shape: [1, NSNumber(value: BammConst.clipDim)]),
                "padding_mask": pm,
            ], outputNames: ["logits"], runOptions: nil)["logits"].flatMap { try? readFloatTensor($0) }
            let lu = try resSess.run(withInputs: [
                "motion_codes": mc, "qids": qt,
                "cond_vector": try makeFloat32Tensor(zerosCond, shape: [1, NSNumber(value: BammConst.clipDim)]),
                "padding_mask": pm,
            ], outputNames: ["logits"], runOptions: nil)["logits"].flatMap { try? readFloatTensor($0) }
            guard let lcArr = lc, let luArr = lu else { throw OnDeviceError.ortError("res forward") }

            let ntoken = BammConst.numTokens + 1
            let invT = max(1e-3, 1.0 / sampling.temperature)
            var sampled = [Int32](repeating: 0, count: T)
            for t in 0..<T {
                var logitsT = [Float](repeating: 0, count: ntoken)
                for tk in 0..<ntoken {
                    let idx = tk * T + t
                    logitsT[tk] = luArr[idx] + (lcArr[idx] - luArr[idx]) * BammConst.resCondScale
                }
                if sampling.temperature != 1.0 {
                    for i in 0..<ntoken { logitsT[i] *= invT }
                }
                let kept = Self.topPFilter(logitsT, threshold: sampling.topPRes)
                if sampling.deterministic {
                    var bestIdx = 0
                    var bestVal = kept[0]
                    for i in 1..<kept.count where kept[i] > bestVal { bestVal = kept[i]; bestIdx = i }
                    sampled[t] = Int32(bestIdx)
                } else {
                    let probs = softmax(kept)
                    sampled[t] = Int32(Self.sampleCategorical(probs))
                }
            }
            for t in 0..<T where paddingMask[t] { sampled[t] = Int32(BammConst.resPadId) }
            allQ.append(sampled)
        }

        // resPadId → -1 for VQ: ResidualVQ.get_codes_from_indices masks -1 to zero.
        var out = [Int32](repeating: 0, count: T * BammConst.numQuantizers)
        for t in 0..<T {
            for q in 0..<BammConst.numQuantizers {
                let v = allQ[q][t]
                out[t * BammConst.numQuantizers + q] = (Int(v) == BammConst.resPadId) ? -1 : v
            }
        }
        return out
    }

    private func runVqDecoder(indices: [Int32]) throws -> [Float] {
        let T = indices.count / BammConst.numQuantizers
        let shape: [NSNumber] = [1, NSNumber(value: T), NSNumber(value: BammConst.numQuantizers)]
        let input = try makeInt64Tensor(indices.map(Int64.init), shape: shape)
        let out = try vqSess.run(withInputs: ["indices": input], outputNames: ["motion"], runOptions: nil)
        guard let v = out["motion"], let arr = try? readFloatTensor(v) else { throw OnDeviceError.ortError("vq output") }
        return arr
    }

    private func makeFloat32Tensor(_ data: [Float], shape: [NSNumber]) throws -> ORTValue {
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return try ORTValue(tensorData: NSMutableData(data: bytes), elementType: .float, shape: shape)
    }
    private func makeInt32Tensor(_ data: [Int32], shape: [NSNumber]) throws -> ORTValue {
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return try ORTValue(tensorData: NSMutableData(data: bytes), elementType: .int32, shape: shape)
    }
    private func makeInt64Tensor(_ data: [Int64], shape: [NSNumber]) throws -> ORTValue {
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return try ORTValue(tensorData: NSMutableData(data: bytes), elementType: .int64, shape: shape)
    }
    private func readFloatTensor(_ v: ORTValue) throws -> [Float] {
        let data = try v.tensorData() as Data
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
    }

    private func softmax(_ x: [Float]) -> [Float] {
        let m = x.max() ?? 0
        let e = x.map { Foundation.exp($0 - m) }
        let s = e.reduce(0, +)
        return s > 0 ? e.map { $0 / s } : Array(repeating: 1.0 / Float(x.count), count: x.count)
    }

    private static func topPFilter(_ logits: [Float], threshold: Float) -> [Float] {
        guard threshold < 1.0 else { return logits }
        let order = logits.indices.sorted { logits[$0] > logits[$1] }
        let sortedLogits = order.map { logits[$0] }
        let m = sortedLogits.max() ?? 0
        var exps = sortedLogits.map { Foundation.exp($0 - m) }
        let s = exps.reduce(0, +)
        if s > 0 { for i in exps.indices { exps[i] /= s } }
        var cum: Float = 0
        var keep = [Bool](repeating: false, count: logits.count)
        for (rank, idx) in order.enumerated() {
            cum += exps[rank]
            keep[idx] = rank == 0 || (cum < threshold)
        }
        var out = [Float](repeating: -Float.infinity, count: logits.count)
        for i in logits.indices where keep[i] { out[i] = logits[i] }
        return out
    }

    private static func sampleCategorical(_ probs: [Float]) -> Int {
        let u = Float.random(in: 0..<1)
        var c: Float = 0
        for (i, p) in probs.enumerated() {
            c += p
            if u < c { return i }
        }
        return probs.count - 1
    }

    private static func padAfterEnd(_ xsIn: [Int32]) -> ([Int32], Int) {
        var xs = xsIn
        let n = xs.count
        if Int(xs[0]) >= BammConst.endId {
            xs[0] = 0
            xs[1] = Int32(BammConst.endId)
        }
        var predLen = n + 1
        for i in 0..<n {
            if Int(xs[i]) >= BammConst.endId { predLen = i; break }
        }
        if predLen >= n { predLen = n }
        for i in predLen..<n { xs[i] = Int32(BammConst.maskPadId) }
        return (xs, predLen)
    }

    private static func buildPaddingMask(length: Int, total: Int) -> [Bool] {
        var m = [Bool](repeating: false, count: total)
        for i in length..<total { m[i] = true }
        return m
    }

    // motion272 layout: [0,2) root vel xz, [2,8) heading 6D, [8,74) joint xyz heading-aligned.
    // headings[f] = local→world (our column-major rel is already the transpose of Python's
    // row-major matrix; post-multiplying gives inv_heading directly — apply without transpose).
    private static func motion272ToWorldJoints(_ motion: [Float], totalFrames: Int, useFrames: Int) -> [JointFrame] {
        let nF = useFrames
        let dim = BammConst.dimPose
        let nJ = BammConst.numJoints

        var headings = [simd_float3x3](repeating: matrix_identity_float3x3, count: totalFrames)
        for f in 0..<totalFrames {
            let off = f * dim + 2
            let a1 = simd_float3(motion[off],   motion[off+1], motion[off+2])
            let a2 = simd_float3(motion[off+3], motion[off+4], motion[off+5])
            let b1 = simd_normalize(a1)
            let b2 = simd_normalize(a2 - simd_dot(b1, a2) * b1)
            let b3 = simd_cross(b1, b2)
            let rel = simd_float3x3(columns: (b1, b2, b3))
            if f == 0 { headings[0] = rel } else { headings[f] = simd_mul(headings[f-1], rel) }
        }

        var rootT = [simd_float3](repeating: .zero, count: totalFrames)
        var accum = simd_float3.zero
        for f in 0..<totalFrames {
            let off = f * dim
            var velLocal = simd_float3(motion[off], 0, motion[off+1])
            if f >= 1 { velLocal = simd_mul(headings[f-1], velLocal) }
            accum += velLocal
            let h = motion[f * dim + 8 + 1]
            rootT[f] = simd_float3(accum.x, h, accum.z)
        }

        var out: [JointFrame] = []
        out.reserveCapacity(nF)
        for f in 0..<nF {
            var xyz = [Float](repeating: 0, count: nJ * 3)
            let H = headings[f]
            let t = rootT[f]
            let posOff = f * dim + 8
            for j in 0..<nJ {
                let local = simd_float3(motion[posOff + j*3],
                                        motion[posOff + j*3 + 1],
                                        motion[posOff + j*3 + 2])
                let world = simd_mul(H, local) + t
                xyz[j*3]     = world.x
                xyz[j*3 + 1] = world.y
                xyz[j*3 + 2] = world.z
            }
            out.append(JointFrame(xyz))
        }
        return out
    }

    private static func loadFloatBlob(named: String, ext: String, expectedCount: Int) throws -> [Float] {
        let url = Bundle.main.url(forResource: named, withExtension: ext, subdirectory: "Bamm2")
            ?? Bundle.main.url(forResource: named, withExtension: ext)
        guard let url else { throw OnDeviceError.resourceMissing("\(named).\(ext)") }
        let data = try Data(contentsOf: url)
        let n = data.count / MemoryLayout<Float>.size
        guard n == expectedCount else {
            throw OnDeviceError.shapeMismatch("\(named).\(ext) has \(n) floats, expected \(expectedCount)")
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(n)) }
    }
}

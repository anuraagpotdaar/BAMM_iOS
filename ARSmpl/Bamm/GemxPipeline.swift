import Foundation
import simd

enum GemxConst {
    static let numJoints = 77
    static let hmH = 64, hmW = 48
    static let cropH = 256, cropW = 192
    static let xDim = 585
    static let window = 120
    static let vpMean: [Float] = [0.485, 0.456, 0.406]
    static let vpStd: [Float] = [0.229, 0.224, 0.225]
    static let camAngvelStatic: [Float] = [1, 0, 0, 0, 1, 0]

    static var humanml22: [Int] { SkeletonTopology.humanml22 }

    static let bodyPoseRange = 0..<456
    static let identityRange = 456..<501
    static let scaleRange = 501..<570
    static let globalOrientRange = 570..<576
    static let globalOrientGvRange = 576..<582
    static let localTranslVelRange = 582..<585
}

struct GemxTables {
    let xMean: [Float]
    let xStd: [Float]
    let lutJ1: [Float]
    let lutA: [Float]
    let lutGrid: [Float]
    let lutLUT: [Float]
    let parents78: [Int]
    let names78: [String]

    static func load(from dir: URL) throws -> GemxTables {
        func f32(_ name: String, _ n: Int) throws -> [Float] {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { throw OnDeviceError.resourceMissing("Gemx/\(name)") }
            let count = data.count / 4
            guard count == n else { throw OnDeviceError.shapeMismatch("\(name) has \(count) floats, expected \(n)") }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let parentsURL = dir.appendingPathComponent("joint_parents.i32")
        guard let pdata = try? Data(contentsOf: parentsURL) else { throw OnDeviceError.resourceMissing("Gemx/joint_parents.i32") }
        let parents = pdata.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }.map { Int($0) }
        guard parents.count == 78 else { throw OnDeviceError.shapeMismatch("joint_parents.i32 has \(parents.count) entries") }
        let namesURL = dir.appendingPathComponent("joint_names.txt")
        let names = (try? String(contentsOf: namesURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map { String($0) } ?? []
        guard names.count == 78 else { throw OnDeviceError.resourceMissing("Gemx/joint_names.txt (78 names)") }
        let J = GemxConst.numJoints
        return GemxTables(
            xMean: try f32("x_mean.f32", GemxConst.xDim),
            xStd: try f32("x_std.f32", GemxConst.xDim),
            lutJ1: try f32("lut_J1.f32", J * 3),
            lutA: try f32("lut_A.f32", 45 * J * 3),
            lutGrid: try f32("lut_grid.f32", 41),
            lutLUT: try f32("lut_LUT.f32", 69 * 41 * J * 3),
            parents78: parents,
            names78: names)
    }
}

struct GemxCamera: Sendable, Equatable {
    let width: Int
    let height: Int

    let K: [Float]
    var fx: Float { K[0] }
    var fy: Float { K[4] }
    var cx: Float { K[2] }
    var cy: Float { K[5] }
    var aspect: Double { Double(width) / Double(max(height, 1)) }

    static func estimated(width: Int, height: Int) -> GemxCamera {
        GemxCamera(width: width, height: height, K: GemxPipeline.estimateK(width: width, height: height))
    }
}

struct CameraMotion: Sendable {
    let id = UUID()
    let frames: [JointFrame]
    let frameTime: TimeInterval
    let camera: GemxCamera
}

struct GemxDecoded {
    let L: Int
    let bodyPose: [Double]
    let globalOrientGv: [Double]
    let globalOrientIncam: [Double]
    let localTranslVel: [Double]
    let identity: [Float]
    let scale: [Float]
}

enum GemxPipeline {

    static func estimateK(width: Int, height: Int) -> [Float] {
        let f = Float(max(width, height))
        return [f, 0, Float(width) / 2, 0, f, Float(height) / 2, 0, 0, 1]
    }

    static func sampleIndices(n: Int, step: Int) -> [Int] {
        guard n > 0 else { return [] }
        var idx = Array(stride(from: 0, to: n, by: max(step, 1)))
        if idx.last != n - 1 { idx.append(n - 1) }
        return idx
    }

    static func fillMissingBoxes(_ boxes: [SIMD4<Float>?], width: Int, height: Int) -> [SIMD4<Float>] {
        let n = boxes.count
        let valid = boxes.indices.filter { boxes[$0] != nil }
        guard !valid.isEmpty else {
            return [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, Float(width - 1), Float(height - 1)), count: n)
        }
        var out = [SIMD4<Float>](repeating: .zero, count: n)
        var k = 0
        for i in 0..<n {
            if let b = boxes[i] { out[i] = b; continue }
            while k + 1 < valid.count && valid[k + 1] <= i { k += 1 }
            if i < valid[0] { out[i] = boxes[valid[0]]! }
            else if k + 1 >= valid.count { out[i] = boxes[valid[valid.count - 1]]! }
            else {
                let i0 = valid[k], i1 = valid[k + 1]
                let a = Float(i - i0) / Float(i1 - i0)
                out[i] = boxes[i0]! + (boxes[i1]! - boxes[i0]!) * a
            }
        }
        return out
    }

    static func smoothBoxes(_ b: [SIMD4<Float>], window: Int = 3) -> [SIMD4<Float>] {
        let n = b.count
        guard n > window else { return b }
        let pad = window / 2
        var out = [SIMD4<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            var acc = SIMD4<Float>.zero
            for k in -pad...(window - 1 - pad) {
                acc += b[min(max(i + k, 0), n - 1)]
            }
            out[i] = acc / Float(window)
        }
        return out
    }

    static func xyxyToXys(_ b: [SIMD4<Float>], width: Int, height: Int, enlarge: Float = 1.2) -> [SIMD3<Float>] {
        let W = Float(width - 1), H = Float(height - 1)
        let ar: Float = 192.0 / 256.0
        return b.map { box in
            let x1 = min(max(box.x, 0), W), x2 = min(max(box.z, 0), W)
            let y1 = min(max(box.y, 0), H), y2 = min(max(box.w, 0), H)
            let cx = (x1 + x2) / 2, cy = (y1 + y2) / 2
            var w = x2 - x1, h = y2 - y1
            if w > ar * h { h = w / ar }
            if w < ar * h { w = h * ar }
            return SIMD3<Float>(cx, cy, max(h, w) * enlarge)
        }
    }

    static func cropForVitPose(frame: GemxFrame, box: SIMD3<Float>, into out: UnsafeMutablePointer<Float>) {
        let cx = box.x, cy = box.y, s = box.z
        let hs = s / 2
        let step = s / 255
        let W = frame.width, H = frame.height, rb = frame.bytesPerRow
        let data = frame.data
        let plane = GemxConst.cropH * GemxConst.cropW
        var inv = [Float](repeating: 0, count: 3)
        for c in 0..<3 { inv[c] = 1 / (255 * GemxConst.vpStd[c]) }
        for v in 0..<GemxConst.cropH {
            let sy = cy - hs + Float(v) * step
            let y0f = sy.rounded(.down)
            let fy = sy - y0f
            let y0 = Int(y0f)
            let y1 = y0 + 1
            let y0ok = y0 >= 0 && y0 < H, y1ok = y1 >= 0 && y1 < H
            for u in 0..<GemxConst.cropW {
                let sx = cx - hs + Float(u + 32) * step
                let x0f = sx.rounded(.down)
                let fx = sx - x0f
                let x0 = Int(x0f)
                let x1 = x0 + 1
                let x0ok = x0 >= 0 && x0 < W, x1ok = x1 >= 0 && x1 < W
                let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                let o = v * GemxConst.cropW + u
                for c in 0..<3 {
                    var acc: Float = 0
                    if y0ok {
                        let row = data + y0 * rb
                        if x0ok { acc += w00 * Float(row[x0 * 4 + c]) }
                        if x1ok { acc += w10 * Float(row[x1 * 4 + c]) }
                    }
                    if y1ok {
                        let row = data + y1 * rb
                        if x0ok { acc += w01 * Float(row[x0 * 4 + c]) }
                        if x1ok { acc += w11 * Float(row[x1 * 4 + c]) }
                    }

                    out[c * plane + o] = acc * inv[c] - GemxConst.vpMean[c] / GemxConst.vpStd[c]
                }
            }
        }
    }

    static let flipIndex: [Int] = {
        var f = Array(0..<GemxConst.numJoints)
        func swap(_ a: Int, _ b: Int) { f[a] = b; f[b] = a }
        swap(9, 10)
        for k in 11...38 { swap(k, k + 28) }
        for k in 67...71 { swap(k, k + 5) }
        return f
    }()

    static func flipCrop(_ src: UnsafePointer<Float>, into dst: UnsafeMutablePointer<Float>) {
        let H = GemxConst.cropH, W = GemxConst.cropW
        for c in 0..<3 {
            for v in 0..<H {
                let s = src + (c * H + v) * W, d = dst + (c * H + v) * W
                for u in 0..<W { d[u] = s[W - 1 - u] }
            }
        }
    }

    static func mergeFlippedHeatmaps(hm: UnsafeMutablePointer<Float>, flipped: UnsafePointer<Float>) {
        let Hh = GemxConst.hmH, Hw = GemxConst.hmW
        for j in 0..<GemxConst.numJoints {
            let fj = flipIndex[j]
            for y in 0..<Hh {
                let a = hm + (j * Hh + y) * Hw, b = flipped + (fj * Hh + y) * Hw
                for x in 0..<Hw { a[x] = 0.5 * (a[x] + b[Hw - 1 - x]) }
            }
        }
    }

    static func heatmapsToKp2d(hm: UnsafePointer<Float>, box: SIMD3<Float>, into out: UnsafeMutablePointer<Float>) {
        let Hh = GemxConst.hmH, Hw = GemxConst.hmW
        let cx = box.x, cy = box.y, s = box.z
        let sw = s * 24 / 32, sh = s
        for j in 0..<GemxConst.numJoints {
            let base = hm + j * Hh * Hw
            var bi = 0
            var bv = base[0]
            for i in 1..<(Hh * Hw) where base[i] > bv { bv = base[i]; bi = i }
            var px = Float(bi % Hw), py = Float(bi / Hw)
            let x = bi % Hw, y = bi / Hw
            if x > 1 && x < Hw - 1 {
                let d = base[y * Hw + x + 1] - base[y * Hw + x - 1]
                px += (d > 0 ? 0.25 : d < 0 ? -0.25 : 0)
            }
            if y > 1 && y < Hh - 1 {
                let d = base[(y + 1) * Hw + x] - base[(y - 1) * Hw + x]
                py += (d > 0 ? 0.25 : d < 0 ? -0.25 : 0)
            }
            out[j * 3]     = px / Float(Hw) * sw + cx - sw / 2
            out[j * 3 + 1] = py / Float(Hh) * sh + cy - sh / 2
            out[j * 3 + 2] = bv
        }
    }

    static func interpolate(sampled: [Float], positions: [Double], n: Int, stride: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n * stride)
        sampled.withUnsafeBufferPointer { fp in
            out.withUnsafeMutableBufferPointer { op in
                GemxMath.interp(xp: positions, fp: fp, stride: stride, n: n, into: op)
            }
        }
        return out
    }
    static func interpolate(sampled: [Float], idx: [Int], n: Int, stride: Int) -> [Float] {
        interpolate(sampled: sampled, positions: idx.map(Double.init), n: n, stride: stride)
    }

    static func outputTimeline(n: Int, idx: [Int], fps: Double, resampleFps: Double?) -> (L: Int, positions: [Double], fps: Double) {
        guard let target = resampleFps, fps > 0, abs(fps - target) >= 1 else {
            return (n, idx.map(Double.init), fps)
        }
        let L = max(1, Int((Double(n - 1) * target / fps).rounded()) + 1)
        return (L, idx.map { Double($0) * target / fps }, target)
    }

    static func frameStride(stride30: Int, fps: Double, resampling: Bool) -> Int {
        guard resampling, fps > 0 else { return max(1, stride30) }
        return max(1, Int((Double(max(1, stride30)) * fps / 30).rounded()))
    }

    static func bandMask(L: Int, maxLen: Int = GemxConst.window) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: L * L)
        guard L > maxLen else { return m }
        for i in 0..<(L * L) { m[i] = 1 }
        let eff = min(maxLen, L)
        for i in 0..<L {
            let lo = max(0, i - maxLen / 2), hi = min(L, i + maxLen / 2)
            let a = min(L - eff, lo), b = max(eff, hi)
            for j in a..<b { m[i * L + j] = 0 }
        }
        return m
    }

    static func decodeX(predX: [Float], L: Int, tables: GemxTables) -> GemxDecoded {
        let D = GemxConst.xDim
        var x = [Double](repeating: 0, count: L * D)
        for t in 0..<L {
            for d in 0..<D { x[t * D + d] = Double(predX[t * D + d]) * Double(tables.xStd[d]) + Double(tables.xMean[d]) }
        }
        var bodyPose = [Double](repeating: 0, count: L * 228)
        var gv = [Double](repeating: 0, count: L * 3)
        var gIncam = [Double](repeating: 0, count: L * 3)
        var ltv = [Double](repeating: 0, count: L * 3)
        x.withUnsafeBufferPointer { xp in
            for t in 0..<L {
                let o = t * D
                for j in 0..<76 {
                    let rv = GemxMath.matrixToRotvec(GemxMath.r6dToMatrix(xp, o + j * 6))
                    bodyPose[t * 228 + j * 3] = rv.x; bodyPose[t * 228 + j * 3 + 1] = rv.y; bodyPose[t * 228 + j * 3 + 2] = rv.z
                }
                let g = GemxMath.matrixToRotvec(GemxMath.r6dToMatrix(xp, o + GemxConst.globalOrientRange.lowerBound))
                gIncam[t * 3] = g.x; gIncam[t * 3 + 1] = g.y; gIncam[t * 3 + 2] = g.z
                let v = GemxMath.matrixToRotvec(GemxMath.r6dToMatrix(xp, o + GemxConst.globalOrientGvRange.lowerBound))
                gv[t * 3] = v.x; gv[t * 3 + 1] = v.y; gv[t * 3 + 2] = v.z
                for c in 0..<3 { ltv[t * 3 + c] = xp[o + GemxConst.localTranslVelRange.lowerBound + c] }
            }
        }
        var identity = [Float](repeating: 0, count: 45)
        for i in 0..<45 { identity[i] = Float(x[GemxConst.identityRange.lowerBound + i]) }
        var scale = [Float](repeating: 0, count: 69)
        for i in 0..<69 { scale[i] = Float(x[GemxConst.scaleRange.lowerBound + i]) }
        scale[0] = min(max(scale[0], 0.7), 1.0)
        return GemxDecoded(L: L, bodyPose: bodyPose, globalOrientGv: gv, globalOrientIncam: gIncam,
                           localTranslVel: ltv, identity: identity, scale: scale)
    }

    static func globalFrameStatic(_ d: GemxDecoded) -> (globalOrient: [Double], transl: [Double]) {
        let L = d.L
        var go = d.globalOrientGv
        var transl = [Double](repeating: 0, count: L * 3)
        var acc = SIMD3<Double>.zero
        for t in 0..<L {
            var g = SIMD3<Double>(go[t * 3], go[t * 3 + 1], go[t * 3 + 2])
            if simd_length(g) < 1e-5 { g = .zero; go[t * 3] = 0; go[t * 3 + 1] = 0; go[t * 3 + 2] = 0 }
            transl[t * 3] = acc.x; transl[t * 3 + 1] = acc.y; transl[t * 3 + 2] = acc.z
            let v = SIMD3<Double>(d.localTranslVel[t * 3], d.localTranslVel[t * 3 + 1], d.localTranslVel[t * 3 + 2])
            acc += GemxMath.rotvecToMatrix(g) * v
        }
        return (go, transl)
    }

    static func restSkeleton(identity: [Float], scale: [Float], tables: GemxTables) -> [Double] {
        let J3 = GemxConst.numJoints * 3
        var out = [Double](repeating: 0, count: J3)
        for i in 0..<J3 { out[i] = Double(tables.lutJ1[i]) }
        for i in 0..<45 {
            let a = Double(identity[i])
            for j in 0..<J3 { out[j] += a * Double(tables.lutA[i * J3 + j]) }
        }
        let g0 = Double(tables.lutGrid[0]), gLast = Double(tables.lutGrid[40])
        let dgrid = Double(tables.lutGrid[1]) - g0
        for k in 1..<69 {
            let v = min(max(Double(scale[k]), g0), gLast)
            let gi = min(Int((v - g0) / dgrid), 39)
            let t = (v - Double(tables.lutGrid[gi])) / dgrid
            let b0 = (k * 41 + gi) * J3, b1 = (k * 41 + gi + 1) * J3
            for j in 0..<J3 { out[j] += (1 - t) * Double(tables.lutLUT[b0 + j]) + t * Double(tables.lutLUT[b1 + j]) }
        }
        let s0 = Double(scale[0])
        for j in 0..<J3 { out[j] *= s0 }
        return out
    }

    static func fk(rest: [Double], globalOrient: [Double], bodyPose: [Double], transl: [Double], parents78: [Int], L: Int) -> [Double] {
        let J = GemxConst.numJoints
        var joints = [Double](repeating: 0, count: L * J * 3)
        var G = [simd_double3x3](repeating: matrix_identity_double3x3, count: J)
        var P = [SIMD3<Double>](repeating: .zero, count: J)
        let restV = (0..<J).map { SIMD3<Double>(rest[$0 * 3], rest[$0 * 3 + 1], rest[$0 * 3 + 2]) }
        let par = (1..<78).map { parents78[$0] - 1 }
        for t in 0..<L {
            G[0] = GemxMath.rotvecToMatrix(SIMD3<Double>(globalOrient[t * 3], globalOrient[t * 3 + 1], globalOrient[t * 3 + 2]))
            P[0] = SIMD3<Double>(transl[t * 3], transl[t * 3 + 1], transl[t * 3 + 2])
            for k in 1..<J {
                let q = par[k]
                let rk = GemxMath.rotvecToMatrix(SIMD3<Double>(bodyPose[t * 228 + (k - 1) * 3], bodyPose[t * 228 + (k - 1) * 3 + 1], bodyPose[t * 228 + (k - 1) * 3 + 2]))
                G[k] = G[q] * rk
                P[k] = P[q] + G[q] * (restV[k] - restV[q])
            }
            for k in 0..<J {
                joints[(t * J + k) * 3] = P[k].x; joints[(t * J + k) * 3 + 1] = P[k].y; joints[(t * J + k) * 3 + 2] = P[k].z
            }
        }
        return joints
    }

    static func ground(transl: [Double], joints: [Double], L: Int, smoothXZ: Bool = true, sigma: Double = 3) -> [Double] {
        var t = transl
        if smoothXZ && L > 1 {
            let xs = GemxMath.gaussianFilter1D((0..<L).map { transl[$0 * 3] }, sigma: sigma)
            let zs = GemxMath.gaussianFilter1D((0..<L).map { transl[$0 * 3 + 2] }, sigma: sigma)
            for i in 0..<L { t[i * 3] = xs[i]; t[i * 3 + 2] = zs[i] }
        }
        let J = GemxConst.numJoints
        var minY = Double.infinity
        for f in 0..<L {
            let dy = t[f * 3 + 1] - transl[f * 3 + 1]
            for k in 0..<J { minY = min(minY, joints[(f * J + k) * 3 + 1] + dy) }
        }
        for f in 0..<L { t[f * 3 + 1] -= minY }
        return t
    }

    static func jointFrames(joints: [Double], transl: [Double], groundedTransl: [Double], L: Int) -> [JointFrame] {
        let J = GemxConst.numJoints
        var frames: [JointFrame] = []
        frames.reserveCapacity(L)
        for f in 0..<L {
            let d = SIMD3<Double>(groundedTransl[f * 3] - transl[f * 3], groundedTransl[f * 3 + 1] - transl[f * 3 + 1], groundedTransl[f * 3 + 2] - transl[f * 3 + 2])
            var xyz = [Float](repeating: 0, count: J * 3)
            for k in 0..<J {
                let o = (f * J + k) * 3
                xyz[k * 3] = Float(joints[o] + d.x); xyz[k * 3 + 1] = Float(joints[o + 1] + d.y); xyz[k * 3 + 2] = Float(joints[o + 2] + d.z)
            }
            SkeletonTopology.gemxToSceneFrame(&xyz)
            frames.append(JointFrame(xyz))
        }
        return frames
    }

    static func incamTransl(predCam: [Float], bbxXys: [Float], K: [Float], L: Int) -> [Double] {
        let f = Double(K[0]), icx = Double(K[2]), icy = Double(K[5])
        var out = [Double](repeating: 0, count: L * 3)
        for t in 0..<L {
            let s = Double(predCam[t * 3]), tx = Double(predCam[t * 3 + 1]), ty = Double(predCam[t * 3 + 2])
            let sb = s * Double(bbxXys[t * 3 + 2]) + 1e-9
            out[t * 3]     = tx + 2 * (Double(bbxXys[t * 3]) - icx) / sb
            out[t * 3 + 1] = ty + 2 * (Double(bbxXys[t * 3 + 1]) - icy) / sb
            out[t * 3 + 2] = 2 * f / sb
        }
        return out
    }

    static func cameraFrames(joints: [Double], L: Int) -> [JointFrame] {
        let J = GemxConst.numJoints
        var frames: [JointFrame] = []
        frames.reserveCapacity(L)
        for f in 0..<L {
            var xyz = [Float](repeating: 0, count: J * 3)
            for k in 0..<J {
                let o = (f * J + k) * 3
                xyz[k * 3] = Float(joints[o]); xyz[k * 3 + 1] = Float(joints[o + 1]); xyz[k * 3 + 2] = Float(joints[o + 2])
            }
            SkeletonTopology.gemxToCameraFrame(&xyz)
            frames.append(JointFrame(xyz))
        }
        return frames
    }

    static func project(points: [Double], K: [Float], count: Int) -> [Double] {
        let fx = Double(K[0]), fy = Double(K[4]), cx = Double(K[2]), cy = Double(K[5])
        var out = [Double](repeating: 0, count: count * 2)
        for i in 0..<count {
            let z = max(points[i * 3 + 2], 1e-6)
            out[i * 2] = fx * points[i * 3] / z + cx
            out[i * 2 + 1] = fy * points[i * 3 + 1] / z + cy
        }
        return out
    }

    static func toBvh(globalOrient: [Double], bodyPose: [Double], transl: [Double], rest: [Double], tables: GemxTables, L: Int, fps: Double) -> String {
        let n = 78
        let names = tables.names78, parents = tables.parents78
        var pos = [SIMD3<Double>](repeating: .zero, count: n)
        for j in 1..<n { pos[j] = SIMD3<Double>(rest[(j - 1) * 3], rest[(j - 1) * 3 + 1], rest[(j - 1) * 3 + 2]) }
        var off = [SIMD3<Double>](repeating: .zero, count: n)
        for j in 1..<n { off[j] = pos[j] - pos[parents[j]] }
        var children = [[Int]](repeating: [], count: n)
        for j in 2..<n { children[parents[j]].append(j) }

        var out: [String] = ["HIERARCHY"]
        var order: [Int] = []
        func f6(_ v: Double) -> String { String(format: "%.6f", v) }
        func write(_ j: Int, _ depth: Int) {
            let ind = String(repeating: "\t", count: depth)
            let root = j == 1
            order.append(j)
            out.append("\(ind)\(root ? "ROOT" : "JOINT") \(names[j])")
            out.append("\(ind){")
            let o = root ? SIMD3<Double>.zero : off[j]
            out.append("\(ind)\tOFFSET \(f6(o.x)) \(f6(o.y)) \(f6(o.z))")
            out.append(root ? "\(ind)\tCHANNELS 6 Xposition Yposition Zposition Zrotation Yrotation Xrotation"
                            : "\(ind)\tCHANNELS 3 Zrotation Yrotation Xrotation")
            if children[j].isEmpty {
                out.append("\(ind)\tEnd Site"); out.append("\(ind)\t{"); out.append("\(ind)\t\tOFFSET 0.000000 0.000000 0.000000"); out.append("\(ind)\t}")
            } else {
                for c in children[j] { write(c, depth + 1) }
            }
            out.append("\(ind)}")
        }
        write(1, 0)
        out.append("MOTION")
        out.append("Frames: \(L)")
        out.append("Frame Time: \(f6(1.0 / (fps > 0 ? fps : 30)))")
        var row: [String] = []
        row.reserveCapacity(3 + 3 * 77)
        for t in 0..<L {
            row.removeAll(keepingCapacity: true)
            row.append(f6(transl[t * 3])); row.append(f6(transl[t * 3 + 1])); row.append(f6(transl[t * 3 + 2]))
            for j in order {
                let rv: SIMD3<Double>
                if j == 1 {
                    rv = SIMD3<Double>(globalOrient[t * 3], globalOrient[t * 3 + 1], globalOrient[t * 3 + 2])
                } else {
                    let o = t * 228 + (j - 2) * 3
                    rv = SIMD3<Double>(bodyPose[o], bodyPose[o + 1], bodyPose[o + 2])
                }
                let e = GemxMath.matrixToEulerZYXDeg(GemxMath.rotvecToMatrix(rv))
                row.append(f6(e.x)); row.append(f6(e.y)); row.append(f6(e.z))
            }
            out.append(row.joined(separator: " "))
        }
        return out.joined(separator: "\n") + "\n"
    }
}

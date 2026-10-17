import Foundation
import simd
import SceneKit

final class RigPoseApplier {

    fileprivate struct BoneBind {
        let node: SCNNode
        let bindLocalT: SIMD3<Float>
        let bindLocalR: simd_quatf
        let bindLocalS: SIMD3<Float>

        let bindWorldT: SIMD3<Float>
        let bindWorldQ: simd_quatf
        let bindParentQ: simd_quatf
    }

    fileprivate struct AimCandidate {
        let target: Int
        let bindDirInParent: SIMD3<Float>
    }

    fileprivate struct UpdateSpec {
        let own: Int
        let bone: BoneBind

        let candidates: [AimCandidate]
    }

    fileprivate struct YawSpec {
        let bone: BoneBind
        let leftJoint: Int
        let rightJoint: Int
        let bindRightXZ: SIMD3<Float>
    }

    private let bones: [BoneBind?]
    private let updateSpecs: [UpdateSpec]
    private let yawSpec: YawSpec?
    private let avatarContainer: SCNNode
    let hipsLift: Float
    let isReady: Bool

    let matchedCount: Int
    let coreMatchedCount: Int

    let missingJointIndices: [Int]

    let bindHipsAvatarLocal: SIMD3<Float>

    let bindChainLength: Float

    private(set) var lastRootPosition: SIMD3<Float>? = nil

    private(set) var motionTranslation: SIMD3<Float> = .zero
    private var firstFrameJ0: SIMD3<Float>? = nil
    private var loggedFirstFrame = false

    func resetMotionAnchor() { firstFrameJ0 = nil; motionTranslation = .zero; lastRootPosition = nil }

    static func chainLength(_ xyz: [Float]) -> Float {
        guard xyz.count == JointFrame.floatCount else { return 0 }
        func d(_ a: Int, _ b: Int) -> Float {
            simd_length(SIMD3<Float>(xyz[a * 3], xyz[a * 3 + 1], xyz[a * 3 + 2]) - SIMD3<Float>(xyz[b * 3], xyz[b * 3 + 1], xyz[b * 3 + 2]))
        }
        typealias T = SkeletonTopology
        let spine = d(T.hips, T.spine1) + d(T.spine1, T.spine2) + d(T.spine2, T.chest) + d(T.chest, T.neck1) + d(T.neck1, T.head)
        let legL = d(T.hips, T.leftLeg) + d(T.leftLeg, T.leftShin) + d(T.leftShin, T.leftFoot)
        let legR = d(T.hips, T.rightLeg) + d(T.rightLeg, T.rightShin) + d(T.rightShin, T.rightFoot)
        let l = spine + (legL + legR) / 2
        return l.isFinite ? l : 0
    }

    private init(
        bones: [BoneBind?],
        updateSpecs: [UpdateSpec],
        yawSpec: YawSpec?,
        avatarContainer: SCNNode,
        hipsLift: Float,
        isReady: Bool,
        bindHipsAvatarLocal: SIMD3<Float>,
        bindChainLength: Float = 0
    ) {
        self.bones = bones
        self.bindChainLength = bindChainLength
        self.updateSpecs = updateSpecs
        self.yawSpec = yawSpec
        self.avatarContainer = avatarContainer
        self.hipsLift = hipsLift
        self.isReady = isReady
        self.matchedCount = bones.compactMap { $0 }.count
        self.coreMatchedCount = SkeletonTopology.humanml22.filter { bones[$0] != nil }.count
        self.missingJointIndices = SkeletonTopology.humanml22.filter { bones[$0] == nil }
        self.bindHipsAvatarLocal = bindHipsAvatarLocal
    }

    private func parentRotation(_ bone: BoneBind, _ avatarInv: simd_float4x4) -> simd_quatf {
        guard let p = bone.node.parent else { return identityQ }
        return decompose(simd_mul(avatarInv, p.simdWorldTransform)).1
    }

    func apply(_ frame: JointFrame) {
        guard isReady, frame.xyz.count == JointFrame.floatCount else { return }

        for j in SkeletonTopology.humanml22 where !frame.isPresent(j) { return }

        let j0 = frame.position(0)
        if firstFrameJ0 == nil { firstFrameJ0 = j0 }
        motionTranslation = j0 - (firstFrameJ0 ?? j0)
        lastRootPosition = j0

        let avatarInv = avatarContainer.simdWorldTransform.inverse

        if let yaw = yawSpec, let pelvis = bones[0] {
            let jl = frame.position(yaw.leftJoint)
            let jr = frame.position(yaw.rightJoint)
            let live = SIMD3<Float>(jr.x - jl.x, 0, jr.z - jl.z)
            let lenSq = simd_length_squared(live)
            let newWorld: simd_quatf
            if lenSq < 1e-8 {
                newWorld = pelvis.bindWorldQ
            } else {
                let liveDir = live / sqrt(lenSq)
                let yawDelta = quatFromUnitVectors(yaw.bindRightXZ, liveDir)
                newWorld = simd_mul(yawDelta, pelvis.bindWorldQ)
            }
            let newLocal = simd_mul(parentRotation(pelvis, avatarInv).inverse, newWorld)
            pelvis.node.simdTransform = composeTRS(pelvis.bindLocalT, newLocal, pelvis.bindLocalS)
        }

        var aimed = 0, aimedFingers = 0
        defer {
            if !loggedFirstFrame {
                loggedFirstFrame = true
                let present = (0..<SkeletonTopology.jointCount).filter { frame.isPresent($0) }.count
                NSLog("[RigPoseApplier] first frame: \(present)/\(SkeletonTopology.jointCount) joints present, aimed \(aimed) bones (\(aimedFingers) finger)")
            }
        }
        for spec in updateSpecs {
            let bone = spec.bone
            guard frame.isPresent(spec.own) else {
                bone.node.simdTransform = composeTRS(bone.bindLocalT, bone.bindLocalR, bone.bindLocalS)
                continue
            }
            let jOwn = frame.position(spec.own)
            var chosen: AimCandidate? = nil
            var dirWorld = SIMD3<Float>.zero
            var degenerate = false
            for c in spec.candidates where frame.isPresent(c.target) {
                let r = frame.position(c.target) - jOwn
                let lenSq = simd_length_squared(r)
                if lenSq < 1e-8 { degenerate = true; continue }
                chosen = c; dirWorld = r / sqrt(lenSq)
                break
            }
            guard let cand = chosen else {

                if !degenerate { bone.node.simdTransform = composeTRS(bone.bindLocalT, bone.bindLocalR, bone.bindLocalS) }
                continue
            }
            let parentQ = parentRotation(bone, avatarInv)
            let dirInParent = simd_act(parentQ.inverse, dirWorld)
            let delta = quatFromUnitVectors(cand.bindDirInParent, dirInParent)
            let newLocal = simd_mul(delta, bone.bindLocalR)
            bone.node.simdTransform = composeTRS(bone.bindLocalT, newLocal, bone.bindLocalS)
            aimed += 1
            if (15...38).contains(spec.own) || (43...66).contains(spec.own) { aimedFingers += 1 }
        }
    }

    static func forSmpl(
        rigRoot: SCNNode,
        bonesByName: [String: SCNNode],
        avatarContainer: SCNNode
    ) -> RigPoseApplier {
        return create(
            rigRoot: rigRoot,
            bonesByName: bonesByName,
            aliases: SkeletonTopology.aliases,
            rigName: "Rig",
            hipsLift: 0,
            avatarContainer: avatarContainer
        )
    }

    private static func create(
        rigRoot: SCNNode,
        bonesByName: [String: SCNNode],
        aliases: [(Int, [String])],
        rigName: String,
        hipsLift: Float,
        avatarContainer: SCNNode
    ) -> RigPoseApplier {
        let J = SkeletonTopology.jointCount
        var nodes: [SCNNode?] = Array(repeating: nil, count: J)
        for (idx, aliasList) in aliases {
            for alias in aliasList {
                let key = SkeletonTopology.normalize(alias)
                if let node = bonesByName[key] ?? bonesByName[SkeletonTopology.stripPrefix(key)] {
                    nodes[idx] = node
                    break
                }
            }
        }
        let matched = nodes.compactMap { $0 }.count
        let core = SkeletonTopology.humanml22.filter { nodes[$0] != nil }.count
        let fingers = (15...38).filter { nodes[$0] != nil }.count + (43...66).filter { nodes[$0] != nil }.count
        NSLog("[RigPoseApplier] matched \(matched)/\(J) \(rigName) bones: \(core)/22 body, \(fingers)/48 finger")

        if core < 18 {
            NSLog("[RigPoseApplier] too few \(rigName) body bones (\(core)/22) — pose updates disabled")
            return RigPoseApplier(
                bones: Array(repeating: nil, count: J),
                updateSpecs: [],
                yawSpec: nil,
                avatarContainer: avatarContainer,
                hipsLift: hipsLift,
                isReady: false,
                bindHipsAvatarLocal: .zero
            )
        }

        let avatarInv = avatarContainer.simdWorldTransform.inverse
        var bones: [BoneBind?] = Array(repeating: nil, count: J)
        for i in 0..<J {
            guard let node = nodes[i] else { continue }
            let (t, r, s) = decompose(node.simdTransform)
            let (wt, wr, _) = decompose(simd_mul(avatarInv, node.simdWorldTransform))
            let pq = node.parent.map { decompose(simd_mul(avatarInv, $0.simdWorldTransform)).1 } ?? identityQ
            bones[i] = BoneBind(node: node, bindLocalT: t, bindLocalR: r, bindLocalS: s,
                                bindWorldT: wt, bindWorldQ: wr, bindParentQ: pq)
        }
        if let pelvisParent = bones[0]?.node.parent {
            let (_, r, sc) = decompose(simd_mul(avatarInv, pelvisParent.simdWorldTransform))
            NSLog("[RigPoseApplier] pelvis parent '\(pelvisParent.name ?? "?")' in avatar space: rot=(\(r.vector.x), \(r.vector.y), \(r.vector.z), \(r.vector.w)) scale=\(sc)")
        }

        var updateSpecs: [UpdateSpec] = []
        for own in 1..<J {
            guard let ownBone = bones[own] else { continue }
            var candidates: [AimCandidate] = []
            for target in SkeletonTopology.aimTargets[own] {
                guard let tb = bones[target] else { continue }
                let d = tb.bindWorldT - ownBone.bindWorldT
                if simd_length_squared(d) < 1e-10 { continue }
                candidates.append(AimCandidate(
                    target: target,
                    bindDirInParent: normalizeOrZero(simd_act(ownBone.bindParentQ.inverse, d))
                ))
            }
            if !candidates.isEmpty {
                updateSpecs.append(UpdateSpec(own: own, bone: ownBone, candidates: candidates))
            }
        }

        let yawSpec: YawSpec?
        if let pelvis = bones[0], let l = bones[SkeletonTopology.leftLeg], let r = bones[SkeletonTopology.rightLeg] {
            let dx = r.bindWorldT.x - l.bindWorldT.x
            let dz = r.bindWorldT.z - l.bindWorldT.z
            if dx * dx + dz * dz < 1e-10 {
                yawSpec = nil
            } else {
                yawSpec = YawSpec(
                    bone: pelvis,
                    leftJoint: SkeletonTopology.leftLeg, rightJoint: SkeletonTopology.rightLeg,
                    bindRightXZ: normalizeOrZero(SIMD3<Float>(dx, 0, dz))
                )
            }
        } else {
            yawSpec = nil
        }

        let bindHipsAvatarLocal = bones[0]?.bindWorldT ?? .zero
        var bindXyz = [Float](repeating: .nan, count: JointFrame.floatCount)
        for i in 0..<J {
            guard let b = bones[i] else { continue }
            bindXyz[i * 3] = b.bindWorldT.x; bindXyz[i * 3 + 1] = b.bindWorldT.y; bindXyz[i * 3 + 2] = b.bindWorldT.z
        }
        let bindChain = chainLength(bindXyz)
        NSLog("[RigPoseApplier] bindHipsAvatarLocal=\(bindHipsAvatarLocal) bindChainLength=\(bindChain) aimBones=\(updateSpecs.count)")

        return RigPoseApplier(
            bones: bones,
            updateSpecs: updateSpecs,
            yawSpec: yawSpec,
            avatarContainer: avatarContainer,
            hipsLift: hipsLift,
            isReady: true,
            bindHipsAvatarLocal: bindHipsAvatarLocal,
            bindChainLength: bindChain
        )
    }
}

let identityQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

private func normalizeOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let ls = simd_length_squared(v)
    if ls < 1e-12 { return .zero }
    return v / sqrt(ls)
}

private func quatFromUnitVectors(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> simd_quatf {
    var r = simd_dot(from, to) + 1
    let qx: Float; let qy: Float; let qz: Float; let qw: Float
    if r < 1e-6 {
        r = 0
        if abs(from.x) > abs(from.z) {
            qx = -from.y; qy = from.x; qz = 0; qw = r
        } else {
            qx = 0; qy = -from.z; qz = from.y; qw = r
        }
    } else {
        qx = from.y * to.z - from.z * to.y
        qy = from.z * to.x - from.x * to.z
        qz = from.x * to.y - from.y * to.x
        qw = r
    }
    let n = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if n < 1e-12 { return identityQ }
    return simd_quatf(ix: qx / n, iy: qy / n, iz: qz / n, r: qw / n)
}

private func composeTRS(
    _ t: SIMD3<Float>,
    _ q: simd_quatf,
    _ s: SIMD3<Float>
) -> simd_float4x4 {
    let xx = q.imag.x * q.imag.x
    let yy = q.imag.y * q.imag.y
    let zz = q.imag.z * q.imag.z
    let xy = q.imag.x * q.imag.y
    let xz = q.imag.x * q.imag.z
    let yz = q.imag.y * q.imag.z
    let wx = q.real * q.imag.x
    let wy = q.real * q.imag.y
    let wz = q.real * q.imag.z
    let c0 = SIMD4<Float>(
        s.x * (1 - 2 * (yy + zz)),
        s.x * (2 * (xy + wz)),
        s.x * (2 * (xz - wy)),
        0
    )
    let c1 = SIMD4<Float>(
        s.y * (2 * (xy - wz)),
        s.y * (1 - 2 * (xx + zz)),
        s.y * (2 * (yz + wx)),
        0
    )
    let c2 = SIMD4<Float>(
        s.z * (2 * (xz + wy)),
        s.z * (2 * (yz - wx)),
        s.z * (1 - 2 * (xx + yy)),
        0
    )
    let c3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    return simd_float4x4(columns: (c0, c1, c2, c3))
}

func decompose(_ m: simd_float4x4) -> (SIMD3<Float>, simd_quatf, SIMD3<Float>) {
    let m0 = m.columns.0
    let m1 = m.columns.1
    let m2 = m.columns.2
    let m3 = m.columns.3
    let sx = sqrt(m0.x * m0.x + m0.y * m0.y + m0.z * m0.z)
    let sy = sqrt(m1.x * m1.x + m1.y * m1.y + m1.z * m1.z)
    let sz = sqrt(m2.x * m2.x + m2.y * m2.y + m2.z * m2.z)
    let rsx: Float = sx == 0 ? 0 : 1 / sx
    let rsy: Float = sy == 0 ? 0 : 1 / sy
    let rsz: Float = sz == 0 ? 0 : 1 / sz
    let r00 = m0.x * rsx, r01 = m1.x * rsy, r02 = m2.x * rsz
    let r10 = m0.y * rsx, r11 = m1.y * rsy, r12 = m2.y * rsz
    let r20 = m0.z * rsx, r21 = m1.z * rsy, r22 = m2.z * rsz
    let tr = r00 + r11 + r22
    let q: simd_quatf
    if tr > 0 {
        let s2 = sqrt(tr + 1) * 2
        q = simd_quatf(ix: (r21 - r12) / s2, iy: (r02 - r20) / s2, iz: (r10 - r01) / s2, r: 0.25 * s2)
    } else if r00 > r11 && r00 > r22 {
        let s2 = sqrt(1 + r00 - r11 - r22) * 2
        q = simd_quatf(ix: 0.25 * s2, iy: (r01 + r10) / s2, iz: (r02 + r20) / s2, r: (r21 - r12) / s2)
    } else if r11 > r22 {
        let s2 = sqrt(1 + r11 - r00 - r22) * 2
        q = simd_quatf(ix: (r01 + r10) / s2, iy: 0.25 * s2, iz: (r12 + r21) / s2, r: (r02 - r20) / s2)
    } else {
        let s2 = sqrt(1 + r22 - r00 - r11) * 2
        q = simd_quatf(ix: (r02 + r20) / s2, iy: (r12 + r21) / s2, iz: 0.25 * s2, r: (r10 - r01) / s2)
    }
    return (SIMD3<Float>(m3.x, m3.y, m3.z), q, SIMD3<Float>(sx, sy, sz))
}

import Foundation
import simd
import SceneKit

/// Drives a rigged humanoid SCNNode tree from 22-joint HumanML3D frames using
/// an aim-at-child approach: per bone, capture its parent-local direction
/// toward its child at bind time; per frame, compute the live direction in the
/// parent's current frame and rotate the bone by the delta. Pelvis yaw is
/// handled separately from L_Hip→R_Hip so the body twists at the waist.
final class RigPoseApplier {

    fileprivate struct BoneBind {
        let node: SCNNode
        let bindLocalT: SIMD3<Float>
        let bindLocalR: simd_quatf
        let bindLocalS: SIMD3<Float>
        let bindWorldQ: simd_quatf
    }

    fileprivate struct RootBind {
        let node: SCNNode
        let bindT: SIMD3<Float>
        let bindR: simd_quatf
        let bindS: SIMD3<Float>
    }

    fileprivate struct UpdateSpec {
        let own: Int
        let target: Int
        let bone: BoneBind
        let bindDirInParent: SIMD3<Float>
        let bindLocalQ: simd_quatf
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
    private let rootBind: RootBind
    private let bindHipsOffset: SIMD3<Float>
    private let parentWorldRot: simd_quatf
    private let bindRootWorldT: SIMD3<Float>
    private let bindRootWorldR: simd_quatf
    private let bindRootWorldS: SIMD3<Float>
    let hipsLift: Float
    let isReady: Bool

    let matchedCount: Int
    let missingJointIndices: [Int]

    private let bindHipsAvatarLocal: SIMD3<Float>

    /// Anchored to the *first received frame*, not the asset's bind pose —
    /// BAMM's reference pelvis (~Y=0.92) can disagree with the rig's bind
    /// (e.g. USDZ pelvis at avatar-local Y=-0.24). Anchoring per-session
    /// avoids that mismatch.
    private(set) var motionTranslation: SIMD3<Float> = .zero
    private var firstFrameJ0: SIMD3<Float>? = nil

    func resetMotionAnchor() { firstFrameJ0 = nil; motionTranslation = .zero }

    private init(
        bones: [BoneBind?],
        updateSpecs: [UpdateSpec],
        yawSpec: YawSpec?,
        rootBind: RootBind,
        bindHipsOffset: SIMD3<Float>,
        parentWorldRot: simd_quatf,
        hipsLift: Float,
        isReady: Bool,
        bindHipsAvatarLocal: SIMD3<Float>
    ) {
        self.bones = bones
        self.updateSpecs = updateSpecs
        self.yawSpec = yawSpec
        self.rootBind = rootBind
        self.bindHipsOffset = bindHipsOffset
        self.parentWorldRot = parentWorldRot
        self.hipsLift = hipsLift
        self.isReady = isReady
        self.matchedCount = bones.compactMap { $0 }.count
        self.missingJointIndices = (0..<bones.count).filter { bones[$0] == nil }
        let (wt, wr, ws) = decompose(rootBind.node.simdWorldTransform)
        self.bindRootWorldT = wt
        self.bindRootWorldR = wr
        self.bindRootWorldS = ws
        self.bindHipsAvatarLocal = bindHipsAvatarLocal
    }

    func apply(_ frame: JointFrame) {
        guard isReady, frame.xyz.count == 66 else { return }
        let xyz = frame.xyz

        var currentWorldQ: [simd_quatf?] = Array(repeating: nil, count: 22)

        // Reject NaN/Inf — they silently propagate and either send the rig to
        // infinity or collapse it to origin.
        for v in xyz where !v.isFinite { return }

        // Root translation is published as motionTranslation; SceneCoordinator
        // adds it to avatarContainer.simdPosition. Writing into a deep skinner
        // bone breaks the local-space math through the USDZ transforms.
        let j0 = SIMD3<Float>(xyz[0], xyz[1], xyz[2])
        if firstFrameJ0 == nil { firstFrameJ0 = j0 }
        motionTranslation = j0 - (firstFrameJ0 ?? j0)

        // Pelvis yaw: build new world quat from L_Hip→R_Hip XZ direction, then
        // divide out parent world rotation to get the local quat to write.
        let parentWorldRotInv = parentWorldRot.inverse
        let pelvisOpt = bones[0]
        if let yaw = yawSpec, let pelvis = pelvisOpt {
            let jl = readJoint(xyz, yaw.leftJoint)
            let jr = readJoint(xyz, yaw.rightJoint)
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
            let newLocal = simd_mul(parentWorldRotInv, newWorld)
            pelvis.node.simdTransform = composeTRS(pelvis.bindLocalT, newLocal, pelvis.bindLocalS)
            currentWorldQ[0] = newWorld
        } else if let pelvis = pelvisOpt {
            currentWorldQ[0] = pelvis.bindWorldQ
        }

        // Aim-at-child for every other bone. Update order has parents first.
        for spec in updateSpecs {
            let jOwn = readJoint(xyz, spec.own)
            let jTgt = readJoint(xyz, spec.target)
            let r = jTgt - jOwn
            let lenSq = simd_length_squared(r)
            if lenSq < 1e-8 {
                if currentWorldQ[spec.own] == nil {
                    currentWorldQ[spec.own] = spec.bone.bindWorldQ
                }
                continue
            }
            let dirWorld = r / sqrt(lenSq)
            let parentJoint = SkeletonTopology.parent[spec.own]
            let parentWorld: simd_quatf
            if parentJoint >= 0, let pq = currentWorldQ[parentJoint] {
                parentWorld = pq
            } else if parentJoint >= 0, let pb = bones[parentJoint] {
                parentWorld = pb.bindWorldQ
            } else if let pb = bones[max(parentJoint, 0)] {
                parentWorld = pb.bindWorldQ
            } else {
                parentWorld = identityQ
            }
            let parentInv = parentWorld.inverse
            let dirInParent = simd_act(parentInv, dirWorld)
            let delta = quatFromUnitVectors(spec.bindDirInParent, dirInParent)
            let newLocal = simd_mul(delta, spec.bindLocalQ)
            spec.bone.node.simdTransform = composeTRS(
                spec.bone.bindLocalT, newLocal, spec.bone.bindLocalS
            )
            currentWorldQ[spec.own] = simd_mul(parentWorld, newLocal)
        }
    }

    // MARK: - Factories

    static func forSmpl(
        rigRoot: SCNNode,
        bonesByName: [String: SCNNode],
        avatarContainer: SCNNode
    ) -> RigPoseApplier {
        return create(
            rigRoot: rigRoot,
            bonesByName: bonesByName,
            aliases: SkeletonTopology.smplAliases,
            rigName: "Rig",
            hipsLift: 0,
            parentWorldT: .zero,
            parentWorldR: identityQ,
            parentWorldS: SIMD3<Float>(1, 1, 1),
            avatarContainer: avatarContainer
        )
    }

    private static func create(
        rigRoot: SCNNode,
        bonesByName: [String: SCNNode],
        aliases: [(Int, [String])],
        rigName: String,
        hipsLift: Float,
        parentWorldT: SIMD3<Float>,
        parentWorldR: simd_quatf,
        parentWorldS: SIMD3<Float>,
        avatarContainer: SCNNode
    ) -> RigPoseApplier {

        let rootCandidate =
            bonesByName[SkeletonTopology.normalize("root")]
            ?? bonesByName[SkeletonTopology.normalize("Character")]
            ?? bonesByName[SkeletonTopology.normalize("Pelvis")]
            ?? rigRoot

        var bones: [BoneBind?] = Array(repeating: nil, count: 22)
        for (idx, aliasList) in aliases {
            for alias in aliasList {
                let key = SkeletonTopology.normalize(alias)
                if let node = bonesByName[key] ?? bonesByName[SkeletonTopology.stripPrefix(key)] {
                    bones[idx] = BoneBind(
                        node: node,
                        bindLocalT: .zero, bindLocalR: identityQ, bindLocalS: SIMD3<Float>(1, 1, 1),
                        bindWorldQ: identityQ
                    )
                    break
                }
            }
        }
        let matched = bones.compactMap { $0 }.count
        NSLog("[RigPoseApplier] matched \(matched)/22 \(rigName) bones")

        let (rootT, rootR, rootS) = decompose(rootCandidate.simdTransform)
        let rootBind = RootBind(node: rootCandidate, bindT: rootT, bindR: rootR, bindS: rootS)

        if matched < 18 {
            NSLog("[RigPoseApplier] too few \(rigName) bones (\(matched)/22) — pose updates disabled")
            return RigPoseApplier(
                bones: bones,
                updateSpecs: [],
                yawSpec: nil,
                rootBind: rootBind,
                bindHipsOffset: .zero,
                parentWorldRot: parentWorldR,
                hipsLift: hipsLift,
                isReady: false,
                bindHipsAvatarLocal: .zero
            )
        }

        for i in 0..<22 {
            guard let b = bones[i] else { continue }
            let (t, r, s) = decompose(b.node.simdTransform)
            bones[i] = BoneBind(
                node: b.node,
                bindLocalT: t, bindLocalR: r, bindLocalS: s,
                bindWorldQ: identityQ
            )
        }

        var bindWorldQuats: [simd_quatf?] = Array(repeating: nil, count: 22)
        bindWorldQuats[0] = simd_mul(parentWorldR, bones[0]?.bindLocalR ?? identityQ)
        for i in 1..<22 {
            let p = SkeletonTopology.parent[i]
            let parentWorld = bindWorldQuats[p] ?? bones[p]?.bindLocalR ?? identityQ
            bindWorldQuats[i] = simd_mul(parentWorld, bones[i]?.bindLocalR ?? identityQ)
        }
        for i in 0..<22 {
            guard let b = bones[i] else { continue }
            bones[i] = BoneBind(
                node: b.node,
                bindLocalT: b.bindLocalT, bindLocalR: b.bindLocalR, bindLocalS: b.bindLocalS,
                bindWorldQ: bindWorldQuats[i] ?? identityQ
            )
        }

        let bindHipsOffset = worldPosAtBind(0, bones, parentWorldR, parentWorldS)

        var updateSpecs: [UpdateSpec] = []
        for (own, target) in SkeletonTopology.updateOrder {
            guard let ownBone = bones[own], bones[target] != nil else { continue }
            let ownWorld = worldPosAtBind(own, bones, parentWorldR, parentWorldS)
            let targetWorld = worldPosAtBind(target, bones, parentWorldR, parentWorldS)
            let d = targetWorld - ownWorld
            let lenSq = simd_length_squared(d)
            if lenSq < 1e-10 { continue }
            let parentWorldQ: simd_quatf = (own == 0)
                ? parentWorldR
                : (bones[SkeletonTopology.parent[own]]?.bindWorldQ ?? identityQ)
            let parentInv = parentWorldQ.inverse
            let dirInParent = normalizeOrZero(simd_act(parentInv, d))
            updateSpecs.append(UpdateSpec(
                own: own, target: target, bone: ownBone,
                bindDirInParent: dirInParent,
                bindLocalQ: ownBone.bindLocalR
            ))
        }

        let yawSpec: YawSpec?
        if let pelvis = bones[0], bones[1] != nil, bones[2] != nil {
            let lWorld = worldPosAtBind(1, bones, parentWorldR, parentWorldS)
            let rWorld = worldPosAtBind(2, bones, parentWorldR, parentWorldS)
            let dx = rWorld.x - lWorld.x
            let dz = rWorld.z - lWorld.z
            if dx * dx + dz * dz < 1e-10 {
                yawSpec = nil
            } else {
                yawSpec = YawSpec(
                    bone: pelvis,
                    leftJoint: 1, rightJoint: 2,
                    bindRightXZ: normalizeOrZero(SIMD3<Float>(dx, 0, dz))
                )
            }
        } else {
            yawSpec = nil
        }

        let bindHipsAvatarLocal: SIMD3<Float>
        if let pelvisNode = bones[0]?.node {
            let pelvisWorld = pelvisNode.simdWorldTransform.columns.3
            let pelvisWorldT = SIMD3<Float>(pelvisWorld.x, pelvisWorld.y, pelvisWorld.z)
            bindHipsAvatarLocal = avatarContainer.simdConvertPosition(pelvisWorldT, from: nil)
        } else {
            bindHipsAvatarLocal = bindHipsOffset
        }
        NSLog("[RigPoseApplier] bindHipsAvatarLocal=\(bindHipsAvatarLocal)")

        return RigPoseApplier(
            bones: bones,
            updateSpecs: updateSpecs,
            yawSpec: yawSpec,
            rootBind: rootBind,
            bindHipsOffset: bindHipsOffset,
            parentWorldRot: parentWorldR,
            hipsLift: hipsLift,
            isReady: true,
            bindHipsAvatarLocal: bindHipsAvatarLocal
        )
    }
}

// MARK: - Math helpers

let identityQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

private func readJoint(_ xyz: [Float], _ idx: Int) -> SIMD3<Float> {
    SIMD3<Float>(xyz[idx * 3], xyz[idx * 3 + 1], xyz[idx * 3 + 2])
}

private func worldPosAtBind(
    _ idx: Int,
    _ bones: [RigPoseApplier.BoneBind?],
    _ parentR: simd_quatf,
    _ parentS: SIMD3<Float>
) -> SIMD3<Float> {
    var chain: [Int] = []
    var cur = idx
    while cur != -1 {
        chain.insert(cur, at: 0)
        cur = (cur == 0) ? -1 : SkeletonTopology.parent[cur]
    }
    var p = SIMD3<Float>(0, 0, 0)
    var q = parentR
    var s = parentS
    for joint in chain {
        guard let b = bones[joint] else { return p }
        let scaled = b.bindLocalT * s
        let r = simd_act(q, scaled)
        p += r
        q = simd_mul(q, b.bindLocalR)
        s = s * b.bindLocalS
    }
    return p
}

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

import Foundation
import SceneKit

enum BoneBinder {

    static func indexByName(_ root: SCNNode) -> [String: SCNNode] {
        var out: [String: SCNNode] = [:]
        walk(root) { node in
            guard let raw = node.name, !raw.isEmpty else { return }
            out[SkeletonTopology.normalize(raw)] = node
        }
        return out
    }

    static func find(_ root: SCNNode, named name: String) -> SCNNode? {
        let target = SkeletonTopology.normalize(name)
        var found: SCNNode? = nil
        walk(root) { node in
            if found != nil { return }
            if let raw = node.name, SkeletonTopology.normalize(raw) == target {
                found = node
            }
        }
        return found
    }

    static func firstSkinner(_ root: SCNNode) -> SCNSkinner? {
        var found: SCNSkinner? = nil
        walk(root) { node in
            if found != nil { return }
            if let s = node.skinner { found = s }
        }
        return found
    }

    static func logSkin(_ root: SCNNode, label: String) {
        var nodeCount = 0
        var named: [String] = []
        walk(root) { node in
            nodeCount += 1
            if let n = node.name, !n.isEmpty {
                named.append(n)
            }
        }
        let skinner = firstSkinner(root)
        let boneCount = skinner?.bones.count ?? 0
        NSLog("[BoneBinder] \(label): \(nodeCount) nodes, \(named.count) named, skinner.bones=\(boneCount)")
        for chunk in named.chunked(into: 8) {
            NSLog("[BoneBinder] \(label) names: \(chunk.joined(separator: ", "))")
        }
        if let s = skinner {
            let boneNames = s.bones.compactMap { $0.name }
            for chunk in boneNames.chunked(into: 8) {
                NSLog("[BoneBinder] \(label) skinner.bones: \(chunk.joined(separator: ", "))")
            }
        }
    }

    /// USDZ imports produce two parallel hierarchies for skinned rigs: a named
    /// chain (Pelvis, L_Hip, …) and an anonymous skinner-bone chain (n0, n1, …)
    /// that actually drives mesh deformation. Pose writes to the named nodes
    /// do nothing — remap each name to the closest-position skinner bone.
    static func remapToSkinnerBones(
        _ bonesByName: [String: SCNNode],
        skinner: SCNSkinner?
    ) -> [String: SCNNode] {
        guard let skinner, !skinner.bones.isEmpty else {
            NSLog("[BoneBinder] no skinner — keeping named-node mapping")
            return bonesByName
        }
        let actualBones = skinner.bones
        let actualSet = Set(actualBones.map { ObjectIdentifier($0) })

        struct BonePos { let node: SCNNode; let pos: SIMD3<Float> }
        let bonePositions: [BonePos] = actualBones.map {
            let t = $0.simdWorldTransform
            return BonePos(node: $0, pos: SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z))
        }

        var out: [String: SCNNode] = [:]
        var remapped = 0, alreadyBone = 0, unmatched = 0
        for (name, node) in bonesByName {
            if actualSet.contains(ObjectIdentifier(node)) {
                out[name] = node
                alreadyBone += 1
                continue
            }
            let t = node.simdWorldTransform
            let target = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            var best: BonePos? = nil
            var bestDist: Float = .greatestFiniteMagnitude
            for bp in bonePositions {
                let d = simd_distance_squared(target, bp.pos)
                if d < bestDist {
                    bestDist = d
                    best = bp
                }
            }
            // 1 cm threshold — reject larger gaps to avoid snapping unrelated
            // nodes (the named tree also contains mesh/shape parents).
            if let best, bestDist < 0.01 * 0.01 {
                out[name] = best.node
                remapped += 1
            } else {
                unmatched += 1
            }
        }
        NSLog("[BoneBinder] remap-to-skinner: \(alreadyBone) already-bone, \(remapped) remapped, \(unmatched) unmatched")
        return out
    }

    /// USDZ exports often embed an animation that would overwrite our
    /// per-frame pose writes; strip it before bind-pose capture.
    static func removeAllAnimations(_ root: SCNNode) {
        var stripped = 0
        walk(root) { node in
            for key in node.animationKeys {
                node.removeAnimation(forKey: key)
                stripped += 1
            }
        }
        NSLog("[BoneBinder] stripped \(stripped) animations from subtree")
    }

    private static func walk(_ node: SCNNode, _ visit: (SCNNode) -> Void) {
        visit(node)
        for child in node.childNodes { walk(child, visit) }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

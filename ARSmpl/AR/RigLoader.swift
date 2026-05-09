import Foundation
import SceneKit
import UIKit

final class RigLoader {

    /// Per-material original diffuse contents, keyed by material identity, so
    /// the color picker's "Default" can restore them.
    private(set) var originalDiffuse: [ObjectIdentifier: Any] = [:]

    struct Loaded {
        let rigRoot: SCNNode
        let bonesByName: [String: SCNNode]
        let groundLift: Float
    }

    func load(_ rig: RigKind) throws -> Loaded {
        let rigRoot = try loadAsWrapper(
            resource: rig.resourceName,
            ext: rig.resourceExtension,
            label: "rig:\(rig.rawValue)"
        )

        // USDZ exports often bake an SCNAnimation on bone nodes that would
        // overwrite our per-frame pose writes; strip them before bind capture.
        BoneBinder.removeAllAnimations(rigRoot)

        // SceneKit's USDZ importer occasionally enables OpenSubdiv refinement.
        // Mixamo Vanguard has valence > 12 vertices which exceeds the GPU
        // ceiling and aborts rendering, so force level 0.
        disableSubdivision(rigRoot)

        captureOriginalDiffuse(rigRoot)

        let namedNodes = BoneBinder.indexByName(rigRoot)
        BoneBinder.logSkin(rigRoot, label: "rig:\(rig.rawValue)")

        // USDZ imports duplicate the skeleton: the named "Pelvis"/"L_Hip"/…
        // chain is decoupled from the anonymous bones SCNSkinner actually
        // deforms. Remap so each alias points at the live skinner bone.
        let skinner = BoneBinder.firstSkinner(rigRoot)
        let bonesByName = BoneBinder.remapToSkinnerBones(namedNodes, skinner: skinner)

        let lift: Float = -lowestMeshYInWrapper(rigRoot)
        NSLog("[RigLoader] rig:\(rig.rawValue) groundLift=\(lift)")

        return Loaded(
            rigRoot: rigRoot,
            bonesByName: bonesByName,
            groundLift: lift
        )
    }

    func loadStage(_ scene: SceneKind) throws -> SCNNode {
        let root = try loadAsWrapper(
            resource: scene.resourceName,
            ext: scene.resourceExtension,
            label: "stage:\(scene.rawValue)"
        )
        forceDoubleSided(root)
        return root
    }

    private func loadAsWrapper(resource: String, ext: String, label: String) throws -> SCNNode {
        // Models live under "Models/" (folder reference); fall back to flat.
        let url: URL
        if let nested = Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "Models") {
            url = nested
        } else if let flat = Bundle.main.url(forResource: resource, withExtension: ext) {
            url = flat
        } else {
            NSLog("[RigLoader] missing bundle resource: \(resource).\(ext)")
            throw NSError(
                domain: "RigLoader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(resource).\(ext) not in bundle"]
            )
        }
        NSLog("[RigLoader] loading \(label) from \(url.path)")
        let scene: SCNScene
        do {
            scene = try SCNScene(url: url, options: [
                .checkConsistency: false,
                .createNormalsIfAbsent: true,
            ])
        } catch {
            NSLog("[RigLoader] SCNScene(url:) threw for \(label): \(error)")
            throw error
        }

        let wrapper = SCNNode()
        wrapper.name = "\(label)_root"
        for child in Array(scene.rootNode.childNodes) {
            child.removeFromParentNode()
            wrapper.addChildNode(child)
        }

        let (minB, maxB) = wrapper.boundingBox
        var materialCount = 0
        forEachMaterial(wrapper) { _ in materialCount += 1 }
        NSLog("[RigLoader] \(label) loaded — children=\(wrapper.childNodes.count) materials=\(materialCount) bbox=(\(minB.x),\(minB.y),\(minB.z))→(\(maxB.x),\(maxB.y),\(maxB.z))")

        return wrapper
    }

    private func captureOriginalDiffuse(_ root: SCNNode) {
        forEachMaterial(root) { mat in
            let id = ObjectIdentifier(mat)
            if originalDiffuse[id] == nil, let c = mat.diffuse.contents {
                originalDiffuse[id] = c
            }
        }
    }

    func applyTint(_ root: SCNNode, color: BodyColor, restoreOriginal: Bool) {
        forEachMaterial(root) { mat in
            if restoreOriginal {
                let id = ObjectIdentifier(mat)
                if let original = originalDiffuse[id] {
                    mat.diffuse.contents = original
                }
            } else {
                let r = CGFloat(color.argb.r)
                let g = CGFloat(color.argb.g)
                let b = CGFloat(color.argb.b)
                mat.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1.0)
            }
        }
    }

    private func forceDoubleSided(_ root: SCNNode) {
        forEachMaterial(root) { mat in
            mat.isDoubleSided = true
        }
    }

    /// Returns 0 if no geometry found — leaves the avatar at the floor anchor,
    /// safer than guessing a lift.
    private func lowestMeshYInWrapper(_ wrapper: SCNNode) -> Float {
        var minY: Float = .greatestFiniteMagnitude
        func walk(_ node: SCNNode) {
            if node.geometry != nil {
                let (gMin, gMax) = node.boundingBox
                let corners: [SCNVector3] = [
                    SCNVector3(gMin.x, gMin.y, gMin.z),
                    SCNVector3(gMin.x, gMin.y, gMax.z),
                    SCNVector3(gMin.x, gMax.y, gMin.z),
                    SCNVector3(gMin.x, gMax.y, gMax.z),
                    SCNVector3(gMax.x, gMin.y, gMin.z),
                    SCNVector3(gMax.x, gMin.y, gMax.z),
                    SCNVector3(gMax.x, gMax.y, gMin.z),
                    SCNVector3(gMax.x, gMax.y, gMax.z),
                ]
                for c in corners {
                    let inWrapper = wrapper.convertPosition(c, from: node)
                    if Float(inWrapper.y) < minY { minY = Float(inWrapper.y) }
                }
            }
            for child in node.childNodes { walk(child) }
        }
        walk(wrapper)
        return minY == .greatestFiniteMagnitude ? 0 : minY
    }

    private func disableSubdivision(_ node: SCNNode) {
        if let g = node.geometry, g.subdivisionLevel != 0 {
            g.subdivisionLevel = 0
        }
        for child in node.childNodes { disableSubdivision(child) }
    }

    private func forEachMaterial(_ node: SCNNode, _ body: (SCNMaterial) -> Void) {
        if let mats = node.geometry?.materials {
            for m in mats { body(m) }
        }
        for child in node.childNodes { forEachMaterial(child, body) }
    }
}

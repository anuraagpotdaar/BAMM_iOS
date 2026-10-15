import Foundation
import SceneKit
import simd
import SwiftUI
import UIKit

@MainActor
final class SceneCoordinator: NSObject, SCNSceneRendererDelegate {

    enum Mode { case threeD, ar, overlay }

    private let pendingFrame: PendingFrameBox
    private(set) var loader = RigLoader()

    private weak var scene: SCNScene?
    private weak var rendererView: SCNView?

    private(set) var avatarContainer = SCNNode()
    private(set) var stageContainer = SCNNode()

    private var loadedRigRoot: SCNNode?
    private var loadedStageRoot: SCNNode?

    private var poseApplier: RigPoseApplier?

    private var contactShadowNode: SCNNode?

    private var rigGroundLift: Float = 0

    private(set) var lastRig: RigKind = .smpl
    private(set) var lastScene: SceneKind = .runway
    private(set) var lastColorIndex: Int = 0
    private(set) var lastMode: Mode = .threeD

    private var avatarPos = SIMD3<Float>(0, 0, 0)
    private var avatarRot = SIMD3<Float>(0, 0, 0)
    private var avatarUserScale: Float = 1
    private var modelScale: Float = 1

    private var stagePos = SIMD3<Float>(0, 0, 0)
    private var stageRot = SIMD3<Float>(0, 0, 0)
    private var stageScale: Float = 0.25

    var anchorLocalOffset = SIMD3<Float>(0, 0, 0)

    private(set) var placedWorldPos: SIMD3<Float>? = nil

    private var fitScale: Float? = nil

    var onFirstFrame: (@MainActor () -> Void)?
    private var firstFrameSeen = false

    init(pendingFrame: PendingFrameBox) {
        self.pendingFrame = pendingFrame
    }

    func attach(scene: SCNScene, view: SCNView) {
        self.scene = scene
        self.rendererView = view
        if avatarContainer.parent == nil { scene.rootNode.addChildNode(avatarContainer) }
        if stageContainer.parent == nil { scene.rootNode.addChildNode(stageContainer) }
    }

    func reparentAvatar(under parent: SCNNode) {
        avatarContainer.removeFromParentNode()
        parent.addChildNode(avatarContainer)
    }

    func detachAvatarToWorld() {
        guard let scene = self.scene else { return }
        avatarContainer.removeFromParentNode()
        scene.rootNode.addChildNode(avatarContainer)
    }

    func applyState(_ state: AppState, mode: Mode) {
        if lastMode != mode { fitScale = nil; poseApplier?.resetMotionAnchor() }
        lastMode = mode

        if state.firstFrameNeedsReset {
            firstFrameSeen = false
            state.firstFrameNeedsReset = false
        }

        let rigChanged = lastRig != state.rigKind
        if loadedRigRoot == nil || rigChanged {
            loadRig(state.rigKind)
            lastRig = state.rigKind
            applyColor(index: state.colorIndex)
            lastColorIndex = state.colorIndex
        }

        if mode == .threeD {
            if loadedStageRoot == nil || lastScene != state.sceneKind {
                loadStage(state.sceneKind)
                lastScene = state.sceneKind
            }
            stageContainer.isHidden = false
        } else {
            stageContainer.isHidden = true
        }

        if lastColorIndex != state.colorIndex {
            applyColor(index: state.colorIndex)
            lastColorIndex = state.colorIndex
        }

        if mode == .ar || mode == .overlay {
            avatarPos = .zero
            avatarRot = .zero
            avatarUserScale = 1
        } else {
            avatarPos = SIMD3<Float>(state.avatarPosX, state.avatarPosY, state.avatarPosZ)
            avatarRot = SIMD3<Float>(state.avatarRotX, state.avatarRotY, state.avatarRotZ)
            avatarUserScale = state.avatarScale
        }
        modelScale = state.modelScale
        stagePos = SIMD3<Float>(state.stagePosX, state.stagePosY, state.stagePosZ)
        stageRot = SIMD3<Float>(state.stageRotX, state.stageRotY, state.stageRotZ)
        stageScale = state.stageScale

        applyTransforms()
    }

    func forceReapplyTransforms() {
        applyTransforms()
    }

    func placeAvatar(at worldPos: SIMD3<Float>) {
        placedWorldPos = worldPos
        poseApplier?.resetMotionAnchor()
        applyTransforms()
    }

    func setAvatarTransform(
        pos: SIMD3<Float>, rotDeg: SIMD3<Float>, userScale: Float, modelScale: Float
    ) {
        avatarPos = pos
        avatarRot = rotDeg
        avatarUserScale = userScale
        self.modelScale = modelScale
        applyTransforms()
    }

    func setStageTransform(
        pos: SIMD3<Float>, rotDeg: SIMD3<Float>, scale: Float
    ) {
        stagePos = pos
        stageRot = rotDeg
        stageScale = scale
        applyTransforms()
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let frame = pendingFrame.take() else { return }
        Task { @MainActor in
            guard let applier = self.poseApplier, applier.isReady else { return }
            applier.apply(frame)
            if self.lastMode == .overlay, self.fitScale == nil, applier.bindChainLength > 0.05 {
                let l = RigPoseApplier.chainLength(frame.xyz)
                if l > 0.05 {
                    self.fitScale = l / applier.bindChainLength
                    NSLog("[SceneCoordinator] overlay fitScale=\(l / applier.bindChainLength) (subject chain \(l) m, rig \(applier.bindChainLength))")
                }
            }
            self.applyTransforms()
            if !self.firstFrameSeen {
                self.firstFrameSeen = true
                NSLog("[SceneCoordinator] first frame applied in mode \(self.lastMode)")
                self.onFirstFrame?()
            }
        }
    }

    func resetFirstFrame() { firstFrameSeen = false; fitScale = nil; poseApplier?.resetMotionAnchor() }

    private func loadRig(_ rig: RigKind) {
        if let old = loadedRigRoot { old.removeFromParentNode() }
        loadedRigRoot = nil
        poseApplier = nil

        avatarContainer.simdPosition = .zero
        avatarContainer.simdScale = SIMD3<Float>(repeating: 1)
        avatarContainer.simdEulerAngles = .zero
        avatarContainer.isHidden = false
        fitScale = nil

        do {
            let loaded = try loader.load(rig)
            avatarContainer.addChildNode(loaded.rigRoot)
            loadedRigRoot = loaded.rigRoot
            rigGroundLift = loaded.groundLift

            let applier = RigPoseApplier.forSmpl(
                rigRoot: loaded.rigRoot,
                bonesByName: loaded.bonesByName,
                avatarContainer: avatarContainer
            )
            poseApplier = applier
            NSLog("[SceneCoordinator] rig=\(rig.rawValue) loaded. applier.isReady=\(applier.isReady) matched=\(applier.matchedCount)/\(SkeletonTopology.jointCount) body=\(applier.coreMatchedCount)/22 missingBody=\(applier.missingJointIndices) hipsLift=\(applier.hipsLift)")

            if let pelvis = loaded.bonesByName[SkeletonTopology.normalize("Pelvis")]
                ?? loaded.bonesByName[SkeletonTopology.normalize("mixamorig:Hips")],
               let head = loaded.bonesByName[SkeletonTopology.normalize("Head")]
                ?? loaded.bonesByName[SkeletonTopology.normalize("mixamorig:Head")] {
                let p = pelvis.simdWorldTransform.columns.3
                let h = head.simdWorldTransform.columns.3
                NSLog("[SceneCoordinator] orient pelvis=(\(p.x),\(p.y),\(p.z)) head=(\(h.x),\(h.y),\(h.z)) Δ=(\(h.x - p.x), \(h.y - p.y), \(h.z - p.z))")
            }
        } catch {
            NSLog("[SceneCoordinator] failed to load rig \(rig.rawValue): \(error)")
        }
    }

    private func loadStage(_ scene: SceneKind) {
        if let old = loadedStageRoot { old.removeFromParentNode() }
        loadedStageRoot = nil
        do {
            let root = try loader.loadStage(scene)
            stageContainer.addChildNode(root)
            loadedStageRoot = root
        } catch {
            NSLog("[SceneCoordinator] failed to load stage \(scene.rawValue): \(error)")
        }
    }

    private func ensureContactShadow() {
        guard contactShadowNode == nil else { return }
        let plane = SCNPlane(width: 0.6, height: 0.6)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.black
        mat.transparency = 0.35
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.lightingModel = .constant
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
        node.isHidden = true
        avatarContainer.addChildNode(node)
        contactShadowNode = node
    }

    private func applyColor(index: Int) {
        guard let root = loadedRigRoot else { return }
        let entry = BODY_COLORS[index]
        let isDefault = (index == 0)
        loader.applyTint(root, color: entry, restoreOriginal: isDefault)
    }

    private func applyTransforms() {
        if lastMode == .overlay {
            applyOverlayTransforms()
            return
        }
        avatarContainer.isHidden = false

        let hipsLift = poseApplier?.hipsLift ?? 0
        let effScale = modelScale * avatarUserScale
        let yLift = (rigGroundLift + hipsLift) * effScale
        let motion = (poseApplier?.motionTranslation ?? .zero) * effScale

        avatarContainer.simdScale = SIMD3<Float>(repeating: effScale)
        let basePos: SIMD3<Float>
        if lastMode == .ar, let p = placedWorldPos {
            basePos = p
        } else {
            basePos = .zero
        }
        avatarContainer.simdPosition = SIMD3<Float>(
            basePos.x + anchorLocalOffset.x + avatarPos.x + motion.x,
            basePos.y + anchorLocalOffset.y + yLift + avatarPos.y + motion.y,
            basePos.z + anchorLocalOffset.z + avatarPos.z + motion.z
        )
        avatarContainer.simdEulerAngles = SIMD3<Float>(
            avatarRot.x.degreesToRadians,
            avatarRot.y.degreesToRadians,
            avatarRot.z.degreesToRadians
        )

        ensureContactShadow()
        contactShadowNode?.simdPosition = SIMD3<Float>(0, -rigGroundLift + 0.0005, 0)
        contactShadowNode?.isHidden = (lastMode != .ar) || (placedWorldPos == nil)

        stageContainer.simdScale = SIMD3<Float>(repeating: stageScale)
        stageContainer.simdPosition = stagePos
        stageContainer.simdEulerAngles = SIMD3<Float>(
            stageRot.x.degreesToRadians,
            stageRot.y.degreesToRadians,
            stageRot.z.degreesToRadians
        )
    }

    private func applyOverlayTransforms() {
        stageContainer.isHidden = true
        contactShadowNode?.isHidden = true
        guard let applier = poseApplier, let root = applier.lastRootPosition else {
            avatarContainer.isHidden = true
            return
        }
        let eff = modelScale * (fitScale ?? 1)
        avatarContainer.isHidden = false
        avatarContainer.simdScale = SIMD3<Float>(repeating: eff)
        avatarContainer.simdEulerAngles = .zero
        avatarContainer.simdPosition = root - applier.bindHipsAvatarLocal * eff
    }
}

private extension Float {
    var degreesToRadians: Float { self * .pi / 180 }
}

import Foundation
import SceneKit
import simd
import SwiftUI
import UIKit

@MainActor
final class SceneCoordinator: NSObject, SCNSceneRendererDelegate {

    enum Mode { case threeD, ar }

    private let pendingFrame: PendingFrameBox
    private(set) var loader = RigLoader()

    private weak var scene: SCNScene?
    private weak var rendererView: SCNView?

    /// Parents the loaded rigRoot. Its transform carries UI-controlled
    /// translate/rotate/scale — kept separate from rigRoot so the pose applier
    /// can mutate joints without fighting the UI.
    private(set) var avatarContainer = SCNNode()
    private(set) var stageContainer = SCNNode()

    private var loadedRigRoot: SCNNode?
    private var loadedStageRoot: SCNNode?

    private var poseApplier: RigPoseApplier?

    /// Translucent disc parented under `avatarContainer` for an AR-mode
    /// contact shadow; the camera feed has no real lighting otherwise.
    private var contactShadowNode: SCNNode?

    /// Lifts the rig so feet rest on Y=0. Read from the asset bbox at load.
    private var rigGroundLift: Float = 0

    private(set) var lastRig: RigKind = .smpl
    private(set) var lastScene: SceneKind = .runway
    private(set) var lastColorIndex: Int = 0
    private(set) var lastMode: Mode = .threeD

    private var avatarPos = SIMD3<Float>(0, 0, 0)
    private var avatarRot = SIMD3<Float>(0, 0, 0) // degrees
    private var avatarUserScale: Float = 1
    private var modelScale: Float = 1

    private var stagePos = SIMD3<Float>(0, 0, 0)
    private var stageRot = SIMD3<Float>(0, 0, 0) // degrees
    private var stageScale: Float = 0.25

    var anchorLocalOffset = SIMD3<Float>(0, 0, 0)

    /// World position of the latest tap-to-place; nil before first tap.
    private(set) var placedWorldPos: SIMD3<Float>? = nil

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

        // AR mode ignores the avatar-editor offsets so the rig stays anchored
        // at the tap point. modelScale (FAB) still applies in both modes.
        if mode == .ar {
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
            self.applyTransforms()
            if !self.firstFrameSeen {
                self.firstFrameSeen = true
                self.onFirstFrame?()
            }
        }
    }

    func resetFirstFrame() { firstFrameSeen = false }

    private func loadRig(_ rig: RigKind) {
        if let old = loadedRigRoot { old.removeFromParentNode() }
        loadedRigRoot = nil
        poseApplier = nil

        // Reset to identity so the new rig's bind-pose capture sees joints in
        // their true local frame; otherwise the previous rig's groundLift /
        // scale leaks through and the new rig renders squashed.
        avatarContainer.simdPosition = .zero
        avatarContainer.simdScale = SIMD3<Float>(repeating: 1)
        avatarContainer.simdEulerAngles = .zero

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
            NSLog("[SceneCoordinator] rig=\(rig.rawValue) loaded. applier.isReady=\(applier.isReady) matched=\(applier.matchedCount)/22 missingJoints=\(applier.missingJointIndices) hipsLift=\(applier.hipsLift)")

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
        // hipsLift fallback must be 0: the only shipped factory (forSmpl)
        // passes 0, and a non-zero fallback during the load window levitates
        // the avatar.
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

        // Local -rigGroundLift cancels the container's yLift so the disc
        // lands at world Y == placedWorldPos.y. +0.5 mm avoids z-fighting.
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
}

private extension Float {
    var degreesToRadians: Float { self * .pi / 180 }
}

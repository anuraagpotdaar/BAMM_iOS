import SwiftUI
import SceneKit
import UIKit

struct SceneKit3DViewRepresentable: UIViewRepresentable {
    @Bindable var state: AppState

    func makeCoordinator() -> SceneCoordinator {
        SceneCoordinator(pendingFrame: state.session.pendingFrame)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = UIColor(red: 0.06, green: 0.08, blue: 0.10, alpha: 1)
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.minimumVerticalAngle = -10
        view.defaultCameraController.maximumVerticalAngle = 80
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        view.autoenablesDefaultLighting = true
        // SCNView pauses its loop when nothing in the scene-graph animates;
        // direct simdTransform writes don't trigger it, so force continuous.
        view.isPlaying = true
        view.rendersContinuously = true

        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.06, green: 0.08, blue: 0.10, alpha: 1)

        let cameraNode = makeCamera()
        scene.rootNode.addChildNode(cameraNode)

        addLights(scene)

        view.scene = scene
        view.pointOfView = cameraNode

        context.coordinator.attach(scene: scene, view: view)
        context.coordinator.applyState(state, mode: .threeD)
        let s = state
        context.coordinator.onFirstFrame = { s.hasFirstFrame = true }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.applyState(state, mode: .threeD)
    }

    private func makeCamera() -> SCNNode {
        let cam = SCNCamera()
        cam.fieldOfView = 60
        cam.zNear = 0.05
        cam.zFar = 200
        let n = SCNNode()
        n.name = "MainCamera"
        n.camera = cam
        n.position = SCNVector3(0, 1.5, 3)
        n.look(at: SCNVector3(0, 0.9, 0))
        return n
    }

    private func addLights(_ scene: SCNScene) {
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1800
        sun.castsShadow = true
        sun.shadowSampleCount = 8
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 6, 0)
        scene.rootNode.addChildNode(sunNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 600
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi / 4, 0)
        scene.rootNode.addChildNode(fillNode)

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 400
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)
    }
}

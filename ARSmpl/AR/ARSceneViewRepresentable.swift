import SwiftUI
import SceneKit
import ARKit
import UIKit

/// Uses the AR session for raycasting only; writes `simdWorldTransform` directly
/// instead of going through ARAnchor (anchor reparenting timing was unreliable).
struct ARSceneViewRepresentable: UIViewRepresentable {
    @Bindable var state: AppState
    @Binding var trackingFailureReason: ARCamera.TrackingState.Reason?
    @Binding var anchorIsPlaced: Bool

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(scene: SceneCoordinator(pendingFrame: state.session.pendingFrame))
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.backgroundColor = .black
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        view.session.delegate = context.coordinator

        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = .horizontal
        cfg.environmentTexturing = .automatic
        cfg.isLightEstimationEnabled = true
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            cfg.frameSemantics.insert(.sceneDepth)
        }
        view.session.run(cfg, options: [.resetTracking, .removeExistingAnchors])

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(ARCoordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(ARCoordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)

        context.coordinator.attach(view: view)
        context.coordinator.scene.attach(scene: view.scene, view: view)
        context.coordinator.scene.applyState(state, mode: .ar)
        let s = state
        context.coordinator.scene.onFirstFrame = { s.hasFirstFrame = true }
        context.coordinator.bindings = ARCoordinator.Bindings(
            trackingFailureReason: $trackingFailureReason,
            anchorIsPlaced: $anchorIsPlaced
        )
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.scene.applyState(state, mode: .ar)
    }
}

@MainActor
final class ARCoordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate, UIGestureRecognizerDelegate {

    struct Bindings {
        var trackingFailureReason: Binding<ARCamera.TrackingState.Reason?>
        var anchorIsPlaced: Binding<Bool>
    }

    let scene: SceneCoordinator
    var bindings: Bindings?

    private weak var arView: ARSCNView?

    init(scene: SceneCoordinator) {
        self.scene = scene
    }

    func attach(view: ARSCNView) {
        self.arView = view
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = arView else { return }
        let p = gesture.location(in: view)
        guard let hit = raycast(at: p) else {
            NSLog("[ARCoordinator] tap raycast missed at \(p)")
            return
        }
        let t = hit.worldTransform.columns.3
        let worldPos = SIMD3<Float>(t.x, t.y, t.z)
        NSLog("[ARCoordinator] tap → world position (\(t.x), \(t.y), \(t.z))")
        scene.placeAvatar(at: worldPos)
        bindings?.anchorIsPlaced.wrappedValue = true
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = arView, scene.placedWorldPos != nil else { return }
        guard gesture.state == .began || gesture.state == .changed else { return }
        let p = gesture.location(in: view)
        guard let hit = raycast(at: p) else { return }
        let t = hit.worldTransform.columns.3
        let worldPos = SIMD3<Float>(t.x, t.y, t.z)
        scene.placeAvatar(at: worldPos)
    }

    private func raycast(at point: CGPoint) -> ARRaycastResult? {
        guard let view = arView else { return nil }
        if let q = view.raycastQuery(from: point, allowing: .existingPlaneInfinite, alignment: .horizontal) {
            let hits: [ARRaycastResult] = view.session.raycast(q)
            if let first = hits.first { return first }
        }
        if let q = view.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .horizontal) {
            let hits: [ARRaycastResult] = view.session.raycast(q)
            return hits.first
        }
        return nil
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        scene.renderer(renderer, updateAtTime: time)
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        let reason: ARCamera.TrackingState.Reason?
        switch state {
        case .limited(let r): reason = r
        case .normal:         reason = nil
        case .notAvailable:   reason = nil
        }
        Task { @MainActor in
            self.bindings?.trackingFailureReason.wrappedValue = reason
        }
    }
}

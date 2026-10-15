import SwiftUI
import SceneKit
import AVFoundation
import UIKit
import os

struct OverlaySceneViewRepresentable: UIViewRepresentable {
    @Bindable var state: AppState

    func makeCoordinator() -> OverlayCoordinator {
        OverlayCoordinator(pendingFrame: state.session.pendingFrame)
    }

    func makeUIView(context: Context) -> OverlayContainerView {
        let view = OverlayContainerView()
        view.scnView.delegate = context.coordinator
        context.coordinator.attach(view: view)
        context.coordinator.scene.attach(scene: view.scnView.scene!, view: view.scnView)
        context.coordinator.scene.applyState(state, mode: .overlay)
        let s = state
        context.coordinator.scene.onFirstFrame = { s.hasFirstFrame = true }
        context.coordinator.takeClock(of: state.session)
        context.coordinator.update(videoURL: state.session.gemxVideoURL ?? state.pickedVideo?.url,
                                   motion: state.session.gemxCamera)
        return view
    }

    func updateUIView(_ view: OverlayContainerView, context: Context) {
        context.coordinator.takeClock(of: state.session)
        context.coordinator.scene.applyState(state, mode: .overlay)
        context.coordinator.update(videoURL: state.session.gemxVideoURL ?? state.pickedVideo?.url,
                                   motion: state.session.gemxCamera)
    }

    static func dismantleUIView(_ view: OverlayContainerView, coordinator: OverlayCoordinator) {
        coordinator.teardown()
    }
}

final class OverlayContainerView: UIView {
    let playerLayer = AVPlayerLayer()
    let scnView = SCNView(frame: .zero)
    let cameraNode = SCNNode()

    var videoAspect: CGFloat? = nil { didSet { if videoAspect != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)

        scnView.backgroundColor = .clear
        scnView.isOpaque = false
        scnView.antialiasingMode = .multisampling4X
        scnView.preferredFramesPerSecond = 60
        scnView.autoenablesDefaultLighting = true
        scnView.allowsCameraControl = false
        scnView.isPlaying = true
        scnView.rendersContinuously = true

        let scene = SCNScene()
        scene.background.contents = nil
        let cam = SCNCamera()
        cam.zNear = 0.05
        cam.zFar = 100
        cam.fieldOfView = 55
        cam.projectionDirection = .vertical
        cameraNode.name = "OverlayCamera"
        cameraNode.camera = cam
        cameraNode.position = SCNVector3Zero
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1200
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 8, 0)
        scene.rootNode.addChildNode(keyNode)
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 500
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        scnView.scene = scene
        scnView.pointOfView = cameraNode
        addSubview(scnView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        guard let a = videoAspect, a > 0, bounds.width > 0, bounds.height > 0 else {
            scnView.frame = bounds
            return
        }
        let w = min(bounds.width, bounds.height * a)
        let h = w / a
        scnView.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    func setIntrinsics(_ c: GemxCamera) {
        let W = Float(c.width), H = Float(c.height)
        let n: Float = 0.05, f: Float = 100
        let rows: [SIMD4<Float>] = [
            SIMD4<Float>(2 * c.fx / W, 0, (W - 2 * c.cx) / W, 0),
            SIMD4<Float>(0, 2 * c.fy / H, (2 * c.cy - H) / H, 0),
            SIMD4<Float>(0, 0, -(f + n) / (f - n), -2 * f * n / (f - n)),
            SIMD4<Float>(0, 0, -1, 0),
        ]
        cameraNode.camera?.projectionTransform = SCNMatrix4(simd_float4x4(rows: rows))
        videoAspect = CGFloat(c.aspect)
    }
}

@MainActor
final class OverlayCoordinator: NSObject, SCNSceneRendererDelegate {
    let scene: SceneCoordinator
    private let pendingFrame: PendingFrameBox
    private weak var view: OverlayContainerView?

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var currentMotionID: UUID?
    private var foregroundObserver: NSObjectProtocol?

    private weak var clockedSession: BammSession?

    private struct Clip: Sendable {
        let frames: [JointFrame]
        let frameTime: Double
    }

    private let clip = OSAllocatedUnfairLock<Clip?>(initialState: nil)
    private nonisolated(unsafe) var renderPlayer: AVQueuePlayer?

    init(pendingFrame: PendingFrameBox) {
        self.pendingFrame = pendingFrame
        self.scene = SceneCoordinator(pendingFrame: pendingFrame)
        super.init()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.player?.play() }
        }
    }

    func attach(view: OverlayContainerView) {
        self.view = view
    }

    func takeClock(of session: BammSession) {
        if let old = clockedSession, old !== session { old.externalClock = false; old.overlayTransport = nil }
        clockedSession = session
        session.externalClock = true
        session.overlayTransport = self
        loopEnabled = session.playbackLoop
        if session.playbackPaused { player?.pause() }
    }

    func update(videoURL: URL?, motion: CameraMotion?) {
        let videoChanged = videoURL != currentURL
        let motionChanged = motion?.id != currentMotionID
        if videoChanged {
            currentURL = videoURL
            if motion == nil, let url = videoURL { loadAspect(from: url) }
            NSLog("[Overlay] video → %@", videoURL?.lastPathComponent ?? "none")
        }
        if motionChanged {
            currentMotionID = motion?.id
            if let m = motion {
                clip.withLock { $0 = Clip(frames: m.frames, frameTime: max(m.frameTime, 1.0 / 240.0)) }
                view?.setIntrinsics(m.camera)
                scene.resetFirstFrame()
                NSLog("[Overlay] motion: %d frames, %dx%d fx=%.1f", m.frames.count, m.camera.width, m.camera.height, m.camera.fx)
            } else {
                clip.withLock { $0 = nil }
                pendingFrame.clear()
            }
        }

        if videoChanged || (motionChanged && motion != nil) {
            startPlayer(url: videoURL)
        }
    }

    private func startPlayer(url: URL?) {
        looper = nil
        player?.pause()
        player = nil
        renderPlayer = nil
        guard let url else {
            view?.playerLayer.player = nil
            return
        }
        let p = AVQueuePlayer()
        p.isMuted = true
        looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
        view?.playerLayer.player = p
        player = p
        renderPlayer = p
        p.play()
    }

    private func loadAspect(from url: URL) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, t) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            let r = size.applying(t)
            let w = abs(r.width), h = abs(r.height)
            guard w > 0, h > 0 else { return }
            await MainActor.run { self?.view?.videoAspect = w / h }
        }
    }

    func teardown() {

        clockedSession?.externalClock = false
        clockedSession?.overlayTransport = nil
        clockedSession = nil
        player?.pause()
        looper = nil
        player = nil
        renderPlayer = nil
        view?.playerLayer.player = nil
        clip.withLock { $0 = nil }
        if let o = foregroundObserver { NotificationCenter.default.removeObserver(o) }
        foregroundObserver = nil
    }

    private nonisolated(unsafe) var lastDiag: TimeInterval = 0
    private nonisolated(unsafe) var lastReportedFrame: Int = -1
    private nonisolated(unsafe) var loopEnabled: Bool = true

    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if let p = renderPlayer {
            let secs = p.currentTime().seconds
            if let c = clip.withLock({ $0 }), !c.frames.isEmpty, secs.isFinite {
                let i = min(max(Int(secs / c.frameTime), 0), c.frames.count - 1)
                pendingFrame.set(c.frames[i])
                if i != lastReportedFrame {
                    lastReportedFrame = i
                    let stopAtEnd = !loopEnabled && i >= c.frames.count - 1
                    Task { @MainActor in
                        self.clockedSession?.reportPlaybackFrame(i)
                        if stopAtEnd, let s = self.clockedSession, !s.playbackPaused { s.playbackPaused = true }
                    }
                }
            }
            if time - lastDiag > 5 {
                lastDiag = time
                let item = p.currentItem
                NSLog("[Overlay] player t=%.2f rate=%.1f status=%d item=%@ err=%@", secs, p.rate, p.status.rawValue,
                      item.map { "\($0.status.rawValue) \(String(format: "%.1f", $0.duration.seconds))s" } ?? "nil",
                      (p.error ?? item?.error).map { String(describing: $0) } ?? "-")
            }
        }
        scene.renderer(renderer, updateAtTime: time)
    }
}

extension OverlayCoordinator: PlaybackTransport {
    func seek(to seconds: Double) {
        guard let p = player else { return }
        p.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func setPaused(_ paused: Bool) {
        if paused { player?.pause() } else { player?.play() }
    }

    func setLoop(_ loop: Bool) { loopEnabled = loop }
}

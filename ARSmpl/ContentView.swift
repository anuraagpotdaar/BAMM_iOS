import SwiftUI

struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        ZStack {
            if !appState.hasPickedMode {
                WelcomeScreen(state: appState)
            } else {
                ARMainView(state: appState)
            }
        }
        .sheet(isPresented: $appState.showUrlDialog) {
            BackendUrlDialog(state: appState)
        }
        .animation(.easeInOut(duration: 0.2), value: appState.hasPickedMode)
        .onAppear { appState.runAutoVideoIfRequested() }
    }
}

enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case ar
    case threeD = "3d"
    case overlay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ar:      return "AR"
        case .threeD:  return "3D"
        case .overlay: return "Overlay"
        }
    }

    var systemImage: String {
        switch self {
        case .ar:      return "arkit"
        case .threeD:  return "cube.fill"
        case .overlay: return "person.and.background.dotted"
        }
    }

    static func available(for model: BackendModel) -> [ViewMode] {
        model.takesVideo ? [.ar, .threeD, .overlay] : [.ar, .threeD]
    }
}

@Observable
@MainActor
final class AppState {
    var hasPickedMode: Bool = false
    var viewMode: ViewMode = .ar
    var arMode: Bool { viewMode == .ar }
    var showUrlDialog: Bool = false

    var rigKind: RigKind = .smpl {
        didSet {
            guard rigKind != oldValue else { return }
            saveAvatarTransform(for: oldValue)
            loadAvatarTransform()
        }
    }
    var sceneKind: SceneKind = .runway {
        didSet {
            guard sceneKind != oldValue else { return }
            saveStageTransform(for: oldValue)
            loadStageTransform()
        }
    }
    var colorIndex: Int = 0

    var backendModel: BackendModel = BackendUrlStore.shared.model
    var backendMode: BackendMode = BackendUrlStore.shared.mode
    var backendUrl: String = BackendUrlStore.shared.current

    var pickedVideo: PickedVideo? = nil
    var lastImportError: String? = nil

    var hasStartedSession: Bool = false
    var hasFirstFrame: Bool = false

    var firstFrameNeedsReset: Bool = false

    var session: BammSession

    var avatarRotX: Float = 0
    var avatarRotY: Float = 0
    var avatarRotZ: Float = 0
    var avatarScale: Float = 1.0
    var avatarPosX: Float = 0
    var avatarPosY: Float = 0
    var avatarPosZ: Float = 0
    var modelScale: Float = 1.0

    var stageRotX: Float = 0
    var stageRotY: Float = 0
    var stageRotZ: Float = 0
    var stageScale: Float = 0.25
    var stagePosX: Float = 0
    var stagePosY: Float = 0
    var stagePosZ: Float = 0

    init() {

        let model = BackendUrlStore.shared.model
        let mode = BackendUrlStore.shared.mode
        let url = BackendUrlStore.shared.url(model: model, mode: mode)
        self.backendModel = model
        self.backendMode = mode
        self.backendUrl = url
        self.session = BammSession.build(model: model, mode: mode, baseUrl: url)
        loadAvatarTransform()
        loadStageTransform()
    }

    func rebuildSession() {
        session.shutdown()
        session = BammSession.build(model: backendModel, mode: backendMode, baseUrl: backendUrl)
    }

    func setBackendModel(_ model: BackendModel) {
        guard model != backendModel else { return }
        backendModel = model
        BackendUrlStore.shared.model = model
        backendUrl = BackendUrlStore.shared.url(model: model, mode: backendMode)
        if !ViewMode.available(for: model).contains(viewMode) { viewMode = .threeD }
        rebuildSession()
    }

    func setBackendMode(_ mode: BackendMode) {
        guard mode != backendMode else { return }
        backendMode = mode
        BackendUrlStore.shared.mode = mode
        backendUrl = BackendUrlStore.shared.url(model: backendModel, mode: mode)
        rebuildSession()
    }

    private func avatarKey(_ rig: RigKind, _ suffix: String) -> String {
        "avatar_\(rig.rawValue)_\(suffix)"
    }
    private func stageKey(_ scene: SceneKind, _ suffix: String) -> String {
        "stage_\(scene.rawValue)_\(suffix)"
    }

    func loadAvatarTransform() {
        let saved = TransformStore.shared.load()
        let rig = rigKind
        avatarRotX = saved[avatarKey(rig, "rot_x")] ?? 0
        avatarRotY = saved[avatarKey(rig, "rot_y")] ?? 0
        avatarRotZ = saved[avatarKey(rig, "rot_z")] ?? 0
        avatarScale = saved[avatarKey(rig, "scale")] ?? 1.0
        avatarPosX = saved[avatarKey(rig, "pos_x")] ?? 0
        avatarPosY = saved[avatarKey(rig, "pos_y")] ?? 0
        avatarPosZ = saved[avatarKey(rig, "pos_z")] ?? 0
        modelScale = saved[avatarKey(rig, "model_scale")] ?? 1.0
    }

    func loadStageTransform() {
        let saved = TransformStore.shared.load()
        let scene = sceneKind
        stageRotX = saved[stageKey(scene, "rot_x")] ?? 0
        stageRotY = saved[stageKey(scene, "rot_y")] ?? 0
        stageRotZ = saved[stageKey(scene, "rot_z")] ?? 0
        stageScale = saved[stageKey(scene, "scale")] ?? scene.defaultScale
        stagePosX = saved[stageKey(scene, "pos_x")] ?? 0
        stagePosY = saved[stageKey(scene, "pos_y")] ?? 0
        stagePosZ = saved[stageKey(scene, "pos_z")] ?? 0
    }

    func saveAvatarTransform() { saveAvatarTransform(for: rigKind) }
    func saveStageTransform()  { saveStageTransform(for: sceneKind) }

    func saveAvatarTransform(for rig: RigKind) {
        TransformStore.shared.save([
            avatarKey(rig, "rot_x"): avatarRotX,
            avatarKey(rig, "rot_y"): avatarRotY,
            avatarKey(rig, "rot_z"): avatarRotZ,
            avatarKey(rig, "scale"): avatarScale,
            avatarKey(rig, "pos_x"): avatarPosX,
            avatarKey(rig, "pos_y"): avatarPosY,
            avatarKey(rig, "pos_z"): avatarPosZ,
            avatarKey(rig, "model_scale"): modelScale,
        ])
    }

    func saveStageTransform(for scene: SceneKind) {
        TransformStore.shared.save([
            stageKey(scene, "rot_x"): stageRotX,
            stageKey(scene, "rot_y"): stageRotY,
            stageKey(scene, "rot_z"): stageRotZ,
            stageKey(scene, "scale"): stageScale,
            stageKey(scene, "pos_x"): stagePosX,
            stageKey(scene, "pos_y"): stagePosY,
            stageKey(scene, "pos_z"): stagePosZ,
        ])
    }

    func saveModelScale() {
        TransformStore.shared.saveOne(avatarKey(rigKind, "model_scale"), modelScale)
    }

    func runAutoVideoIfRequested() {
        let d = UserDefaults.standard

        if let plan = d.string(forKey: "gemxBench"), !plan.isEmpty {
            let resume = d.string(forKey: "gemxBenchResume").flatMap { $0.isEmpty ? nil : $0 }
            Task { await GemxBenchmark.run(kind: plan, resume: resume) { line in NSLog("%@", line); print(line) } }
            return
        }
        guard var path = d.string(forKey: "gemxAutoVideo"), !path.isEmpty else { return }

        if !path.hasPrefix("/"), let u = Bundle.main.url(forResource: (path as NSString).deletingPathExtension, withExtension: "mp4", subdirectory: "BenchClips") { path = u.path }
        let mode = BackendMode(rawValue: d.string(forKey: "gemxAutoMode") ?? "onDevice") ?? .onDevice
        setBackendModel(.gemx)
        setBackendMode(mode)
        if let url = d.string(forKey: "gemxAutoUrl"), !url.isEmpty {
            BackendUrlStore.shared.setUrl(url, model: .gemx, mode: mode)
            backendUrl = url
            rebuildSession()
        }
        viewMode = ViewMode(rawValue: d.string(forKey: "gemxAutoView") ?? "3d") ?? .threeD
        if let r = d.string(forKey: "gemxAutoRig"), let rig = RigKind(rawValue: r) { rigKind = rig }

        if let s = d.object(forKey: "gemxAutoStep") as? Int, (1...6).contains(s) { GemxSettings.shared.sampleStep = s }
        if d.object(forKey: "gemxAutoFlip") != nil { GemxSettings.shared.flipTest = d.bool(forKey: "gemxAutoFlip") }
        if viewMode == .ar { viewMode = .threeD }
        hasPickedMode = true
        let video = PickedVideo(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent)
        pickedVideo = video
        NSLog("[GemxAuto] starting \(mode.rawValue) on \(path)")
        session.startVideo(video)
        hasStartedSession = true

        let cycle = d.integer(forKey: "gemxAutoCycle")
        guard cycle > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.session.state != .streaming { try? await Task.sleep(nanoseconds: 500_000_000) }
            let order: [ViewMode] = [.threeD, .ar, .overlay, .threeD, .overlay, .ar, .threeD]
            for (k, v) in order.enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(cycle) * 1_000_000_000)
                self.viewMode = v
                NSLog("[GemxAuto] view → \(v.rawValue)")
                if k == 4 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    NSLog("[GemxAuto] re-running the clip")
                    self.session.startVideo(video)
                }
            }
        }
    }
}

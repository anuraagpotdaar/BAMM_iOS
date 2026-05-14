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
    }
}

@Observable
@MainActor
final class AppState {
    var hasPickedMode: Bool = false
    var arMode: Bool = true
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

    var hasStartedSession: Bool = false
    var hasFirstFrame: Bool = false
    /// Read & cleared by SceneCoordinator to re-arm the LoadingOverlay after reset.
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
        // Read the store directly — observed accessors touch other not-yet-init
        // stored properties through the @Observable macro's expansion.
        let model = BackendUrlStore.shared.model
        let mode = BackendUrlStore.shared.mode
        let url = BackendUrlStore.shared.url(model: model, mode: mode)
        self.backendModel = model
        self.backendMode = mode
        self.backendUrl = url
        self.session = BammSession.build(mode: mode, baseUrl: url)
        loadAvatarTransform()
        loadStageTransform()
    }

    func rebuildSession() {
        session.shutdown()
        session = BammSession.build(mode: backendMode, baseUrl: backendUrl)
    }

    func setBackendModel(_ model: BackendModel) {
        guard model != backendModel else { return }
        backendModel = model
        BackendUrlStore.shared.model = model
        backendUrl = BackendUrlStore.shared.url(model: model, mode: backendMode)
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
}

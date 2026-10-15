import SwiftUI
import ARKit

struct ARMainView: View {
    @Bindable var state: AppState

    @State private var trackingFailureReason: ARCamera.TrackingState.Reason? = nil
    @State private var anchorIsPlaced: Bool = false
    @State private var motionText: String = "walk forward"
    @State private var scaleFabExpanded: Bool = false
    @State private var showSettings: Bool = false
    @State private var showStageEditor: Bool = false
    @State private var showAvatarEditor: Bool = false
    @FocusState private var inputFocused: Bool

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ZStack(alignment: .top) {
            sceneView
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    if let err = state.session.lastError {
                        ErrorBar(message: err) { state.session.clearError() }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if let err = state.lastImportError {
                        ErrorBar(message: err) { state.lastImportError = nil }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    topEndCluster
                }
                .padding(.horizontal, GlassTokens.edgeInset)
                .padding(.top, 60)

                Spacer(minLength: 0)

                bottomStrip
                    .padding(.bottom, 40)
            }
        }
        .animation(.snappy(duration: 0.25), value: state.session.lastError)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                state: state,
                onChangeUrl: {
                    showSettings = false
                    state.showUrlDialog = true
                },
                onOpenStageEditor: {
                    showSettings = false
                    showStageEditor = true
                },
                onOpenAvatarEditor: {
                    showSettings = false
                    showAvatarEditor = true
                },
                onReset: {
                    state.session.reset()
                    state.hasStartedSession = false
                    state.hasFirstFrame = false
                    state.firstFrameNeedsReset = true
                    anchorIsPlaced = false
                    showSettings = false
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStageEditor) {
            TransformEditor(title: "Stage transform", values: stageBindings) {
                state.saveStageTransform()
                showStageEditor = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAvatarEditor) {
            TransformEditor(title: "Avatar transform", values: avatarBindings) {
                state.saveAvatarTransform()
                showAvatarEditor = false
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: state.viewMode) { _, mode in
            anchorIsPlaced = false
            trackingFailureReason = nil

            state.session.externalClock = (mode == .overlay)
        }
    }

    @ViewBuilder
    private var sceneView: some View {
        switch state.viewMode {
        case .ar:
            ARSceneViewRepresentable(
                state: state,
                trackingFailureReason: $trackingFailureReason,
                anchorIsPlaced: $anchorIsPlaced
            )
        case .threeD:
            SceneKit3DViewRepresentable(state: state)
        case .overlay:
            OverlaySceneViewRepresentable(state: state)
        }
    }

    private var topEndCluster: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: GlassTokens.containerSpacing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(CircularGlassButtonStyle())
                .accessibilityLabel("Settings")

                Button {
                    state.rigKind = state.rigKind.cycled()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.fill")
                        Text(state.rigKind.displayName)
                    }
                }
                .buttonStyle(CapsuleGlassButtonStyle())
                .accessibilityLabel("Rig: \(state.rigKind.displayName)")

                Menu {
                    ForEach(Array(BODY_COLORS.enumerated()), id: \.offset) { i, entry in
                        Button {
                            state.colorIndex = i
                        } label: {
                            if i == state.colorIndex {
                                Label(entry.label, systemImage: "checkmark")
                            } else {
                                Text(entry.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        GlassColorSwatch(color: BODY_COLORS[state.colorIndex].color)
                        Text(BODY_COLORS[state.colorIndex].label)
                    }
                } primaryAction: {
                    state.colorIndex = (state.colorIndex + 1) % BODY_COLORS.count
                }
                .buttonStyle(CapsuleGlassButtonStyle(
                    tint: BODY_COLORS[state.colorIndex].color
                ))
                .accessibilityLabel("Avatar color: \(BODY_COLORS[state.colorIndex].label)")
            }
        }
    }

    private var bottomStrip: some View {
        let isLandscape = verticalSizeClass == .compact
        return VStack(spacing: 12) {
            if !isLandscape {
                statusPill
            }

            HStack {
                Spacer()
                ScaleFAB(
                    expanded: $scaleFabExpanded,
                    percent: Binding(
                        get: { state.modelScale },
                        set: { newValue in
                            state.modelScale = newValue
                            state.saveModelScale()
                        }
                    )
                )
            }
            .padding(.horizontal, GlassTokens.edgeInset)

            if state.session.state == .streaming, state.session.playbackCount > 0 {
                PlaybackScrubber(session: state.session)
                    .padding(.horizontal, GlassTokens.edgeInset)
            }

            if state.backendModel.takesVideo {
                if isLandscape { statusPill }
                videoRow
                    .padding(.horizontal, GlassTokens.edgeInset)
            } else if isLandscape {
                statusPill

                HStack(spacing: GlassTokens.containerSpacing) {
                    inputRow
                        .frame(maxWidth: .infinity)
                    MotionChipsStrip(presets: MOTION_PRESETS) { motion in
                        motionText = motion
                        fireMotion(motion)
                    }
                    .frame(maxWidth: .infinity)

                    .clipped()
                }
                .padding(.horizontal, GlassTokens.edgeInset)
            } else {
                MotionChipsStrip(presets: MOTION_PRESETS) { motion in
                    motionText = motion
                    fireMotion(motion)
                }

                inputRow
                    .padding(.horizontal, GlassTokens.edgeInset)
            }
        }
    }

    private var statusPill: some View {
        StatusOverlay(
            isPlaced: anchorIsPlaced || !state.arMode,
            arMode: state.arMode,
            trackingFailureReason: trackingFailureReason,
            sessionState: state.session.state,
            takesVideo: state.backendModel.takesVideo,
            progressText: state.session.progressText,
            note: overlayNote
        )
    }

    private var overlayNote: String? {
        guard state.viewMode == .overlay, state.session.state == .streaming, state.session.gemxCamera == nil else { return nil }
        return "No camera-frame motion — update the GEM-X server"
    }

    private var videoRow: some View {
        HStack(spacing: GlassTokens.containerSpacing) {
            VideoPickerButton(picked: $state.pickedVideo) { msg in
                state.session.clearError()
                state.lastImportError = msg
            }

            Button {
                fireVideo()
            } label: {
                if state.session.isGenerating {
                    ProgressView().tint(.white).controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
            }
            .buttonStyle(CircularGlassButtonStyle(prominent: true))
            .accessibilityLabel("Generate motion from video")
            .disabled(state.pickedVideo == nil || state.session.isGenerating)
        }
    }

    private func fireVideo() {
        guard let video = state.pickedVideo else { return }
        state.session.startVideo(video)
        state.hasStartedSession = true
    }

    private var inputRow: some View {
        HStack(spacing: GlassTokens.containerSpacing) {
            TextField(
                "",
                text: $motionText,
                prompt: Text("Type a motion or pick a chip")
                    .foregroundStyle(.white.opacity(0.55))
            )
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white)
                .tint(.white)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .focused($inputFocused)
                .onSubmit { fireMotion(motionText) }
                .glassFieldStyle()
                .accessibilityLabel("Motion text")

            Button {
                fireMotion(motionText)
                inputFocused = false
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(CircularGlassButtonStyle(prominent: true))
            .accessibilityLabel("Send motion")
            .disabled(motionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func fireMotion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.session.start(trimmed)
        state.hasStartedSession = true
    }

    private var stageBindings: TransformEditor.Values {
        .init(
            rotX: $state.stageRotX, rotY: $state.stageRotY, rotZ: $state.stageRotZ,
            scale: $state.stageScale,
            posX: $state.stagePosX, posY: $state.stagePosY, posZ: $state.stagePosZ
        )
    }

    private var avatarBindings: TransformEditor.Values {
        .init(
            rotX: $state.avatarRotX, rotY: $state.avatarRotY, rotZ: $state.avatarRotZ,
            scale: $state.avatarScale,
            posX: $state.avatarPosX, posY: $state.avatarPosY, posZ: $state.avatarPosZ
        )
    }
}

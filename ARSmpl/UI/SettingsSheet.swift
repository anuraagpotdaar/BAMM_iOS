import SwiftUI

struct SettingsSheet: View {
    @Bindable var state: AppState
    let onChangeUrl: () -> Void
    let onOpenStageEditor: () -> Void
    let onOpenAvatarEditor: () -> Void
    let onReset: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("View", selection: $state.viewMode) {
                        ForEach(ViewMode.available(for: state.backendModel)) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("View")
                } footer: {
                    if state.backendModel.takesVideo {
                        Text("Overlay plays the clip with the avatar drawn over the person. Pick the avatar color from the swatch button on the main screen.")
                    }
                }
                Section("Avatar rig") {
                    HStack {
                        Text("Current")
                        Spacer()
                        Text(state.rigKind.displayName).foregroundColor(.secondary)
                    }
                    Button("Switch rig") { state.rigKind = state.rigKind.cycled() }
                }
                if state.viewMode == .threeD {
                    Section("Stage scene") {
                        HStack {
                            Text("Current")
                            Spacer()
                            Text(state.sceneKind.displayName).foregroundColor(.secondary)
                        }
                        Button("Switch scene") { state.sceneKind = state.sceneKind.cycled() }
                    }
                }
                Section {
                    Picker("Model", selection: Binding(
                        get: { state.backendModel },
                        set: { state.setBackendModel($0) }
                    )) {
                        ForEach(BackendModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Mode", selection: Binding(
                        get: { state.backendMode },
                        set: { state.setBackendMode($0) }
                    )) {
                        ForEach(BackendMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("URL")
                        Spacer()
                        Text(state.backendUrl)
                            .font(.footnote.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Change URL", action: onChangeUrl)
                } header: {
                    Text("Backend")
                } footer: {
                    Text("\(state.backendModel.displayName) · \(state.backendMode.subtitle(for: state.backendModel))")
                }
                if state.backendModel.takesVideo {
                    GemxSection(mode: state.backendMode)
                } else if state.backendMode == .onDevice {
                    OnDeviceSamplingSection()
                }
                if state.viewMode == .threeD {
                    Section("Adjustments") {
                        Button("Stage adjust", action: onOpenStageEditor)
                        Button("Avatar adjust", action: onOpenAvatarEditor)
                    }
                }
                Section {
                    Button("Reset session", role: .destructive, action: onReset)
                } footer: {
                    Text("Stops streaming, detaches the AR anchor, and returns to the intro.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct GemxSection: View {
    let mode: BackendMode
    @Bindable private var settings = GemxSettings.shared

    var body: some View {
        Section {
            Toggle("Static camera", isOn: Binding(
                get: { settings.staticCam },
                set: { settings.staticCam = $0; settings.save() }
            ))
            .disabled(mode == .onDevice)
            Text(mode == .onDevice
                 ? "On-device always assumes a fixed camera (tripod or held still)."
                 : "Off lets the server estimate camera motion for hand-held clips.")
                .font(.caption2)
                .foregroundColor(.secondary)
            if mode != .onDevice {
                Picker("Denoiser", selection: Binding(
                    get: { settings.hostedDenoiser },
                    set: { settings.hostedDenoiser = $0; settings.save() }
                )) {
                    ForEach(GemxHostedDenoiser.allCases) { d in Text(d.displayName).tag(d) }
                }
                Toggle("Skip image features (faster)", isOn: Binding(
                    get: { settings.noImgfeat },
                    set: { settings.noImgfeat = $0; settings.save() }
                ))
                Text("Drops SAM-3D-Body (≈75% of server time). Poses stay plausible but ~9 cm further from the full model.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("GEM-X")
        } footer: {
            Text("Video → 3D motion on the SOMA skeleton. Clips: one person, mostly in frame, ≤ 30 s at 30 fps work best.")
        }
        if mode == .onDevice {
            Section {
                Picker("Denoiser", selection: Binding(
                    get: { settings.tier },
                    set: { settings.tier = $0; settings.save() }
                )) {
                    ForEach(GemxTier.allCases) { t in Text(t.displayName).tag(t) }
                }
                .pickerStyle(.segmented)
                Picker("2D pose model on", selection: Binding(
                    get: { settings.poseCompute },
                    set: { settings.poseCompute = $0; settings.save() }
                )) {
                    ForEach(GemxPoseCompute.allCases) { c in Text(c.displayName).tag(c) }
                }
                .pickerStyle(.segmented)
                Text("VitPose as a CoreML model (int8 weights, 810 MB): ≈45 ms/frame on an M2 Neural Engine vs 330 ms for the old CPU int8 model, and 0.4 px from the fp32 model instead of 5 px (82 ms/frame on an iPhone 16 Pro Max). CPU is the fallback, about 3× slower.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Toggle("Flip test", isOn: Binding(
                    get: { settings.flipTest },
                    set: { settings.flipTest = $0; settings.save() }
                ))
                Text("Also runs the mirrored crop and averages, like the server (2× pose time).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("2D pose every")
                        Spacer()
                        Text("\(settings.sampleStep) frame\(settings.sampleStep == 1 ? "" : "s")")
                            .font(.footnote.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.sampleStep) },
                        set: { settings.sampleStep = Int($0.rounded()) }
                    ), in: 1...6, step: 1) {
                        Text("2D pose stride")
                    } onEditingChanged: { editing in if !editing { settings.save() } }
                    Text("The ViT-H pose model is the slow stage; 3 = run it on every 3rd frame of a 30 fps clip and interpolate (≈7–9 mm vs every frame). 1 = every frame. Scaled to the clip's frame rate; motion is always solved on a 30 fps timeline.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Picker("Max video side", selection: Binding(
                    get: { settings.maxSide },
                    set: { settings.maxSide = $0; settings.save() }
                )) {
                    Text("540 px").tag(540)
                    Text("720 px").tag(720)
                    Text("1080 px").tag(1080)
                }
                Text("Quality is nearly independent of resolution down to ~540 px; smaller decodes faster and uses less memory.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } header: {
                Text("On-device GEM-X")
            } footer: {
                Text("Bundled: VitPose int8 (877 MB) + no-image-feature denoiser. Expect ~1–4 min per 10 s clip depending on the phone.")
            }
        }
    }
}

private struct OnDeviceSamplingSection: View {
    @Bindable private var settings = GenerationSettings.shared

    var body: some View {
        Section {
            Picker("Precision", selection: Binding(
                get: { settings.precision },
                set: { settings.precision = $0; settings.save() }
            )) {
                ForEach(Precision.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            Text(settings.precision == .fp32
                 ? "≈580 MB bundle · matches production PyTorch (~97% pose-similarity). Default for research."
                 : "~123 MB bundle · faster, smaller (86–94% pose-similarity). Backup for size-constrained tests.")
                .font(.caption2)
                .foregroundColor(.secondary)
        } header: {
            Text("Model precision")
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", settings.temperature))
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.temperature, in: 0.5...1.5, step: 0.05) {
                    Text("Temperature")
                } onEditingChanged: { editing in if !editing { settings.save() } }
                Text("Lower = more consistent. Higher = more varied (also more chaotic).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Top-p (mask)")
                    Spacer()
                    Text(settings.topPMask >= 0.999 ? "off" : String(format: "%.2f", settings.topPMask))
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.topPMask, in: 0.7...1.0, step: 0.01) {
                    Text("Top-p (mask)")
                } onEditingChanged: { editing in if !editing { settings.save() } }
                Text("Nucleus filter on the mask transformer. 1.0 = disabled.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Top-p (residual)")
                    Spacer()
                    Text(String(format: "%.2f", settings.topPRes))
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.topPRes, in: 0.7...1.0, step: 0.01) {
                    Text("Top-p (residual)")
                } onEditingChanged: { editing in if !editing { settings.save() } }
                Text("Production default 0.90.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Motion length")
                    Spacer()
                    Text(settings.motionLength == 0
                         ? "auto"
                         : String(format: "%d tok / %.1fs", settings.motionLength, Double(settings.motionLength) * 4 / 20))
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(settings.motionLength) },
                    set: { settings.motionLength = Int($0.rounded()) }
                ), in: 0...49, step: 1) {
                    Text("Motion length")
                } onEditingChanged: { editing in if !editing { settings.save() } }
                Text("0 = use length estimator (per-prompt). 49 = max (≈9.8 s). Set high for cyclic motions (\"walk in a circle\") that need to complete.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Toggle("Deterministic (greedy)", isOn: Binding(
                get: { settings.deterministic },
                set: { settings.deterministic = $0; settings.save() }
            ))
            Button("Reset to production defaults") {
                settings.temperature = 1.0
                settings.topPMask = 1.0
                settings.topPRes = 0.9
                settings.deterministic = false
                settings.motionLength = 0
                settings.save()
            }
        } header: {
            Text("On-device sampling")
        } footer: {
            Text("Tighter values give more reliable motion but less variety. Edits persist across launches.")
        }
    }
}

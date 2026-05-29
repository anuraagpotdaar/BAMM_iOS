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
                Section("View") {
                    Toggle("Use 3D mode", isOn: Binding(
                        get: { !state.arMode },
                        set: { use3d in state.arMode = !use3d }
                    ))
                }
                Section("Avatar rig") {
                    HStack {
                        Text("Current")
                        Spacer()
                        Text(state.rigKind.displayName).foregroundColor(.secondary)
                    }
                    Button("Switch rig") { state.rigKind = state.rigKind.cycled() }
                }
                if !state.arMode {
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
                    Text("\(state.backendModel.displayName) · \(state.backendMode.subtitle)")
                }
                if state.backendMode == .onDevice {
                    OnDeviceSamplingSection()
                }
                if !state.arMode {
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

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

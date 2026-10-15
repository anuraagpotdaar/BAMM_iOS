import SwiftUI

struct BackendUrlDialog: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newUrl: String = ""
    @State private var recents: [String] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Model")
                        Spacer()
                        Text(state.backendModel.displayName)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Mode")
                        Spacer()
                        Text(state.backendMode.displayName)
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text(state.backendMode.subtitle(for: state.backendModel))
                }
                Section("Backend URL") {
                    TextField(placeholder, text: $newUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                    Text(helpText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.self) { url in
                            Button(url) {
                                newUrl = url
                                save()
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(newUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            newUrl = state.backendUrl
            recents = BackendUrlStore.shared.recentsList(model: state.backendModel, mode: state.backendMode)
            fieldFocused = true
        }
    }

    private var placeholder: String {
        if state.backendModel.takesVideo {
            switch state.backendMode {
            case .local:    return "http://192.168.1.10:8000"
            case .hosted:   return "https://your-org--gemx.modal.run"
            case .onDevice: return "(not used — on-device runs locally)"
            }
        }
        switch state.backendMode {
        case .local:    return "http://192.168.1.10:7860"
        case .hosted:   return "https://your-org--bamm.modal.run"
        case .onDevice: return "(not used — on-device runs locally)"
        }
    }

    private var helpText: String {
        if state.backendModel.takesVideo {
            switch state.backendMode {
            case .local:
                return "GEM-X served by BAMM_API services/csgpu_serve.py (SERVICE=gemx, port 8000) on a LAN GPU box or this Mac. Use the machine's LAN IP on a physical device."
            case .hosted:
                return "Modal deployment URL for the GEM-X service. Uploads the clip and returns a BVH — expect roughly 1 s per video frame plus a cold start."
            case .onDevice:
                return "Runs the GEM-X phone pipeline (Vision person detection → VitPose int8 → denoiser → SOMA skeleton) entirely on this device."
            }
        }
        switch state.backendMode {
        case .local:
            return "Local Flask server. Use the Mac's LAN IP when running on a physical device — `localhost` only resolves on the simulator."
        case .hosted:
            return "Modal deployment URL for the \(state.backendModel.displayName) service. Returns a complete BVH per request — generation may take 30–90s on a cold start."
        case .onDevice:
            return "Runs the BAMM_2 pipeline (CLIP → mask + residual transformer → VQ decoder) entirely on this device using bundled int8 ONNX models. No network needed."
        }
    }

    private func save() {
        let trimmed = newUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        BackendUrlStore.shared.setUrl(trimmed, model: state.backendModel, mode: state.backendMode)
        state.backendUrl = trimmed
        state.rebuildSession()
        dismiss()
    }
}

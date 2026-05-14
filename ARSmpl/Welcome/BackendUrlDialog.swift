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
                    Text(state.backendMode.subtitle)
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
        switch state.backendMode {
        case .local:  return "http://192.168.1.10:7860"
        case .hosted: return "https://your-org--bamm.modal.run"
        }
    }

    private var helpText: String {
        switch state.backendMode {
        case .local:
            return "Local Flask server. Use the Mac's LAN IP when running on a physical device — `localhost` only resolves on the simulator."
        case .hosted:
            return "Modal deployment URL for the \(state.backendModel.displayName) service. Returns a complete BVH per request — generation may take 30–90s on a cold start."
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

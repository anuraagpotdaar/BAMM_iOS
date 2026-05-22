import SwiftUI

struct WelcomeScreen: View {
    @Bindable var state: AppState
    @State private var serverReachable: Bool? = nil
    @State private var pingTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.12),
                    Color(red: 0.10, green: 0.12, blue: 0.18),
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                Text("AR SMPL")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Stream BAMM motion onto a 22-joint humanoid in your space.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 32)

                modelPicker
                backendPicker

                serverStatusRow

                if serverReachable == false, state.backendMode == .local, isProbablyLocalhost(state.backendUrl) {
                    Text("On a real iPhone, `localhost` resolves to the phone, not your Mac. Use your Mac's LAN IP — run `ipconfig getifaddr en0` on your Mac.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: GlassTokens.containerSpacing) {
                    Button {
                        state.arMode = true
                        state.hasPickedMode = true
                    } label: {
                        modeLabel("Open in AR", system: "arkit")
                    }
                    .buttonStyle(WideGlassButtonStyle(prominent: true))

                    Button {
                        state.arMode = false
                        state.hasPickedMode = true
                    } label: {
                        modeLabel("Open in 3D", system: "cube.fill")
                    }
                    .buttonStyle(WideGlassButtonStyle())
                }
                .padding(.horizontal, 32)

                Button {
                    state.showUrlDialog = true
                } label: {
                    Label("Change server URL", systemImage: "network")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(CapsuleGlassButtonStyle())
                .padding(.bottom, 16)
            }
        }
        .onAppear { startPing() }
        .onDisappear { pingTask?.cancel(); pingTask = nil }
        .onChange(of: state.backendUrl) { _, _ in startPing() }
        .onChange(of: state.backendMode) { _, _ in startPing() }
        .onChange(of: state.backendModel) { _, _ in startPing() }
    }

    private var modelPicker: some View {
        Picker("Model", selection: Binding(
            get: { state.backendModel },
            set: { state.setBackendModel($0) }
        )) {
            ForEach(BackendModel.allCases) { model in
                Text(model.displayName).tag(model)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 32)
    }

    private var backendPicker: some View {
        Picker("Backend", selection: Binding(
            get: { state.backendMode },
            set: { state.setBackendMode($0) }
        )) {
            ForEach(BackendMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 32)
    }

    private var serverStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .shadow(color: dotColor.opacity(0.6), radius: 4)
            Text(statusText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
            Text("·")
                .foregroundStyle(.secondary)
            Text(state.backendUrl)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }

    private var dotColor: Color {
        switch serverReachable {
        case .some(true): return Color(red: 0.30, green: 0.69, blue: 0.31)
        case .some(false): return Color(red: 0.90, green: 0.22, blue: 0.21)
        case .none: return Color.gray
        }
    }

    private var statusText: String {
        switch serverReachable {
        case .some(true): return "Server reachable"
        case .some(false): return "Server unreachable"
        case .none: return "Checking…"
        }
    }

    private func modeLabel(_ title: String, system: String) -> some View {
        HStack {
            Image(systemName: system)
            Text(title).fontWeight(.semibold)
            Spacer()
            Image(systemName: "chevron.right").opacity(0.6)
        }
    }

    private func isProbablyLocalhost(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("0.0.0.0")
    }

    private func startPing() {
        pingTask?.cancel()
        let url = state.backendUrl
        let mode = state.backendMode
        pingTask = Task {
            while !Task.isCancelled {
                let ok: Bool
                switch mode {
                case .local:    ok = await BammClient(baseUrl: url).ping()
                case .hosted:   ok = await HostedBammClient(baseUrl: url).ping()
                case .onDevice: ok = true   // no network probe needed
                }
                if Task.isCancelled { return }
                await MainActor.run { self.serverReachable = ok }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }
}

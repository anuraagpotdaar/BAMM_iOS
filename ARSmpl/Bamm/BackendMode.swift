import Foundation

enum BackendMode: String, Sendable, CaseIterable, Identifiable {
    case local
    case hosted
    case onDevice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:    return "Local"
        case .hosted:   return "Hosted"
        case .onDevice: return "On-device"
        }
    }

    var subtitle: String { subtitle(for: .bamm) }

    func subtitle(for model: BackendModel) -> String {
        switch (model, self) {
        case (.gemx, .local):    return "LAN GEM-X server (csgpu_serve.py), returns BVH"
        case (.gemx, .hosted):   return "Modal GEM-X service, returns BVH"
        case (.gemx, .onDevice): return "Runs GEM-X on this device (no network)"
        case (_, .local):        return "LAN Flask server, streams frames"
        case (_, .hosted):       return "Modal service, returns BVH"
        case (_, .onDevice):     return "Runs BAMM_2 on this device (no network)"
        }
    }

    var defaultUrl: String {
        switch self {
        case .local:    return "http://localhost:7860"
        case .hosted:   return "https://example.modal.run"
        case .onDevice: return ""
        }
    }

    var requiresUrl: Bool { self != .onDevice }
}

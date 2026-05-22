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

    var subtitle: String {
        switch self {
        case .local:    return "LAN Flask server, streams frames"
        case .hosted:   return "Modal service, returns BVH"
        case .onDevice: return "Runs BAMM_2 on this device (no network)"
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

import Foundation

enum BackendMode: String, Sendable, CaseIterable, Identifiable {
    case local
    case hosted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:  return "Local"
        case .hosted: return "Hosted"
        }
    }

    var subtitle: String {
        switch self {
        case .local:  return "LAN Flask server, streams frames"
        case .hosted: return "Modal service, returns BVH"
        }
    }

    var defaultUrl: String {
        switch self {
        case .local:  return "http://localhost:7860"
        case .hosted: return "https://example.modal.run"
        }
    }
}

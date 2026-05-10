import Foundation

enum BackendModel: String, Sendable, CaseIterable, Identifiable {
    case bamm
    case mmm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bamm: return "BAMM"
        case .mmm:  return "MMM"
        }
    }
}

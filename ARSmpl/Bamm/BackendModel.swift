import Foundation

enum BackendModel: String, Sendable, CaseIterable, Identifiable {
    case bamm
    case mmm
    case gemx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bamm: return "BAMM"
        case .mmm:  return "MMM"
        case .gemx: return "GEM-X"
        }
    }

    var takesVideo: Bool { self == .gemx }

    var inputHint: String {
        takesVideo ? "Pick a video of one person, then Generate" : "Type a motion or pick a chip"
    }
}

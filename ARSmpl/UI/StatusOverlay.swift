import SwiftUI
import ARKit

struct StatusOverlay: View {
    let isPlaced: Bool
    let arMode: Bool
    let trackingFailureReason: ARCamera.TrackingState.Reason?
    let sessionState: BammSession.State

    var body: some View {
        Group {
            if let info = label {
                GlassPill(text: info.text, tint: info.tint)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.snappy(duration: 0.2), value: label?.text)
    }

    private struct LabelInfo {
        let text: String
        let tint: Color?
    }

    private var label: LabelInfo? {
        if arMode, let reason = trackingFailureReason {
            switch reason {
            case .insufficientFeatures: return .init(text: "Point at a textured surface", tint: .orange)
            case .excessiveMotion:      return .init(text: "Moving too fast", tint: .orange)
            case .initializing:         return .init(text: "Initializing AR…", tint: .blue)
            case .relocalizing:         return .init(text: "Relocalizing…", tint: .blue)
            @unknown default:           return .init(text: "Tracking lost", tint: .orange)
            }
        }
        if arMode, !isPlaced {
            return .init(text: "Tap the floor to place the body", tint: .blue)
        }
        switch sessionState {
        case .streaming: return .init(text: "Streaming", tint: .green)
        case .idle:      return .init(text: "Pick a motion below", tint: nil)
        case .stopped:   return .init(text: "Stopped — pick a motion", tint: nil)
        case .error:     return nil
        }
    }
}

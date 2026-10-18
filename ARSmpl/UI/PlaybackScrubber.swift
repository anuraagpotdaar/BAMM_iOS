import SwiftUI

struct PlaybackScrubber: View {
    @Bindable var session: BammSession

    var body: some View {
        HStack(spacing: 10) {
            Button { session.togglePlayback() } label: {
                Image(systemName: session.playbackPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
            }
            .accessibilityLabel(session.playbackPaused ? "Play" : "Pause")
            Text(Self.mmss(Double(session.playbackFrame) * session.playbackFrameTime))
                .font(.caption.monospacedDigit())
            Slider(
                value: Binding(
                    get: { Double(session.playbackFrame) },
                    set: { session.seek(frame: Int($0.rounded())) }
                ),
                in: 0...Double(max(session.playbackCount - 1, 1))
            )
            .tint(.white)
            .accessibilityLabel("Playback position")
            Text(Self.mmss(session.playbackDuration))
                .font(.caption.monospacedDigit())
            Button { session.playbackLoop.toggle() } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 15, weight: .semibold))
                    .opacity(session.playbackLoop ? 1 : 0.4)
                    .frame(width: 22)
            }
            .accessibilityLabel(session.playbackLoop ? "Auto replay on" : "Auto replay off")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    static func mmss(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

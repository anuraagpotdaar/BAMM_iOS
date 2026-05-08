import SwiftUI

struct MotionChipsStrip: View {
    let presets: [MotionPreset]
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(presets) { p in
                    Button {
                        onPick(p.prompt)
                    } label: {
                        Text(p.label)
                    }
                    .buttonStyle(CapsuleGlassButtonStyle(horizontalPadding: 14))
                    .accessibilityLabel(p.label)
                    .accessibilityHint("Plays \(p.prompt) motion")
                }
            }
            .padding(.horizontal, GlassTokens.edgeInset)
        }
        .scrollClipDisabled()
    }
}

import SwiftUI

struct IntroOverlay: View {
    let presets: [MotionPreset]
    let onPick: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Pick a motion to begin")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                Text("Or type your own in the box below.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets) { p in
                            Button(p.label) { onPick(p.prompt) }
                                .buttonStyle(.borderedProminent)
                                .tint(.white.opacity(0.18))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 24)
        }
    }
}

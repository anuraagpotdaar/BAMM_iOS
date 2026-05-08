import SwiftUI

struct LoadingOverlay: View {
    let motionText: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Generating motion…")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                if !motionText.isEmpty {
                    Text("\u{201C}\(motionText)\u{201D}")
                        .font(.footnote.italic())
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
    }
}

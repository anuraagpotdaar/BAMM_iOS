import SwiftUI

struct ScaleFAB: View {
    @Binding var expanded: Bool
    @Binding var percent: Float    // 1.0 = 100%

    var body: some View {
        HStack(spacing: GlassTokens.containerSpacing) {
            if expanded {
                Button {
                    percent = max(0.05, percent - 0.05)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(CircularGlassButtonStyle())
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Decrease scale")

                Button {
                    percent = min(3.0, percent + 0.05)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(CircularGlassButtonStyle())
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Increase scale")
            }

            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                Text("\(Int(percent * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(CircularGlassButtonStyle(size: 56, prominent: true))
            .accessibilityLabel("Avatar scale: \(Int(percent * 100)) percent")
        }
    }
}

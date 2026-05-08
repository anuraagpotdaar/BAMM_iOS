import SwiftUI

// MARK: - Design tokens

enum GlassTokens {
    static let controlHeight: CGFloat = 44
    static let containerSpacing: CGFloat = 8
    static let edgeInset: CGFloat = 16
    static let pressedOpacity: Double = 0.85
    static let cornerRadius: CGFloat = 18
}

// MARK: - Material backdrop helpers

private struct MaterialCapsule: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    if let tint { Capsule().fill(tint.opacity(0.35)) }
                }
            )
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

private struct MaterialCircle: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    if let tint { Circle().fill(tint.opacity(0.35)) }
                }
            )
            .overlay(
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

private struct MaterialRect: ViewModifier {
    var tint: Color? = nil
    var radius: CGFloat = GlassTokens.cornerRadius
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.35)) }
                }
            )
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

// MARK: - Capsule glass button

struct CapsuleGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent: Bool = false
    var horizontalPadding: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color? = prominent ? (tint ?? .accentColor) : tint
        let fg: Color = prominent ? .white : .primary
        return configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: GlassTokens.controlHeight)
            .foregroundStyle(fg)
            .modifier(MaterialCapsule(tint: bg))
            .opacity(configuration.isPressed ? GlassTokens.pressedOpacity : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - Circular glass icon button

struct CircularGlassButtonStyle: ButtonStyle {
    var size: CGFloat = GlassTokens.controlHeight
    var tint: Color? = nil
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color? = prominent ? (tint ?? .accentColor) : tint
        let fg: Color = prominent ? .white : .primary
        return configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(fg)
            .modifier(MaterialCircle(tint: bg))
            .opacity(configuration.isPressed ? GlassTokens.pressedOpacity : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - Wide glass button (welcome / mode picker)

struct WideGlassButtonStyle: ButtonStyle {
    var prominent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        let bg: Color? = prominent ? .accentColor : nil
        let fg: Color = prominent ? .white : .primary
        return configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(fg)
            .modifier(MaterialRect(tint: bg, radius: 16))
            .opacity(configuration.isPressed ? GlassTokens.pressedOpacity : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - Status pill (non-interactive)

struct GlassPill: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .modifier(MaterialCapsule(tint: tint))
    }
}

// MARK: - Color swatch used inside the color-picker button

struct GlassColorSwatch: View {
    let color: Color
    var size: CGFloat = 14

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: color.opacity(0.4), radius: 3, y: 1)
    }
}

// MARK: - Glass text field surface

struct GlassFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: GlassTokens.controlHeight)
            .modifier(MaterialCapsule())
    }
}

extension View {
    func glassFieldStyle() -> some View { modifier(GlassFieldBackground()) }
}

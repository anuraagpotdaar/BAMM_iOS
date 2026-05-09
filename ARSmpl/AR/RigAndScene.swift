import Foundation
import SwiftUI

enum RigKind: String, CaseIterable, Identifiable, Sendable {
    case smpl, soldier
    var id: String { rawValue }
    var displayName: String { self == .smpl ? "SMPL" : "Soldier" }
    var resourceName: String { self == .smpl ? "smpl" : "soldier" }
    var resourceExtension: String { "usdz" }

    func cycled() -> RigKind { self == .smpl ? .soldier : .smpl }
}

enum SceneKind: String, CaseIterable, Identifiable, Sendable {
    case runway, gallery
    var id: String { rawValue }
    var displayName: String { self == .runway ? "Runway" : "Gallery" }
    var resourceName: String { self == .runway ? "scene" : "scene_gallery" }
    var resourceExtension: String { "usdz" }
    var defaultScale: Float { 0.25 }

    func cycled() -> SceneKind { self == .runway ? .gallery : .runway }
}

/// Index 0 ("Default") restores the original textures rather than tinting.
struct BodyColor: Sendable {
    let label: String
    let color: Color
    let argb: (r: Float, g: Float, b: Float)
}

let BODY_COLORS: [BodyColor] = [
    BodyColor(label: "Default", color: .white,             argb: (1.00, 1.00, 1.00)),
    BodyColor(label: "Red",     color: Color(hex: 0xE74C3C), argb: (0.91, 0.30, 0.24)),
    BodyColor(label: "Blue",    color: Color(hex: 0x3498DB), argb: (0.20, 0.60, 0.86)),
    BodyColor(label: "Green",   color: Color(hex: 0x2ECC71), argb: (0.18, 0.80, 0.44)),
    BodyColor(label: "Gold",    color: Color(hex: 0xF1C40F), argb: (0.95, 0.77, 0.06)),
    BodyColor(label: "Purple",  color: Color(hex: 0x9B59B6), argb: (0.61, 0.35, 0.71)),
]

struct MotionPreset: Identifiable, Sendable {
    let prompt: String
    let label: String
    var id: String { prompt }
}

let MOTION_PRESETS: [MotionPreset] = [
    MotionPreset(prompt: "walk forward", label: "Walk"),
    MotionPreset(prompt: "run forward", label: "Run"),
    MotionPreset(prompt: "jump", label: "Jump"),
    MotionPreset(prompt: "dance", label: "Dance"),
    MotionPreset(prompt: "sit down", label: "Sit"),
    MotionPreset(prompt: "stand up", label: "Stand"),
    MotionPreset(prompt: "wave hand", label: "Wave"),
    MotionPreset(prompt: "kick", label: "Kick"),
    MotionPreset(prompt: "punch", label: "Punch"),
    MotionPreset(prompt: "crouch", label: "Crouch"),
    MotionPreset(prompt: "turn around", label: "Turn"),
    MotionPreset(prompt: "clap hands", label: "Clap"),
    MotionPreset(prompt: "bow", label: "Bow"),
    MotionPreset(prompt: "walk in a circle", label: "Circle"),
]

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

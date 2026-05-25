import Foundation
import Observation

enum Precision: String, CaseIterable, Identifiable, Sendable {
    case fp32
    case int8
    var id: String { rawValue }
    var displayName: String { self == .fp32 ? "fp32 (research)" : "int8 (compact)" }
}

@Observable
final class GenerationSettings {
    var precision: Precision = .fp32
    var temperature: Float = 1.0
    var topPMask:    Float = 1.0
    var topPRes:     Float = 0.9
    var deterministic: Bool = false
    var motionLength: Int = 0   // 0 = use length estimator; 1..49 = manual tokens.

    static let shared = GenerationSettings.load()

    private static let kP  = "bamm2.gen.precision"
    private static let kT  = "bamm2.gen.temperature"
    private static let kPM = "bamm2.gen.topPMask"
    private static let kPR = "bamm2.gen.topPRes"
    private static let kD  = "bamm2.gen.deterministic"
    private static let kL  = "bamm2.gen.motionLength"

    private init() {}

    private static func load() -> GenerationSettings {
        let g = GenerationSettings()
        let d = UserDefaults.standard
        if let raw = d.string(forKey: kP), let p = Precision(rawValue: raw) { g.precision = p }
        if let v = d.object(forKey: kT)  as? Double { g.temperature = Float(v) }
        if let v = d.object(forKey: kPM) as? Double { g.topPMask    = Float(v) }
        if let v = d.object(forKey: kPR) as? Double { g.topPRes     = Float(v) }
        if let v = d.object(forKey: kD)  as? Bool   { g.deterministic = v }
        if let v = d.object(forKey: kL)  as? Int    { g.motionLength = v }
        return g
    }

    func save() {
        let d = UserDefaults.standard
        d.set(precision.rawValue,   forKey: Self.kP)
        d.set(Double(temperature),  forKey: Self.kT)
        d.set(Double(topPMask),     forKey: Self.kPM)
        d.set(Double(topPRes),      forKey: Self.kPR)
        d.set(deterministic,        forKey: Self.kD)
        d.set(motionLength,         forKey: Self.kL)
    }

    func snapshot() -> Sampling {
        Sampling(precision: precision, temperature: temperature, topPMask: topPMask,
                 topPRes: topPRes, deterministic: deterministic, motionLengthTokens: motionLength)
    }
}

struct Sampling: Sendable {
    let precision: Precision
    let temperature: Float
    let topPMask: Float
    let topPRes: Float
    let deterministic: Bool
    let motionLengthTokens: Int

    static let production = Sampling(precision: .fp32, temperature: 1.0, topPMask: 1.0,
                                     topPRes: 0.9, deterministic: false, motionLengthTokens: 0)
}

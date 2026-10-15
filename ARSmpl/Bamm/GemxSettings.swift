import Foundation
import Observation

enum GemxHostedDenoiser: String, CaseIterable, Identifiable, Sendable {
    case pytorch
    case onnx
    var id: String { rawValue }
    var displayName: String { self == .pytorch ? "PyTorch (+contact post-processing)" : "ONNX export" }
}

enum GemxPoseBackend: String, CaseIterable, Identifiable, Sendable {

    case coreml

    case onnx
    var id: String { rawValue }
    var displayName: String { self == .coreml ? "Neural Engine (CoreML)" : "CPU (ONNX int8)" }
}

enum GemxPoseCompute: String, CaseIterable, Identifiable, Sendable {
    case auto, cpu
    var id: String { rawValue }
    var displayName: String {
        switch self { case .auto: return "Neural Engine"; case .cpu: return "CPU" }
    }
}

enum GemxTier: String, CaseIterable, Identifiable, Sendable {
    case fp16
    case int8
    var id: String { rawValue }
    var displayName: String { self == .fp16 ? "fp16 (94 MB, ~1 mm)" : "int8 (57 MB, ~10 mm)" }
    var denoiserResource: String {
        self == .fp16 ? "gem_denoiser_no_imgfeat_fp16_band" : "gem_denoiser_no_imgfeat_int8_band"
    }
}

@Observable
final class GemxSettings {

    var staticCam: Bool = true

    var noImgfeat: Bool = false
    var hostedDenoiser: GemxHostedDenoiser = .pytorch
    var tier: GemxTier = .fp16
    var poseBackend: GemxPoseBackend = .coreml
    var poseCompute: GemxPoseCompute = .auto

    var flipTest: Bool = true

    var sampleStep: Int = 2

    var maxSide: Int = 1080

    static let shared = GemxSettings.load()

    private static let kS = "gemx.staticCam"
    private static let kI = "gemx.noImgfeat"
    private static let kD = "gemx.hostedDenoiser"
    private static let kT = "gemx.tier"
    private static let kP = "gemx.sampleStep"
    private static let kM = "gemx.maxSide"
    private static let kB = "gemx.poseBackend"
    private static let kC = "gemx.poseCompute"
    private static let kF = "gemx.flipTest"

    private init() {}

    private static func load() -> GemxSettings {
        let g = GemxSettings()
        let d = UserDefaults.standard
        if let v = d.object(forKey: kS) as? Bool { g.staticCam = v }
        if let v = d.object(forKey: kI) as? Bool { g.noImgfeat = v }
        if let raw = d.string(forKey: kD), let v = GemxHostedDenoiser(rawValue: raw) { g.hostedDenoiser = v }
        if let raw = d.string(forKey: kT), let v = GemxTier(rawValue: raw) { g.tier = v }
        if let raw = d.string(forKey: kB), let v = GemxPoseBackend(rawValue: raw) { g.poseBackend = v }
        if let raw = d.string(forKey: kC), let v = GemxPoseCompute(rawValue: raw) { g.poseCompute = v }
        if let v = d.object(forKey: kF) as? Bool { g.flipTest = v }
        if let v = d.object(forKey: kP) as? Int, (1...6).contains(v) { g.sampleStep = v }
        if let v = d.object(forKey: kM) as? Int, (360...2160).contains(v) { g.maxSide = v }
        return g
    }

    func save() {
        let d = UserDefaults.standard
        d.set(staticCam, forKey: Self.kS)
        d.set(noImgfeat, forKey: Self.kI)
        d.set(hostedDenoiser.rawValue, forKey: Self.kD)
        d.set(tier.rawValue, forKey: Self.kT)
        d.set(poseBackend.rawValue, forKey: Self.kB)
        d.set(poseCompute.rawValue, forKey: Self.kC)
        d.set(flipTest, forKey: Self.kF)
        d.set(sampleStep, forKey: Self.kP)
        d.set(maxSide, forKey: Self.kM)
    }

    func snapshot() -> GemxOptions {
        GemxOptions(staticCam: staticCam, noImgfeat: noImgfeat, hostedDenoiser: hostedDenoiser,
                    tier: tier, sampleStep: sampleStep, maxSide: maxSide, poseBackend: poseBackend,
                    poseCompute: poseCompute, flipTest: flipTest)
    }
}

struct GemxOptions: Sendable {
    let staticCam: Bool
    let noImgfeat: Bool
    let hostedDenoiser: GemxHostedDenoiser
    let tier: GemxTier

    let sampleStep: Int
    let maxSide: Int

    var resampleFps: Double? = 30
    var poseBackend: GemxPoseBackend = .coreml
    var poseCompute: GemxPoseCompute = .auto
    var flipTest: Bool = true

    var poseModel: String? = nil

    static let defaults = GemxOptions(staticCam: true, noImgfeat: false, hostedDenoiser: .pytorch,
                                      tier: .fp16, sampleStep: 3, maxSide: 1080)
}

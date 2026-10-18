import Foundation
import CoreML

extension GemxPoseCompute {
    var mlComputeUnits: MLComputeUnits {
        switch self { case .auto: return .all; case .cpu: return .cpuOnly }
    }
}

final class GemxVitPoseCoreML {

    static let resourceNames = ["vitpose_w8.mlmodelc"]

    static func modelURL(in dir: URL, preferred: String? = nil) -> URL? {
        for n in [preferred].compactMap({ $0 }) + resourceNames {
            let u = dir.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private let model: MLModel
    private let input: MLMultiArray
    let name: String
    let computeUnits: MLComputeUnits

    init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: cfg)
        input = try MLMultiArray(shape: [1, 3, NSNumber(value: GemxConst.cropH), NSNumber(value: GemxConst.cropW)], dataType: .float32)
        name = modelURL.lastPathComponent
        self.computeUnits = computeUnits
    }

    func run(crop: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) throws {
        let n = 3 * GemxConst.cropH * GemxConst.cropW
        input.withUnsafeMutableBytes { raw, _ in
            raw.baseAddress!.copyMemory(from: UnsafeRawPointer(crop), byteCount: n * 4)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["imgs": MLFeatureValue(multiArray: input)])
        let result = try model.prediction(from: provider)
        guard let hm = result.featureValue(for: "heatmaps")?.multiArrayValue else {
            throw OnDeviceError.ortError("coreml vitpose: no heatmaps output")
        }
        let J = GemxConst.numJoints, Hh = GemxConst.hmH, Hw = GemxConst.hmW
        guard hm.shape.map({ $0.intValue }) == [1, J, Hh, Hw] else { throw OnDeviceError.shapeMismatch("coreml heatmaps shape \(hm.shape)") }

        let st = hm.strides.map { $0.intValue }
        let sj = st[1], sy = st[2], sx = st[3]
        @inline(__always) func gather<T>(_ p: UnsafePointer<T>, _ f: (T) -> Float) {
            var o = 0
            for j in 0..<J {
                for y in 0..<Hh {
                    let row = p + j * sj + y * sy
                    for x in 0..<Hw { out[o] = f(row[x * sx]); o += 1 }
                }
            }
        }
        switch hm.dataType {
        case .float32:
            hm.withUnsafeBytes { raw in gather(raw.baseAddress!.assumingMemoryBound(to: Float.self)) { $0 } }
        case .float16:
            hm.withUnsafeBytes { raw in gather(raw.baseAddress!.assumingMemoryBound(to: UInt16.self)) { Float(Float16(bitPattern: $0)) } }
        case .double:
            hm.withUnsafeBytes { raw in gather(raw.baseAddress!.assumingMemoryBound(to: Double.self)) { Float($0) } }
        default:
            throw OnDeviceError.shapeMismatch("coreml heatmaps dtype \(hm.dataType.rawValue)")
        }
    }
}

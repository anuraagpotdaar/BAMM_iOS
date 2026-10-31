import Foundation
import CoreML

enum GemxPoseLayerDebug {
    struct Manifest: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let id: String
        let model: String
        let compute: String
        let inputName: String
        let inputFile: String
        let shape: [Int]
        let samples: Int
        let exportPlan: Bool?
    }

    static func flattened(_ a: MLMultiArray) throws -> [Float] {
        let dims = a.shape.map { $0.intValue }, strides = a.strides.map { $0.intValue }
        var values = [Float](repeating: 0, count: a.count)
        func gather<T>(_ p: UnsafePointer<T>, _ convert: (T) -> Float) {
            for i in 0..<a.count {
                var rest = i, offset = 0
                for k in dims.indices.reversed() {
                    offset += (rest % dims[k]) * strides[k]; rest /= dims[k]
                }
                values[i] = convert(p[offset])
            }
        }
        switch a.dataType {
        case .float16: a.withUnsafeBytes { gather($0.baseAddress!.assumingMemoryBound(to: UInt16.self)) { Float(Float16(bitPattern: $0)) } }
        case .float32: a.withUnsafeBytes { gather($0.baseAddress!.assumingMemoryBound(to: Float.self)) { $0 } }
        case .double: a.withUnsafeBytes { gather($0.baseAddress!.assumingMemoryBound(to: Double.self)) { Float($0) } }
        default: throw OnDeviceError.shapeMismatch("debug output dtype \(a.dataType)")
        }
        return values
    }

    static func run(directory: URL, log: @escaping @Sendable (String) -> Void) async throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let source = docs.appendingPathComponent("GemxDebug")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        let resultURL = directory.appendingPathComponent("results.jsonl")
        FileManager.default.createFile(atPath: resultURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: resultURL); defer { try? file.close() }
        for c in manifest.cases {
            var row: [String: Any] = ["id": c.id, "model": c.model, "compute": c.compute]
            do {
                log("[GemxBench] debug loading \(c.id) \(c.compute)")
                let cfg = MLModelConfiguration()
                switch c.compute {
                case "cpu": cfg.computeUnits = .cpuOnly
                case "ne": cfg.computeUnits = .cpuAndNeuralEngine
                case "all": cfg.computeUnits = .all
                default: throw OnDeviceError.shapeMismatch("debug compute \(c.compute)")
                }
                let url = source.appendingPathComponent(c.model)
                let t0 = DispatchTime.now().uptimeNanoseconds
                let model = try MLModel(contentsOf: url, configuration: cfg)
                row["loadSeconds"] = Double(DispatchTime.now().uptimeNanoseconds-t0)/1e9
                log("[GemxBench] debug loaded \(c.id)")
                let data = try GemxPoseMicrobenchmark.floats(source.appendingPathComponent(c.inputFile))
                let size = c.shape.reduce(1, *)
                guard c.samples > 0, data.count == size*c.samples else { throw OnDeviceError.shapeMismatch("debug input size") }
                let input = try MLMultiArray(shape: c.shape.map { NSNumber(value: $0) }, dataType: .float16)
                let provider = try MLDictionaryFeatureProvider(dictionary: [c.inputName: MLFeatureValue(multiArray: input)])
                var predictions: [[String: Any]] = []
                let outputDir = directory.appendingPathComponent(c.id)
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                for sample in 0..<c.samples {
                    input.withUnsafeMutableBytes { bytes, _ in
                        let p = bytes.baseAddress!.assumingMemoryBound(to: UInt16.self)
                        for j in 0..<size { p[j] = Float16(data[sample*size+j]).bitPattern }
                    }
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = try await model.prediction(from: provider)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
                    var outputs: [[String: Any]] = []
                    for name in result.featureNames.sorted() {
                        guard let array = result.featureValue(for: name)?.multiArrayValue else { continue }
                        let values = try flattened(array)
                        guard values.allSatisfy({ $0.isFinite }) else { throw OnDeviceError.shapeMismatch("nonfinite \(name)") }
                        let filename = "sample\(sample)_\(name).f32"
                        try values.withUnsafeBytes { try Data($0).write(to: outputDir.appendingPathComponent(filename)) }
                        outputs.append(["name": name, "shape": array.shape.map { $0.intValue }, "file": filename])
                    }
                    predictions.append(["sample": sample, "predictionMs": elapsed, "outputs": outputs])
                    log("[GemxBench] debug \(c.id) sample \(sample+1)/\(c.samples) saved \(outputs.count) outputs")
                }
                row["predictions"] = predictions; row["ok"] = true
                // Save prediction evidence before the optional, separate compute-plan query.
                try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                    .write(to: outputDir.appendingPathComponent("predictions.json"))
                if #available(iOS 17.4, *), c.exportPlan == true {
                    let plan = try await MLComputePlan.load(contentsOf: url, configuration: cfg)
                    var ops: [[String: Any]] = []
                    func walk(_ block: MLModelStructure.Program.Block) {
                        for op in block.operations {
                            var item: [String: Any] = ["op": op.operatorName, "outputs": op.outputs.map { $0.name }]
                            if let usage = plan.deviceUsage(for: op) { item["preferredDevice"] = String(describing: usage.preferred) }
                            ops.append(item)
                            for b in op.blocks { walk(b) }
                        }
                    }
                    if case .program(let p) = plan.modelStructure { for f in p.functions.values { walk(f.block) } }
                    try JSONSerialization.data(withJSONObject: ops, options: [.prettyPrinted, .sortedKeys])
                        .write(to: outputDir.appendingPathComponent("compute_plan.json"))
                }
            } catch {
                row["ok"] = false; row["error"] = String(describing: error)
                log("[GemxBench] debug failed \(c.id): \(error)")
            }
            let encoded = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try file.write(contentsOf: encoded); try file.write(contentsOf: Data([10])); try file.synchronize()
            log("[GemxBench] debug completed \(c.id)")
        }
    }
}

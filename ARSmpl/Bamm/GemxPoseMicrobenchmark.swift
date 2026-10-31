import Foundation
import CoreML

enum GemxPoseMicrobenchmark {
    static func floats(_ url: URL) throws -> [Float] {
        try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func run(directory: URL, variants: [String] = ["w8a8_clipped"],
                    log: @escaping @Sendable (String) -> Void) async throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidates = docs.appendingPathComponent("GemxCandidates")
        let crops = try floats(candidates.appendingPathComponent("crops.f32"))
        let cropSize = 3 * 256 * 192, hmSize = 77 * 64 * 48
        guard crops.count % cropSize == 0, crops.count > 0 else {
            throw OnDeviceError.shapeMismatch("microbenchmark crops")
        }
        let n = crops.count / cropSize
        let bundleDir = Bundle.main.resourceURL!.appendingPathComponent("Gemx")
        let resultURL = directory.appendingPathComponent("results.jsonl")
        FileManager.default.createFile(atPath: resultURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: resultURL)
        defer { try? file.close() }
        // A second baseline checks temperature/drift after the candidate trials.
        let cases = [("w8", "vitpose_w8.mlmodelc")]
            + variants.map { ($0, "vitpose_\($0).mlmodelc") }
            + [("w8_repeat", "vitpose_w8.mlmodelc")]
        for (label, name) in cases {
            while [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
            var row: [String: Any] = ["model": label, "samples": n,
                "thermalBefore": ProcessInfo.processInfo.thermalState.rawValue,
                "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled]
            do {
                guard let requested = GemxVitPoseCoreML.modelURL(in: bundleDir, preferred: name) else {
                    throw OnDeviceError.resourceMissing(name)
                }
                log("[GemxBench] micro loading \(label)")
                let t0 = DispatchTime.now().uptimeNanoseconds
                let model = try GemxVitPoseCoreML(modelURL: requested, computeUnits: .all)
                row["loadSeconds"] = Double(DispatchTime.now().uptimeNanoseconds-t0)/1e9
                var hm = [Float](repeating: 0, count: hmSize)
                for _ in 0..<2 {
                    try crops.withUnsafeBufferPointer { cp in try hm.withUnsafeMutableBufferPointer { hp in
                        try model.run(crop: cp.baseAddress!, into: hp.baseAddress!)
                    } }
                }
                model.recordTimings = true
                var elapsed: [[String: Double]] = [], firstOutput = [Float]()
                firstOutput.reserveCapacity(n * hmSize)
                var repeatMaxDelta: Float = 0
                for rep in 0..<3 {
                    for i in 0..<n {
                        let start = DispatchTime.now().uptimeNanoseconds
                        try crops.withUnsafeBufferPointer { cp in try hm.withUnsafeMutableBufferPointer { hp in
                            try model.run(crop: cp.baseAddress! + i * cropSize, into: hp.baseAddress!)
                        } }
                        var timing = model.lastTimings
                        timing["totalMs"] = Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
                        timing["repeat"] = Double(rep); timing["sample"] = Double(i)
                        elapsed.append(timing)
                        guard hm.allSatisfy({ $0.isFinite }) else { throw OnDeviceError.shapeMismatch("nonfinite \(label)") }
                        if rep == 0 { firstOutput.append(contentsOf: hm) }
                        else {
                            for j in 0..<hmSize { repeatMaxDelta = max(repeatMaxDelta, abs(hm[j]-firstOutput[i*hmSize+j])) }
                        }
                    }
                }
                try firstOutput.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("\(label)_heatmaps.f32")) }
                row["latency"] = elapsed; row["repeatMaxHeatmapDelta"] = repeatMaxDelta
                row["ok"] = true
                if #available(iOS 17.4, *) {
                    do {
                        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
                        let plan = try await MLComputePlan.load(contentsOf: requested, configuration: cfg)
                        var operations: [[String: Any]] = []
                        func walk(_ block: MLModelStructure.Program.Block) {
                            for op in block.operations {
                                let usage = plan.deviceUsage(for: op)
                                var info: [String: Any] = ["operator": op.operatorName,
                                    "outputs": op.outputs.map { $0.name }]
                                if let usage { info["preferredDevice"] = String(describing: usage.preferred) }
                                if let cost = plan.estimatedCost(of: op) { info["estimatedCostWeight"] = cost.weight }
                                operations.append(info)
                                for child in op.blocks { walk(child) }
                            }
                        }
                        if case .program(let program) = plan.modelStructure {
                            for function in program.functions.values { walk(function.block) }
                        }
                        try JSONSerialization.data(withJSONObject: operations, options: [.prettyPrinted, .sortedKeys])
                            .write(to: directory.appendingPathComponent("\(label)_compute_plan.json"))
                    } catch { row["computePlanError"] = String(describing: error) }
                }
                log("[GemxBench] micro completed \(label), \(elapsed.count) predictions")
            } catch {
                row["ok"] = false; row["error"] = String(describing: error)
                log("[GemxBench] micro failed \(label): \(error)")
            }
            row["thermalAfter"] = ProcessInfo.processInfo.thermalState.rawValue
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try file.write(contentsOf: data); try file.write(contentsOf: Data([10])); try file.synchronize()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}

import Foundation
import simd

struct JointFrame: Sendable {
    static let jointCount = SkeletonTopology.jointCount
    static let floatCount = SkeletonTopology.jointCount * 3

    let xyz: [Float]
    init(_ xyz: [Float]) { self.xyz = xyz }

    static func fromHumanml22(_ xyz66: [Float]) -> JointFrame {
        var out = [Float](repeating: .nan, count: floatCount)
        if xyz66.count >= 66 {
            for (i, j) in SkeletonTopology.humanml22.enumerated() {
                out[j * 3] = xyz66[i * 3]; out[j * 3 + 1] = xyz66[i * 3 + 1]; out[j * 3 + 2] = xyz66[i * 3 + 2]
            }
        }
        return JointFrame(out)
    }

    func humanml22() -> [Float] {
        var out = [Float](repeating: 0, count: 66)
        for (i, j) in SkeletonTopology.humanml22.enumerated() where j * 3 + 2 < xyz.count {
            out[i * 3] = xyz[j * 3]; out[i * 3 + 1] = xyz[j * 3 + 1]; out[i * 3 + 2] = xyz[j * 3 + 2]
        }
        return out
    }

    @inline(__always) func position(_ j: Int) -> SIMD3<Float> {
        SIMD3<Float>(xyz[j * 3], xyz[j * 3 + 1], xyz[j * 3 + 2])
    }

    @inline(__always) func isPresent(_ j: Int) -> Bool {
        j * 3 + 2 < xyz.count && xyz[j * 3].isFinite && xyz[j * 3 + 1].isFinite && xyz[j * 3 + 2].isFinite
    }
}

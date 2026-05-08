import Foundation

/// 22-joint HumanML3D frame, flat XYZ floats (length 66).
struct JointFrame: Sendable {
    let xyz: [Float]
    init(_ xyz: [Float]) { self.xyz = xyz }
}

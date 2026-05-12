import Foundation
import simd

struct BvhMotion {
    let frames: [JointFrame]
    let frameTime: TimeInterval
}

enum BvhError: Error, CustomStringConvertible {
    case missingHierarchy
    case missingMotion
    case malformed(String)
    case missingJoints(style: String, missing: [String], present: [String])

    var description: String {
        switch self {
        case .missingHierarchy:   return "BVH: HIERARCHY block missing"
        case .missingMotion:      return "BVH: MOTION block missing"
        case .malformed(let why): return "BVH: \(why)"
        case .missingJoints(let style, let missing, let present):
            return "BVH: missing required \(style) joints \(missing) — have: \(present)"
        }
    }
}

enum BvhParser {

    static func parse(_ text: String) throws -> BvhMotion {
        var tokens = TokenStream(text)
        try expect(&tokens, "HIERARCHY")

        var joints: [BvhJoint] = []
        try parseJointBlock(&tokens, parent: -1, joints: &joints, isRoot: true)

        try expect(&tokens, "MOTION")
        try expect(&tokens, "Frames:")
        guard let nFrames = tokens.nextInt() else { throw BvhError.malformed("Frames: count missing") }
        try expect(&tokens, "Frame")
        try expect(&tokens, "Time:")
        guard let frameTime = tokens.nextDouble() else { throw BvhError.malformed("Frame Time: value missing") }

        let totalChannels = joints.reduce(0) { $0 + $1.channels.count }

        // BAMM and MMM both use "Spine1"/"Spine2" with different anatomy, so
        // pick the table up-front instead of trying both.
        let style = detectStyle(joints)

        var firstByName: [String: Int] = [:]
        for (i, j) in joints.enumerated() where firstByName[j.name] == nil {
            firstByName[j.name] = i
        }

        var smplIndex = [Int](repeating: -1, count: joints.count)
        var missing: [String] = []
        for k in 0..<22 {
            if let bvhIdx = firstByName[style.humanmlNames[k]] {
                smplIndex[bvhIdx] = k
            } else {
                missing.append(style.humanmlNames[k])
            }
        }
        if !missing.isEmpty {
            let present = joints.map { $0.name }
            throw BvhError.missingJoints(style: style.label, missing: missing, present: present)
        }

        var outFrames: [JointFrame] = []
        outFrames.reserveCapacity(nFrames)

        var worldT = [SIMD3<Float>](repeating: .zero, count: joints.count)
        var worldR = [simd_quatf](repeating: simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0)),
                                  count: joints.count)

        for _ in 0..<nFrames {
            guard let row = tokens.nextFloats(count: totalChannels) else {
                throw BvhError.malformed("MOTION row truncated (expected \(totalChannels) channels)")
            }

            var chOff = 0
            for (i, joint) in joints.enumerated() {
                var localPos = SIMD3<Float>.zero
                var localRot = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
                var rotSeen = false
                for (k, ch) in joint.channels.enumerated() {
                    let v = row[chOff + k]
                    switch ch {
                    case .xPos: localPos.x = v
                    case .yPos: localPos.y = v
                    case .zPos: localPos.z = v
                    case .xRot, .yRot, .zRot:
                        let rad = v * .pi / 180
                        let axis: SIMD3<Float>
                        switch ch {
                        case .xRot: axis = SIMD3<Float>(1, 0, 0)
                        case .yRot: axis = SIMD3<Float>(0, 1, 0)
                        case .zRot: axis = SIMD3<Float>(0, 0, 1)
                        default:    axis = SIMD3<Float>(1, 0, 0)
                        }
                        let q = simd_quatf(angle: rad, axis: axis)
                        localRot = rotSeen ? simd_mul(localRot, q) : q
                        rotSeen = true
                    }
                }
                chOff += joint.channels.count

                let localT = joint.offset + localPos
                if joint.parent < 0 {
                    worldT[i] = localT
                    worldR[i] = localRot
                } else {
                    let pT = worldT[joint.parent]
                    let pR = worldR[joint.parent]
                    worldT[i] = pT + pR.act(localT)
                    worldR[i] = simd_mul(pR, localRot)
                }
            }

            var xyz = [Float](repeating: 0, count: 66)
            for (i, idx) in smplIndex.enumerated() where idx >= 0 && idx < 22 {
                xyz[idx * 3]     = worldT[i].x
                xyz[idx * 3 + 1] = worldT[i].y
                xyz[idx * 3 + 2] = worldT[i].z
            }
            // Compensates for smpl.glb ankle bind being steeper than BAMM's
            // static toe offset; without it the toes lift.
            applyFootPitch(&xyz, ankle: 7, toe: 10, radians: footPitchRadians)
            applyFootPitch(&xyz, ankle: 8, toe: 11, radians: footPitchRadians)
            outFrames.append(JointFrame(xyz))
        }

        return BvhMotion(frames: outFrames, frameTime: max(frameTime, 1.0 / 240.0))
    }

    private static func parseJointBlock(
        _ tokens: inout TokenStream,
        parent: Int,
        joints: inout [BvhJoint],
        isRoot: Bool
    ) throws {
        let header = tokens.next() ?? ""
        let name: String
        if isRoot {
            if header != "ROOT" { throw BvhError.malformed("Expected ROOT, got \(header)") }
            name = tokens.next() ?? ""
        } else if header == "JOINT" {
            name = tokens.next() ?? ""
        } else if header == "End" {
            _ = tokens.next() // "Site"
            name = "_EndSite"
        } else {
            throw BvhError.malformed("Unexpected token in HIERARCHY: \(header)")
        }

        try expect(&tokens, "{")
        let myIndex = joints.count
        joints.append(BvhJoint(name: name, parent: parent, offset: .zero, channels: []))

        var offset = SIMD3<Float>.zero
        var channels: [BvhChannel] = []

        while let tok = tokens.peek() {
            if tok == "OFFSET" {
                _ = tokens.next()
                guard let x = tokens.nextFloat(),
                      let y = tokens.nextFloat(),
                      let z = tokens.nextFloat() else {
                    throw BvhError.malformed("OFFSET values missing for \(name)")
                }
                offset = SIMD3<Float>(x, y, z)
            } else if tok == "CHANNELS" {
                _ = tokens.next()
                guard let n = tokens.nextInt() else { throw BvhError.malformed("CHANNELS count missing") }
                for _ in 0..<n {
                    let chTok = tokens.next() ?? ""
                    switch chTok {
                    case "Xposition": channels.append(.xPos)
                    case "Yposition": channels.append(.yPos)
                    case "Zposition": channels.append(.zPos)
                    case "Xrotation": channels.append(.xRot)
                    case "Yrotation": channels.append(.yRot)
                    case "Zrotation": channels.append(.zRot)
                    default: throw BvhError.malformed("Unknown channel \(chTok)")
                    }
                }
            } else if tok == "JOINT" || tok == "End" {
                try parseJointBlock(&tokens, parent: myIndex, joints: &joints, isRoot: false)
            } else if tok == "}" {
                _ = tokens.next()
                joints[myIndex] = BvhJoint(name: name, parent: parent, offset: offset, channels: channels)
                return
            } else {
                throw BvhError.malformed("Unexpected token \(tok) inside \(name)")
            }
        }
        throw BvhError.malformed("Unterminated joint block \(name)")
    }

    private static let bammNames: [String] = [
        "Hips",
        "LeftUpLeg", "RightUpLeg",
        "Spine",
        "LeftLeg", "RightLeg",
        "Spine1",
        "LeftFoot", "RightFoot",
        "Spine2",
        "LeftToe", "RightToe",
        "Neck",
        "LeftShoulder", "RightShoulder",
        "Head",
        "LeftArm", "RightArm",
        "LeftForeArm", "RightForeArm",
        "LeftHand", "RightHand",
    ]

    private static let mmmNames: [String] = [
        "Pelvis",
        "Left_hip", "Right_hip",
        "Spine1",
        "Left_knee", "Right_knee",
        "Spine2",
        "Left_ankle", "Right_ankle",
        "Spine3",
        "Left_foot", "Right_foot",
        "Neck",
        "Left_collar", "Right_collar",
        "Head",
        "Left_shoulder", "Right_shoulder",
        "Left_elbow", "Right_elbow",
        "Left_wrist", "Right_wrist",
    ]

    private struct SkeletonStyle {
        let label: String
        let humanmlNames: [String]
    }

    private static func detectStyle(_ joints: [BvhJoint]) -> SkeletonStyle {
        var names = Set<String>()
        for j in joints { names.insert(j.name) }
        if names.contains("Pelvis"), names.contains("Left_hip") {
            return SkeletonStyle(label: "MMM", humanmlNames: mmmNames)
        }
        if names.contains("Hips"), names.contains("LeftUpLeg") {
            return SkeletonStyle(label: "BAMM", humanmlNames: bammNames)
        }
        return SkeletonStyle(label: "BAMM?", humanmlNames: bammNames)
    }

    private static func expect(_ tokens: inout TokenStream, _ word: String) throws {
        guard let next = tokens.next(), next == word else {
            throw BvhError.malformed("Expected '\(word)'")
        }
    }

    /// Tune if the toe drives into the floor (decrease) or stays lifted (increase).
    private static let footPitchRadians: Float = 35.0 * .pi / 180.0

    private static func applyFootPitch(_ xyz: inout [Float], ankle: Int, toe: Int, radians: Float) {
        let ax = xyz[ankle * 3]
        let ay = xyz[ankle * 3 + 1]
        let az = xyz[ankle * 3 + 2]
        let dx = xyz[toe * 3]     - ax
        let dy = xyz[toe * 3 + 1] - ay
        let dz = xyz[toe * 3 + 2] - az
        let c = cos(radians)
        let s = sin(radians)
        let ny = c * dy - s * dz
        let nz = s * dy + c * dz
        xyz[toe * 3]     = ax + dx
        xyz[toe * 3 + 1] = ay + ny
        xyz[toe * 3 + 2] = az + nz
    }
}

private struct BvhJoint {
    let name: String
    let parent: Int
    let offset: SIMD3<Float>
    let channels: [BvhChannel]
}

private enum BvhChannel {
    case xPos, yPos, zPos
    case xRot, yRot, zRot
}

private struct TokenStream {
    private let tokens: [Substring]
    private var idx: Int = 0

    init(_ text: String) {
        self.tokens = text.split(whereSeparator: { $0.isWhitespace })
    }

    mutating func next() -> String? {
        guard idx < tokens.count else { return nil }
        defer { idx += 1 }
        return String(tokens[idx])
    }

    func peek() -> String? {
        guard idx < tokens.count else { return nil }
        return String(tokens[idx])
    }

    mutating func nextInt() -> Int? {
        guard let t = next() else { return nil }
        return Int(t)
    }

    mutating func nextDouble() -> Double? {
        guard let t = next() else { return nil }
        return Double(t)
    }

    mutating func nextFloat() -> Float? {
        guard let t = next() else { return nil }
        return Float(t)
    }

    mutating func nextFloats(count: Int) -> [Float]? {
        guard idx + count <= tokens.count else { return nil }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            guard let v = Float(tokens[idx + i]) else { return nil }
            out[i] = v
        }
        idx += count
        return out
    }
}

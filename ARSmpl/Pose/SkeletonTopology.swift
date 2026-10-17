import Foundation

enum SkeletonTopology {

    static let jointCount = 77

    static let names: [String] = [
        "Hips", "Spine1", "Spine2", "Chest", "Neck1", "Neck2", "Head", "HeadEnd", "Jaw", "LeftEye", "RightEye",
        "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
        "LeftHandThumb1", "LeftHandThumb2", "LeftHandThumb3", "LeftHandThumbEnd",
        "LeftHandIndex1", "LeftHandIndex2", "LeftHandIndex3", "LeftHandIndex4", "LeftHandIndexEnd",
        "LeftHandMiddle1", "LeftHandMiddle2", "LeftHandMiddle3", "LeftHandMiddle4", "LeftHandMiddleEnd",
        "LeftHandRing1", "LeftHandRing2", "LeftHandRing3", "LeftHandRing4", "LeftHandRingEnd",
        "LeftHandPinky1", "LeftHandPinky2", "LeftHandPinky3", "LeftHandPinky4", "LeftHandPinkyEnd",
        "RightShoulder", "RightArm", "RightForeArm", "RightHand",
        "RightHandThumb1", "RightHandThumb2", "RightHandThumb3", "RightHandThumbEnd",
        "RightHandIndex1", "RightHandIndex2", "RightHandIndex3", "RightHandIndex4", "RightHandIndexEnd",
        "RightHandMiddle1", "RightHandMiddle2", "RightHandMiddle3", "RightHandMiddle4", "RightHandMiddleEnd",
        "RightHandRing1", "RightHandRing2", "RightHandRing3", "RightHandRing4", "RightHandRingEnd",
        "RightHandPinky1", "RightHandPinky2", "RightHandPinky3", "RightHandPinky4", "RightHandPinkyEnd",
        "LeftLeg", "LeftShin", "LeftFoot", "LeftToeBase", "LeftToeEnd",
        "RightLeg", "RightShin", "RightFoot", "RightToeBase", "RightToeEnd",
    ]

    static let parent: [Int] = [
        -1, 0, 1, 2, 3, 4, 5, 6, 6, 6, 6,
        3, 11, 12, 13,
        14, 15, 16, 17,
        14, 19, 20, 21, 22,
        14, 24, 25, 26, 27,
        14, 29, 30, 31, 32,
        14, 34, 35, 36, 37,
        3, 39, 40, 41,
        42, 43, 44, 45,
        42, 47, 48, 49, 50,
        42, 52, 53, 54, 55,
        42, 57, 58, 59, 60,
        42, 62, 63, 64, 65,
        0, 67, 68, 69, 70,
        0, 72, 73, 74, 75,
    ]

    static let hips = 0, spine1 = 1, spine2 = 2, chest = 3, neck1 = 4, neck2 = 5, head = 6, headEnd = 7
    static let leftHand = 14, rightHand = 42
    static let leftLeg = 67, leftShin = 68, leftFoot = 69, leftToeBase = 70, leftToeEnd = 71
    static let rightLeg = 72, rightShin = 73, rightFoot = 74, rightToeBase = 75, rightToeEnd = 76

    static let humanml22: [Int] = [0, 67, 72, 1, 68, 73, 2, 69, 74, 3, 70, 75, 4, 11, 39, 6, 12, 40, 13, 41, 14, 42]

    static let aimTargets: [[Int]] = {
        var t = [[Int]](repeating: [], count: jointCount)
        t[spine1] = [spine2]; t[spine2] = [chest]; t[chest] = [neck1]
        t[neck1] = [neck2, head]; t[neck2] = [head]; t[head] = [headEnd]
        for (shoulder, hand, middle1) in [(11, leftHand, 24), (39, rightHand, 52)] {
            t[shoulder] = [shoulder + 1]; t[shoulder + 1] = [shoulder + 2]; t[shoulder + 2] = [hand]
            t[hand] = [middle1 + 1, middle1]

            var j = hand + 1
            for n in [4, 5, 5, 5, 5] {
                for k in 0..<(n - 1) { t[j + k] = [j + k + 1] }
                j += n
            }
        }
        for leg in [leftLeg, rightLeg] {
            t[leg] = [leg + 1]; t[leg + 1] = [leg + 2]; t[leg + 2] = [leg + 3]; t[leg + 3] = [leg + 4]
        }
        return t
    }()

    static let aliases: [(Int, [String])] = {
        var a: [(Int, [String])] = [
            (hips, ["Pelvis", "mixamorig:Hips", "DEF-spine"]),
            (spine1, ["Spine1", "mixamorig:Spine", "DEF-spine.001"]),
            (spine2, ["Spine2", "mixamorig:Spine1", "DEF-spine.002"]),
            (chest, ["Spine3", "mixamorig:Spine2", "DEF-spine.003"]),
            (neck1, ["Neck", "mixamorig:Neck", "DEF-spine.004"]),
            (neck2, ["DEF-spine.005"]),
            (head, ["Head", "mixamorig:Head", "DEF-spine.006"]),
            (headEnd, ["mixamorig:HeadTop_End"]),
            (9, ["DEF-eye.L"]), (10, ["DEF-eye.R"]),
            (leftLeg, ["L_Hip", "left_hip", "mixamorig:LeftUpLeg", "DEF-thigh.L"]),
            (leftShin, ["L_Knee", "left_knee", "mixamorig:LeftLeg", "DEF-shin.L"]),
            (leftFoot, ["L_Ankle", "left_ankle", "mixamorig:LeftFoot", "DEF-foot.L"]),
            (leftToeBase, ["L_Foot", "left_foot", "mixamorig:LeftToeBase", "DEF-toe.L"]),
            (leftToeEnd, ["mixamorig:LeftToe_End"]),
            (rightLeg, ["R_Hip", "right_hip", "mixamorig:RightUpLeg", "DEF-thigh.R"]),
            (rightShin, ["R_Knee", "right_knee", "mixamorig:RightLeg", "DEF-shin.R"]),
            (rightFoot, ["R_Ankle", "right_ankle", "mixamorig:RightFoot", "DEF-foot.R"]),
            (rightToeBase, ["R_Foot", "right_foot", "mixamorig:RightToeBase", "DEF-toe.R"]),
            (rightToeEnd, ["mixamorig:RightToe_End"]),
        ]
        for (shoulder, hand, S, s, mx) in [(11, leftHand, "L", "left", "Left"), (39, rightHand, "R", "right", "Right")] {
            a.append((shoulder, ["\(S)_Collar", "\(s)_collar", "mixamorig:\(mx)Shoulder", "DEF-shoulder.\(S)"]))
            a.append((shoulder + 1, ["\(S)_Shoulder", "\(s)_shoulder", "mixamorig:\(mx)Arm", "DEF-upper_arm.\(S)"]))
            a.append((shoulder + 2, ["\(S)_Elbow", "\(s)_elbow", "mixamorig:\(mx)ForeArm", "DEF-forearm.\(S)"]))
            a.append((hand, ["\(S)_Wrist", "\(s)_wrist", "mixamorig:\(mx)Hand", "DEF-hand.\(S)"]))

            let th = hand + 1
            for k in 0..<3 { a.append((th + k, ["mixamorig:\(mx)HandThumb\(k + 1)", "DEF-thumb.0\(k + 1).\(S)"])) }
            a.append((th + 3, ["mixamorig:\(mx)HandThumb4"]))

            var j = th + 4
            for (name, rig) in [("Index", "f_index"), ("Middle", "f_middle"), ("Ring", "f_ring"), ("Pinky", "f_pinky")] {
                for k in 0..<3 { a.append((j + 1 + k, ["mixamorig:\(mx)Hand\(name)\(k + 1)", "DEF-\(rig).0\(k + 1).\(S)"])) }
                a.append((j + 4, ["mixamorig:\(mx)Hand\(name)4"]))
                if name == "Middle" { a[a.count - 4].1.insert("\(S)_Hand", at: 0) }
                j += 5
            }
        }
        return a
    }()

    static func gemxToSceneFrame(_ xyz: inout [Float]) {
        var i = 0
        while i + 2 < xyz.count {
            xyz[i] = -xyz[i]
            xyz[i + 2] = -xyz[i + 2]
            i += 3
        }
    }

    static func gemxToCameraFrame(_ xyz: inout [Float]) {
        var i = 0
        while i + 2 < xyz.count {
            xyz[i + 1] = -xyz[i + 1]
            xyz[i + 2] = -xyz[i + 2]
            i += 3
        }
    }

    static func normalize(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s.lowercased() {
            switch ch {
            case ":", ".", "_", "/", "\\", "[", "]", " ", "-", "\t", "\n":
                continue
            default:
                out.append(ch)
            }
        }
        return out
    }

    static func stripPrefix(_ s: String) -> String {
        for p in ["mavg", "mixamorig", "bone", "smpl", "b"] {
            if s.hasPrefix(p), s.count > p.count {
                return String(s.dropFirst(p.count))
            }
        }
        return s
    }
}

import Foundation

enum SkeletonTopology {

    /// Parent joint index of joint i; -1 for the root.
    static let parent: [Int] = [
        -1, 0, 0, 0,
        1, 2, 3,
        4, 5, 6,
        7, 8, 9,
        9, 9, 12,
        13, 14,
        16, 17,
        18, 19,
    ]

    /// (own, target) pairs in update order; parents come before children.
    static let updateOrder: [(own: Int, target: Int)] = [
        (3, 6), (6, 9), (9, 12), (12, 15),
        (13, 16), (16, 18), (18, 20),
        (14, 17), (17, 19), (19, 21),
        (1, 4), (4, 7), (7, 10),
        (2, 5), (5, 8), (8, 11),
    ]

    /// 22-joint HumanML3D index → acceptable bone names (SMPL + Mixamo aliases).
    static let smplAliases: [(Int, [String])] = [
        (0, ["Pelvis", "mixamorig:Hips"]),
        (1, ["L_Hip", "left_hip", "mixamorig:LeftUpLeg"]),
        (2, ["R_Hip", "right_hip", "mixamorig:RightUpLeg"]),
        (3, ["Spine1", "mixamorig:Spine"]),
        (4, ["L_Knee", "left_knee", "mixamorig:LeftLeg"]),
        (5, ["R_Knee", "right_knee", "mixamorig:RightLeg"]),
        (6, ["Spine2", "mixamorig:Spine1"]),
        (7, ["L_Ankle", "left_ankle", "mixamorig:LeftFoot"]),
        (8, ["R_Ankle", "right_ankle", "mixamorig:RightFoot"]),
        (9, ["Spine3", "mixamorig:Spine2"]),
        (10, ["L_Foot", "left_foot", "mixamorig:LeftToeBase"]),
        (11, ["R_Foot", "right_foot", "mixamorig:RightToeBase"]),
        (12, ["Neck", "mixamorig:Neck"]),
        (13, ["L_Collar", "left_collar", "mixamorig:LeftShoulder"]),
        (14, ["R_Collar", "right_collar", "mixamorig:RightShoulder"]),
        (15, ["Head", "mixamorig:Head"]),
        (16, ["L_Shoulder", "left_shoulder", "mixamorig:LeftArm"]),
        (17, ["R_Shoulder", "right_shoulder", "mixamorig:RightArm"]),
        (18, ["L_Elbow", "left_elbow", "mixamorig:LeftForeArm"]),
        (19, ["R_Elbow", "right_elbow", "mixamorig:RightForeArm"]),
        (20, ["L_Wrist", "left_wrist", "mixamorig:LeftHand"]),
        (21, ["R_Wrist", "right_wrist", "mixamorig:RightHand"]),
    ]

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

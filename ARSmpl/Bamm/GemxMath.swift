import Foundation
import simd

enum GemxMath {
    typealias M3 = simd_double3x3
    typealias V3 = SIMD3<Double>

    @inline(__always) static func el(_ R: M3, _ r: Int, _ c: Int) -> Double { R[c][r] }

    static func r6dToMatrix(_ d: UnsafeBufferPointer<Double>, _ off: Int) -> M3 {
        let a1 = V3(d[off], d[off + 1], d[off + 2])
        let a2 = V3(d[off + 3], d[off + 4], d[off + 5])
        let b1 = simd_normalize(a1)
        let b2 = simd_normalize(a2 - simd_dot(b1, a2) * b1)
        let b3 = simd_cross(b1, b2)
        return M3(rows: [b1, b2, b3])
    }

    static func matrixToRotvec(_ R: M3) -> V3 {
        var q = simd_normalize(simd_quatd(R))
        if q.real < 0 { q = simd_quatd(real: -q.real, imag: -q.imag) }
        let n = simd_length(q.imag)
        let angle = 2 * atan2(n, q.real)
        let scale: Double
        if angle <= 1e-3 {
            scale = 2 + angle * angle / 12 + 7 * pow(angle, 4) / 2880
        } else {
            scale = angle / sin(angle / 2)
        }
        return q.imag * scale
    }

    static func rotvecToMatrix(_ v: V3) -> M3 {
        let theta = simd_length(v)
        if theta < 1e-12 { return matrix_identity_double3x3 }
        return M3(simd_quatd(angle: theta, axis: v / theta))
    }

    static func matrixToEulerZYXDeg(_ R: M3) -> V3 {
        let r20 = el(R, 2, 0)
        let beta = asin(max(-1, min(1, -r20)))
        let alpha: Double, gamma: Double
        if abs(r20) < 1 - 1e-10 {
            alpha = atan2(el(R, 1, 0), el(R, 0, 0))
            gamma = atan2(el(R, 2, 1), el(R, 2, 2))
        } else {

            alpha = atan2(-el(R, 0, 1), el(R, 1, 1))
            gamma = 0
        }
        let k = 180 / Double.pi
        return V3(alpha * k, beta * k, gamma * k)
    }

    static func gaussianFilter1D(_ x: [Double], sigma: Double, truncate: Double = 4) -> [Double] {
        let n = x.count
        guard n > 1, sigma > 0 else { return x }
        let radius = Int(truncate * sigma + 0.5)
        var w = [Double](repeating: 0, count: 2 * radius + 1)
        var sum = 0.0
        for i in -radius...radius {
            let v = exp(-Double(i * i) / (2 * sigma * sigma))
            w[i + radius] = v; sum += v
        }
        for i in w.indices { w[i] /= sum }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0.0
            for k in -radius...radius {
                let j = min(max(i + k, 0), n - 1)
                acc += w[k + radius] * x[j]
            }
            out[i] = acc
        }
        return out
    }

    static func interp(xp: [Double], fp: UnsafeBufferPointer<Float>, stride: Int, n: Int, into out: UnsafeMutableBufferPointer<Float>) {

        var k = 0
        for t in 0..<n {
            let td = Double(t)
            while k + 1 < xp.count && xp[k + 1] <= td { k += 1 }
            if td <= xp[0] {
                for c in 0..<stride { out[t * stride + c] = fp[c] }
            } else if k + 1 >= xp.count {
                let last = (xp.count - 1) * stride
                for c in 0..<stride { out[t * stride + c] = fp[last + c] }
            } else {
                let x0 = xp[k], x1 = xp[k + 1]
                let a = Float((td - x0) / (x1 - x0))
                let o0 = k * stride, o1 = (k + 1) * stride
                for c in 0..<stride { out[t * stride + c] = fp[o0 + c] + (fp[o1 + c] - fp[o0 + c]) * a }
            }
        }
    }
}

// A minimal stand-in for Apple's `simd` module, covering exactly the surface
// the portable Twinzo Scan sources use.
//
// Why this exists: `SIMD3<Float>` and friends are Swift *stdlib* types and are
// available everywhere, but the free functions (`dot`, `cross`, `length`) and
// the matrix and quaternion types live in Darwin's `simd`. Supplying them here
// lets BVH.swift, PointToPlaneICP.swift and ScanCloud.swift compile on Windows
// and Linux with no edits.
//
// IMPORTANT: this validates the algorithms, not Apple's simd. It is deliberately
// scalar and straightforward — correctness over speed, since a divergence
// between this and the real thing would be a silent test lie. Every function is
// the textbook definition.

import Foundation

// MARK: - Vector functions

@inlinable
public func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    a.x * b.x + a.y * b.y + a.z * b.z
}

@inlinable
public func dot(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
    a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
}

@inlinable
public func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y,
          a.z * b.x - a.x * b.z,
          a.x * b.y - a.y * b.x)
}

@inlinable
public func length(_ v: SIMD3<Float>) -> Float { dot(v, v).squareRoot() }

@inlinable
public func length_squared(_ v: SIMD3<Float>) -> Float { dot(v, v) }

@inlinable
public func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let len = length(v)
    // Apple's normalize returns NaN for a zero vector. Match that rather than
    // silently returning zero: callers that rely on the guard would otherwise
    // pass here and fail on device.
    return v / len
}

@inlinable
public func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { length(a - b) }

@inlinable
public func distance_squared(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    length_squared(a - b)
}

// Element-wise min/max. These do not collide with the stdlib's `min`/`max`,
// which require Comparable, and SIMD3 is not Comparable.
@inlinable
public func min(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    a.replacing(with: b, where: b .< a)
}

@inlinable
public func max(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    a.replacing(with: b, where: b .> a)
}

// MARK: - SIMD4 conveniences

extension SIMD4 where Scalar == Float {
    /// `SIMD4(xyz, w)`. Present in Apple's simd, absent from the stdlib.
    public init(_ xyz: SIMD3<Float>, _ w: Float) {
        self.init(xyz.x, xyz.y, xyz.z, w)
    }
}

// MARK: - Quaternion

public struct simd_quatf {
    /// Storage order matches Apple's: (x, y, z, w), w real.
    public var vector: SIMD4<Float>

    public init(vector: SIMD4<Float>) { self.vector = vector }

    public init(ix: Float, iy: Float, iz: Float, r: Float) {
        vector = SIMD4(ix, iy, iz, r)
    }

    /// Rotation of `angle` radians about `axis`, which must be unit length.
    public init(angle: Float, axis: SIMD3<Float>) {
        let half = angle * 0.5
        let s = sinf(half)
        vector = SIMD4(axis.x * s, axis.y * s, axis.z * s, cosf(half))
    }

    public var real: Float { vector.w }
    public var imag: SIMD3<Float> { SIMD3(vector.x, vector.y, vector.z) }
}

// MARK: - Matrices

public struct simd_float3x3 {
    /// Column-major, as in Apple's simd and in Metal.
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    public init(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>) {
        columns = (c0, c1, c2)
    }

    public init(diagonal d: SIMD3<Float>) {
        columns = (SIMD3(d.x, 0, 0), SIMD3(0, d.y, 0), SIMD3(0, 0, d.z))
    }

    /// Standard quaternion-to-matrix conversion. The quaternion is normalised
    /// first so a slightly drifted input still yields an orthonormal basis.
    public init(_ q: simd_quatf) {
        let n = dot(q.vector, q.vector)
        let s: Float = n > 0 ? 2 / n : 0
        let (x, y, z, w) = (q.vector.x, q.vector.y, q.vector.z, q.vector.w)
        let (xs, ys, zs) = (x * s, y * s, z * s)
        let (wx, wy, wz) = (w * xs, w * ys, w * zs)
        let (xx, xy, xz) = (x * xs, x * ys, x * zs)
        let (yy, yz, zz) = (y * ys, y * zs, z * zs)

        columns = (
            SIMD3(1 - (yy + zz), xy + wz, xz - wy),
            SIMD3(xy - wz, 1 - (xx + zz), yz + wx),
            SIMD3(xz + wy, yz - wx, 1 - (xx + yy))
        )
    }

    public static func * (m: simd_float3x3, v: SIMD3<Float>) -> SIMD3<Float> {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z
    }
}

public let matrix_identity_float3x3 = simd_float3x3(diagonal: SIMD3(repeating: 1))

public struct simd_float4x4 {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>,
                _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        columns = (c0, c1, c2, c3)
    }

    public init(diagonal d: SIMD4<Float>) {
        self.init(SIMD4(d.x, 0, 0, 0), SIMD4(0, d.y, 0, 0),
                  SIMD4(0, 0, d.z, 0), SIMD4(0, 0, 0, d.w))
    }

    public static func * (a: simd_float4x4, b: simd_float4x4) -> simd_float4x4 {
        simd_float4x4(a * b.columns.0, a * b.columns.1,
                      a * b.columns.2, a * b.columns.3)
    }

    public static func * (m: simd_float4x4, v: SIMD4<Float>) -> SIMD4<Float> {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z + m.columns.3 * v.w
    }

    /// General 4x4 inverse by cofactor expansion, computed in Double.
    ///
    /// Not the fast path Apple uses, and not restricted to rigid transforms:
    /// the tests compose arbitrary matrices, and a rigid-only shortcut here
    /// would quietly give wrong answers the moment one of them was not rigid.
    public var inverse: simd_float4x4 {
        var m = [Double](repeating: 0, count: 16)
        let cols = [columns.0, columns.1, columns.2, columns.3]
        for c in 0..<4 {
            m[c * 4 + 0] = Double(cols[c].x)
            m[c * 4 + 1] = Double(cols[c].y)
            m[c * 4 + 2] = Double(cols[c].z)
            m[c * 4 + 3] = Double(cols[c].w)
        }

        // Gauss-Jordan against an identity augmentation. Partial pivoting keeps
        // it stable for the near-singular cases a failing test might produce.
        var inv = [Double](repeating: 0, count: 16)
        for i in 0..<4 { inv[i * 4 + i] = 1 }

        func at(_ a: [Double], _ row: Int, _ col: Int) -> Double { a[col * 4 + row] }
        func set(_ a: inout [Double], _ row: Int, _ col: Int, _ v: Double) { a[col * 4 + row] = v }

        for pivot in 0..<4 {
            var best = pivot
            for r in (pivot + 1)..<4 where abs(at(m, r, pivot)) > abs(at(m, best, pivot)) {
                best = r
            }
            if best != pivot {
                for c in 0..<4 {
                    let t1 = at(m, pivot, c); set(&m, pivot, c, at(m, best, c)); set(&m, best, c, t1)
                    let t2 = at(inv, pivot, c); set(&inv, pivot, c, at(inv, best, c)); set(&inv, best, c, t2)
                }
            }

            let d = at(m, pivot, pivot)
            guard abs(d) > 1e-12 else { return simd_float4x4(diagonal: SIMD4(repeating: .nan)) }
            for c in 0..<4 {
                set(&m, pivot, c, at(m, pivot, c) / d)
                set(&inv, pivot, c, at(inv, pivot, c) / d)
            }

            for r in 0..<4 where r != pivot {
                let factor = at(m, r, pivot)
                guard factor != 0 else { continue }
                for c in 0..<4 {
                    set(&m, r, c, at(m, r, c) - factor * at(m, pivot, c))
                    set(&inv, r, c, at(inv, r, c) - factor * at(inv, pivot, c))
                }
            }
        }

        return simd_float4x4(
            SIMD4(Float(at(inv, 0, 0)), Float(at(inv, 1, 0)), Float(at(inv, 2, 0)), Float(at(inv, 3, 0))),
            SIMD4(Float(at(inv, 0, 1)), Float(at(inv, 1, 1)), Float(at(inv, 2, 1)), Float(at(inv, 3, 1))),
            SIMD4(Float(at(inv, 0, 2)), Float(at(inv, 1, 2)), Float(at(inv, 2, 2)), Float(at(inv, 3, 2))),
            SIMD4(Float(at(inv, 0, 3)), Float(at(inv, 1, 3)), Float(at(inv, 2, 3)), Float(at(inv, 3, 3)))
        )
    }
}

public typealias float4x4 = simd_float4x4
public typealias float3x3 = simd_float3x3

public let matrix_identity_float4x4 = simd_float4x4(diagonal: SIMD4(repeating: 1))

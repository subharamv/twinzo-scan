import Foundation
import simd
@testable import TwinzoCore

/// Deterministic scene generation for the geometry tests.
///
/// Everything here is seeded. A registration test that passes on one run and
/// fails on the next teaches nothing, and ICP has enough genuinely marginal
/// cases without random inputs blurring the signal.
enum SyntheticScene {

    /// Small, fast, reproducible PRNG (xorshift64*). Foundation's RNG is not
    /// seedable across platforms, and `Int.random` gives no reproducibility.
    struct Random {
        private var state: UInt64

        init(seed: UInt64 = 0x9E3779B97F4A7C15) {
            state = seed == 0 ? 1 : seed
        }

        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2685821657736338717
        }

        /// Uniform in [0, 1).
        mutating func unit() -> Float {
            Float(next() >> 40) / Float(1 << 24)
        }

        mutating func range(_ lo: Float, _ hi: Float) -> Float {
            lo + (hi - lo) * unit()
        }

        /// Box-Muller, for sensor-noise simulation.
        mutating func gaussian(sigma: Float) -> Float {
            let u1 = Swift.max(unit(), 1e-7)
            let u2 = unit()
            return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    // MARK: - Geometry

    /// An axis-aligned box room, tessellated into a grid per face.
    ///
    /// Tessellation matters: a 12-triangle box would leave the BVH with a single
    /// leaf and never exercise subdivision, so the tests would pass against a
    /// tree that was never built.
    static func room(
        width: Float = 8, height: Float = 3, depth: Float = 6,
        divisions: Int = 6
    ) -> [GPUTriangle] {
        var triangles: [GPUTriangle] = []
        let half = SIMD3<Float>(width / 2, height / 2, depth / 2)

        // Each face is defined by an origin corner and two edge vectors.
        let faces: [(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (SIMD3(-half.x, -half.y, -half.z), SIMD3(width, 0, 0), SIMD3(0, 0, depth)),   // floor
            (SIMD3(-half.x,  half.y, -half.z), SIMD3(width, 0, 0), SIMD3(0, 0, depth)),   // ceiling
            (SIMD3(-half.x, -half.y, -half.z), SIMD3(width, 0, 0), SIMD3(0, height, 0)),  // -Z wall
            (SIMD3(-half.x, -half.y,  half.z), SIMD3(width, 0, 0), SIMD3(0, height, 0)),  // +Z wall
            (SIMD3(-half.x, -half.y, -half.z), SIMD3(0, 0, depth), SIMD3(0, height, 0)),  // -X wall
            (SIMD3( half.x, -half.y, -half.z), SIMD3(0, 0, depth), SIMD3(0, height, 0)),  // +X wall
        ]

        let step = 1 / Float(divisions)
        for face in faces {
            for i in 0..<divisions {
                for j in 0..<divisions {
                    let (s0, s1) = (Float(i) * step, Float(i + 1) * step)
                    let (t0, t1) = (Float(j) * step, Float(j + 1) * step)
                    let p00 = face.origin + face.u * s0 + face.v * t0
                    let p10 = face.origin + face.u * s1 + face.v * t0
                    let p11 = face.origin + face.u * s1 + face.v * t1
                    let p01 = face.origin + face.u * s0 + face.v * t1
                    triangles.append(GPUTriangle(p00, p10, p11))
                    triangles.append(GPUTriangle(p00, p11, p01))
                }
            }
        }
        return triangles
    }

    /// Uniformly area-weighted sampling of points on a triangle soup.
    ///
    /// Area weighting, not per-triangle uniform: sampling each triangle equally
    /// would over-represent whatever happens to be finely tessellated and give
    /// ICP a misleadingly easy — or hard — distribution to work with.
    static func samplePoints(
        on triangles: [GPUTriangle],
        count: Int,
        noiseSigma: Float = 0,
        random: inout Random
    ) -> [SIMD3<Float>] {
        guard !triangles.isEmpty else { return [] }

        var cumulative: [Float] = []
        cumulative.reserveCapacity(triangles.count)
        var total: Float = 0
        for tri in triangles {
            total += length(cross(tri.b - tri.a, tri.c - tri.a)) * 0.5
            cumulative.append(total)
        }
        guard total > 0 else { return [] }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(count)
        for _ in 0..<count {
            let target = random.unit() * total
            var lo = 0, hi = cumulative.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if cumulative[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            let tri = triangles[lo]

            // Square-root parameterisation gives a uniform barycentric sample.
            var u = random.unit()
            var v = random.unit()
            if u + v > 1 { u = 1 - u; v = 1 - v }
            var p = tri.a + (tri.b - tri.a) * u + (tri.c - tri.a) * v

            if noiseSigma > 0 {
                p += SIMD3(random.gaussian(sigma: noiseSigma),
                           random.gaussian(sigma: noiseSigma),
                           random.gaussian(sigma: noiseSigma))
            }
            points.append(p)
        }
        return points
    }

    /// Points floating in open space, standing in for pallets, people and
    /// temporary works — the clutter that must not drag the registration.
    static func clutter(
        count: Int, extent: SIMD3<Float>, random: inout Random
    ) -> [SIMD3<Float>] {
        (0..<count).map { _ in
            SIMD3(random.range(-extent.x, extent.x),
                  random.range(-extent.y, extent.y),
                  random.range(-extent.z, extent.z))
        }
    }

    // MARK: - Transforms

    /// A rigid transform from yaw, pitch and a translation.
    static func transform(
        yaw: Float = 0, pitch: Float = 0, translation: SIMD3<Float> = .zero
    ) -> float4x4 {
        let qy = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let qp = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        let ry = simd_float3x3(qy)
        let rp = simd_float3x3(qp)
        // Compose by rotating the pitch basis through yaw.
        let r = simd_float3x3(ry * rp.columns.0, ry * rp.columns.1, ry * rp.columns.2)
        return float4x4(
            SIMD4(r.columns.0, 0),
            SIMD4(r.columns.1, 0),
            SIMD4(r.columns.2, 0),
            SIMD4(translation, 1)
        )
    }

    /// Worst-case disagreement between two transforms, measured where it
    /// matters: how far apart they put the same physical points.
    ///
    /// Comparing matrix elements directly would be meaningless — a small
    /// rotation error far from the origin is a large positional error, and that
    /// is precisely what an inspector would see.
    static func maximumDisplacement(
        _ a: float4x4, _ b: float4x4, over probes: [SIMD3<Float>]
    ) -> Float {
        var worst: Float = 0
        for p in probes {
            worst = Swift.max(worst, distance(a.transformPoint(p), b.transformPoint(p)))
        }
        return worst
    }

    /// Corners of the room, used as probes: they are the points furthest from
    /// the centre and so the most sensitive to residual rotation error.
    static func probeCorners(
        width: Float = 8, height: Float = 3, depth: Float = 6
    ) -> [SIMD3<Float>] {
        var probes: [SIMD3<Float>] = []
        for x in [-width / 2, width / 2] {
            for y in [-height / 2, height / 2] {
                for z in [-depth / 2, depth / 2] {
                    probes.append(SIMD3(x, y, z))
                }
            }
        }
        return probes
    }
}

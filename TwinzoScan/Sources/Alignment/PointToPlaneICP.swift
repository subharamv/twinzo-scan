import Foundation
import simd

/// Diagnostics for one ICP run, surfaced in the UI so the operator can judge
/// whether an alignment is trustworthy before recording deviations against it.
struct ICPResult {
    /// Refined LiDAR-world -> BIM-model transform.
    var worldToModel: float4x4
    /// RMS point-to-plane residual over the inlier set, in metres.
    var rmsError: Float
    /// Fraction of source points that found a correspondence within the
    /// rejection radius on the final iteration.
    var inlierRatio: Float
    var iterations: Int
    var converged: Bool
}

/// Point-to-plane ICP registering a LiDAR point cloud against the BIM mesh.
///
/// Point-to-plane rather than point-to-point because the target is a mesh, not a
/// cloud: it lets points slide along walls and floors instead of being pinned to
/// arbitrary nearest vertices, which converges in far fewer iterations on the
/// large flat surfaces that dominate industrial interiors.
///
/// The linearisation assumes small per-iteration rotations, so this needs a
/// coarse alignment to start from (see `AlignmentCoordinator`). Cold-starting it
/// on a repetitive factory bay will find a local minimum one bay over.
enum PointToPlaneICP {

    struct Parameters {
        /// Correspondences further than this are discarded outright. Should start
        /// generous and shrink as the fit tightens.
        var maxCorrespondenceDistance: Float = 0.35
        var maxIterations: Int = 30
        /// Stop when the incremental transform moves less than this (metres) and
        /// rotates less than `rotationEpsilon`.
        var translationEpsilon: Float = 1e-4
        var rotationEpsilon: Float = 1e-4
        /// Huber threshold as a multiple of the median absolute residual.
        var huberScale: Float = 1.4
        /// Below this many inliers the solve is underdetermined; bail out.
        var minimumInliers: Int = 50
        /// Correspondences whose surface normal is near-perpendicular to the
        /// viewing direction are grazing hits and are unreliable.
        var maxNormalAngleCosine: Float = 0.1

        static let coarse = Parameters(maxCorrespondenceDistance: 0.60, maxIterations: 40)
        static let fine = Parameters(maxCorrespondenceDistance: 0.12, maxIterations: 20)
    }

    /// - Parameters:
    ///   - points: source cloud in LiDAR world space.
    ///   - mesh: target BIM geometry, in model space.
    ///   - initial: current world -> model estimate to refine.
    static func align(
        points: [SIMD3<Float>],
        to mesh: BVH,
        initial: float4x4,
        parameters: Parameters = .fine
    ) -> ICPResult {
        var transform = initial
        guard !mesh.isEmpty, points.count >= parameters.minimumInliers else {
            return ICPResult(worldToModel: transform, rmsError: .nan,
                             inlierRatio: 0, iterations: 0, converged: false)
        }

        var rms = Float.nan
        var inlierRatio: Float = 0
        var converged = false
        var iteration = 0

        // Correspondence radius anneals from the configured maximum down toward
        // the fine radius, which lets an imperfect coarse pose recover without
        // letting distant clutter dominate the final iterations.
        var radius = parameters.maxCorrespondenceDistance

        while iteration < parameters.maxIterations {
            iteration += 1

            var sources: [SIMD3<Float>] = []
            var targets: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var residuals: [Float] = []
            sources.reserveCapacity(points.count)
            targets.reserveCapacity(points.count)
            normals.reserveCapacity(points.count)
            residuals.reserveCapacity(points.count)

            for p in points {
                let q = transform.transformPoint(p)
                guard let hit = mesh.closestPoint(to: q, maxDistance: radius) else { continue }
                // Reject grazing correspondences: the plane constraint carries
                // almost no information when the surface is edge-on to the ray.
                let toSurface = hit.point - q
                let len = length(toSurface)
                if len > 1e-6, abs(dot(toSurface / len, hit.normal)) < parameters.maxNormalAngleCosine {
                    continue
                }
                sources.append(q)
                targets.append(hit.point)
                normals.append(hit.normal)
                residuals.append(abs(dot(q - hit.point, hit.normal)))
            }

            guard sources.count >= parameters.minimumInliers else { break }
            inlierRatio = Float(sources.count) / Float(points.count)

            let huberDelta = max(median(of: residuals) * parameters.huberScale, 1e-3)

            // Normal equations for the 6-DoF twist [omega, translation].
            // Row i is [q_i x n_i, n_i], residual -(q_i - c_i) . n_i.
            var ata = [Double](repeating: 0, count: 36)
            var atb = [Double](repeating: 0, count: 6)
            var weightedSquares: Double = 0
            var weightSum: Double = 0

            for i in 0..<sources.count {
                let q = sources[i], c = targets[i], n = normals[i]
                let r = dot(q - c, n)
                // Huber: quadratic near zero, linear in the tail, so a handful of
                // gross mismatches cannot swing the solve.
                let absR = abs(r)
                let w = Double(absR <= huberDelta ? 1 : huberDelta / absR)

                let cxn = cross(q, n)
                let row: [Double] = [
                    Double(cxn.x), Double(cxn.y), Double(cxn.z),
                    Double(n.x), Double(n.y), Double(n.z)
                ]
                let rhs = -Double(r)

                for a in 0..<6 {
                    let wa = w * row[a]
                    atb[a] += wa * rhs
                    for b in a..<6 {
                        ata[a * 6 + b] += wa * row[b]
                    }
                }
                weightedSquares += w * Double(r * r)
                weightSum += w
            }
            // Mirror the upper triangle we filled.
            for a in 0..<6 {
                for b in 0..<a {
                    ata[a * 6 + b] = ata[b * 6 + a]
                }
            }

            rms = weightSum > 0 ? Float((weightedSquares / weightSum).squareRoot()) : .nan

            guard let x = solveSymmetric6x6(ata, atb) else { break }

            let omega = SIMD3<Float>(Float(x[0]), Float(x[1]), Float(x[2]))
            let translation = SIMD3<Float>(Float(x[3]), Float(x[4]), Float(x[5]))
            let delta = float4x4(exponentialTwist: omega, translation: translation)
            transform = delta * transform

            if length(translation) < parameters.translationEpsilon,
               length(omega) < parameters.rotationEpsilon {
                converged = true
                break
            }

            radius = max(parameters.maxCorrespondenceDistance * 0.25, radius * 0.9)
        }

        return ICPResult(worldToModel: transform, rmsError: rms,
                         inlierRatio: inlierRatio, iterations: iteration,
                         converged: converged)
    }

    // MARK: - Linear algebra

    /// Cholesky solve of a 6x6 symmetric positive-definite system, in double
    /// precision. Returns nil when the system is rank deficient, which in
    /// practice means the scan lacks geometry constraining some axis (a bare
    /// corridor of parallel walls leaves the along-corridor slide free).
    private static func solveSymmetric6x6(_ a: [Double], _ b: [Double]) -> [Double]? {
        var l = [Double](repeating: 0, count: 36)
        // Tikhonov nudge keeps a marginally-conditioned system solvable.
        let lambda = 1e-9

        for i in 0..<6 {
            for j in 0...i {
                var sum = a[i * 6 + j]
                if i == j { sum += lambda }
                for k in 0..<j {
                    sum -= l[i * 6 + k] * l[j * 6 + k]
                }
                if i == j {
                    guard sum > 1e-12 else { return nil }
                    l[i * 6 + j] = sum.squareRoot()
                } else {
                    l[i * 6 + j] = sum / l[j * 6 + j]
                }
            }
        }

        // Forward substitution, then back substitution.
        var y = [Double](repeating: 0, count: 6)
        for i in 0..<6 {
            var sum = b[i]
            for k in 0..<i { sum -= l[i * 6 + k] * y[k] }
            y[i] = sum / l[i * 6 + i]
        }
        var x = [Double](repeating: 0, count: 6)
        for i in stride(from: 5, through: 0, by: -1) {
            var sum = y[i]
            for k in (i + 1)..<6 { sum -= l[k * 6 + i] * x[k] }
            x[i] = sum / l[i * 6 + i]
        }
        return x
    }

    private static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        sorted.sort()
        return sorted[sorted.count / 2]
    }
}

extension float4x4 {
    /// Exact exponential map of a small rigid twist, rather than the usual
    /// `I + [omega]x` shortcut: the closed form stays orthonormal, so drift does
    /// not accumulate across the tens of increments a full ICP run applies.
    init(exponentialTwist omega: SIMD3<Float>, translation: SIMD3<Float>) {
        let theta = length(omega)
        var rotation = matrix_identity_float3x3
        if theta > 1e-8 {
            let axis = omega / theta
            rotation = simd_float3x3(simd_quatf(angle: theta, axis: axis))
        }
        self.init(
            SIMD4(rotation.columns.0, 0),
            SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0),
            SIMD4(translation, 1)
        )
    }

    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        (self * SIMD4(p, 1)).xyz
    }

    func transformDirection(_ v: SIMD3<Float>) -> SIMD3<Float> {
        (self * SIMD4(v, 0)).xyz
    }

    var translation: SIMD3<Float> { columns.3.xyz }
}

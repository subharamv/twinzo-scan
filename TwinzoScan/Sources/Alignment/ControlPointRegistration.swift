import Foundation
import simd

/// One surveyed correspondence: a point the operator touched in the real world,
/// paired with the point it is meant to be in the BIM model.
///
/// These are the "targets" of a target-based alignment — a column corner, a
/// setting-out mark, a survey nail, a printed target taped to a wall.
struct ControlPointPair: Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Where the operator touched, in LiDAR world space.
    var worldPoint: SIMD3<Float>
    /// The corresponding point in BIM model space.
    var modelPoint: SIMD3<Float>
    /// What the operator called it — "grid B/3 base", "north door jamb".
    var label: String = ""
    /// Element the model point was picked on, when it was picked by tapping the
    /// rendered model rather than typed in.
    var elementIndex: UInt32?
}

/// What a target-based fit determined, and what it could not.
struct RegistrationFit: Sendable {
    /// LiDAR world space -> BIM model space.
    var worldToModel: float4x4
    /// Uniform scale the fit applied. 1.0 unless scale was explicitly unlocked.
    var scale: Float
    /// RMS residual over the pairs, metres.
    var rmsError: Float
    /// Residual per input pair, same order as the input. A single bad pick shows
    /// up here as an outlier long before it shows up in the RMS.
    var residuals: [Float]
    /// How much of the pose the targets actually determined.
    var degreesOfFreedom: DegreesOfFreedom
    /// Anything the operator needs to know before trusting this.
    var warnings: [String]

    enum DegreesOfFreedom: String, Sendable {
        /// Full rigid pose from three or more non-collinear targets.
        case full
        /// Yaw and position only; roll and pitch were taken from gravity.
        case gravityConstrained
        /// Position only. Orientation was carried over from the previous pose.
        case translationOnly
    }

    /// Worst single-pair residual — the number that catches a mistyped target.
    var maxResidual: Float { residuals.max() ?? 0 }
}

enum RegistrationError: LocalizedError {
    case noPairs
    case degenerate(String)
    case scaleNotDeterminable

    var errorDescription: String? {
        switch self {
        case .noPairs:
            return "Add at least one target pair before aligning."
        case .degenerate(let detail):
            return detail
        case .scaleNotDeterminable:
            return "A single target cannot determine scale. Add a second target, or "
                 + "enter the scale from a measured reference length."
        }
    }
}

/// Target-based registration: closed-form, deterministic, and reproducible.
///
/// This is the coarse stage ICP needs and, on a site with surveyed control, is
/// often the *only* stage anyone should trust. ICP is a local optimiser that will
/// happily converge one structural bay over in a repetitive building and report
/// an excellent residual for it. Targets pin the pose to points a surveyor can
/// defend.
///
/// On scale: it is locked to 1.0 by default and must be unlocked deliberately.
/// ARKit output is metric, so a free scale parameter does not measure anything
/// real — it absorbs registration error into a 0.98x fit and makes every
/// downstream deviation wrong by 2% while the residual looks better than ever.
/// The only legitimate use is correcting a BIM export in the wrong units, and
/// that is a decision, not a default.
enum ControlPointRegistration {

    struct Options: Sendable {
        /// Let the fit solve for uniform scale. See the note above before using.
        var allowScale: Bool = false
        /// Assume both frames are gravity-aligned and solve yaw only. True is
        /// correct for ARKit, whose world origin is gravity-aligned, against a
        /// BIM model with Y (or Z) up.
        var gravityAligned: Bool = true
        /// Orientation to keep when the targets cannot determine one.
        var priorRotation: simd_float3x3 = matrix_identity_float3x3
        /// Scale to apply when a single target is used and scale is unlocked.
        var suppliedScale: Float?

        static let `default` = Options()
    }

    /// Fits a transform to the given target pairs.
    ///
    /// Dispatches on how many pairs there are, because the answerable question
    /// genuinely changes: three targets determine a pose, two determine a
    /// heading, one determines only a position.
    static func fit(pairs: [ControlPointPair], options: Options = .default) throws -> RegistrationFit {
        switch pairs.count {
        case 0:
            throw RegistrationError.noPairs
        case 1:
            return try fitSingle(pairs[0], options: options)
        case 2:
            return try fitPair(pairs[0], pairs[1], options: options)
        default:
            return try fitMany(pairs, options: options)
        }
    }

    // MARK: - One target

    /// Position only. Orientation is carried over from `priorRotation`, which in
    /// practice is whatever the operator had already lined up by hand.
    private static func fitSingle(
        _ pair: ControlPointPair, options: Options
    ) throws -> RegistrationFit {
        var scale: Float = 1
        var warnings = [
            "One target fixes position only. Heading is whatever you set by hand — "
          + "check a second point across the space before trusting the numbers."
        ]

        if options.allowScale {
            guard let supplied = options.suppliedScale, supplied > 0 else {
                throw RegistrationError.scaleNotDeterminable
            }
            scale = supplied
            warnings.append(String(format: "Scale set to %.4f from the supplied reference.", supplied))
        }

        let rotation = options.priorRotation
        let translation = pair.modelPoint - scale * (rotation * pair.worldPoint)
        let transform = float4x4(rotation: rotation, scale: scale, translation: translation)

        return RegistrationFit(
            worldToModel: transform,
            scale: scale,
            // Exactly solved by construction: one point, three unknowns.
            rmsError: 0,
            residuals: [0],
            degreesOfFreedom: .translationOnly,
            warnings: warnings
        )
    }

    // MARK: - Two targets

    /// Yaw and position, with roll and pitch taken from gravity.
    ///
    /// Two points in a gravity-aligned pair of frames is exactly enough: the
    /// horizontal vector between them fixes heading, and their midpoint fixes
    /// position. Scale, if unlocked, comes from the ratio of the two separations
    /// — which is why the targets should be as far apart as the space allows.
    private static func fitPair(
        _ first: ControlPointPair, _ second: ControlPointPair, options: Options
    ) throws -> RegistrationFit {
        guard options.gravityAligned else {
            // Without the gravity assumption, two points leave a full rotation
            // about the line joining them undetermined. Refusing beats returning
            // an arbitrary pick from that family.
            throw RegistrationError.degenerate(
                "Two targets cannot fix a pose without the gravity assumption. Add a third.")
        }

        let worldDelta = second.worldPoint - first.worldPoint
        let modelDelta = second.modelPoint - first.modelPoint

        let worldFlat = SIMD3<Float>(worldDelta.x, 0, worldDelta.z)
        let modelFlat = SIMD3<Float>(modelDelta.x, 0, modelDelta.z)
        let worldSpan = length(worldFlat)
        let modelSpan = length(modelFlat)

        guard worldSpan > 0.05, modelSpan > 0.05 else {
            throw RegistrationError.degenerate(
                "The two targets are vertically above one another, or too close together. "
              + "Heading needs a horizontal separation — put them at least a few metres apart.")
        }

        var warnings: [String] = []
        if worldSpan < 2.0 {
            warnings.append(String(
                format: "Targets are only %.1f m apart. Heading error grows as they get closer; "
                      + "aim for opposite ends of the space.", worldSpan))
        }

        var scale: Float = 1
        if options.allowScale {
            scale = modelSpan / worldSpan
            warnings.append(String(
                format: "Scale solved as %.4f. LiDAR is already metric, so anything more than a "
                      + "fraction of a percent from 1.0 means the model units are wrong.", scale))
        } else {
            let implied = modelSpan / worldSpan
            if abs(implied - 1) > 0.02 {
                warnings.append(String(
                    format: "Target separation differs by %.1f%% between scan and model. "
                          + "Check the model units or the target picks.", (implied - 1) * 100))
            }
        }

        // Heading is the signed angle between the two horizontal vectors, taken
        // about the gravity axis.
        //
        // The -z in the atan2 is not cosmetic: a right-handed rotation about +Y
        // carries +X toward -Z, so measuring the bearing with +z produces a yaw
        // of the correct magnitude and the wrong sign — an error that looks
        // plausible on a symmetric building and puts the model backwards on
        // every other one.
        let yaw = atan2(-modelFlat.z, modelFlat.x) - atan2(-worldFlat.z, worldFlat.x)
        let rotation = simd_float3x3(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))

        let worldCentroid = (first.worldPoint + second.worldPoint) * 0.5
        let modelCentroid = (first.modelPoint + second.modelPoint) * 0.5
        let translation = modelCentroid - scale * (rotation * worldCentroid)
        let transform = float4x4(rotation: rotation, scale: scale, translation: translation)

        let pairs = [first, second]
        let residuals = pairs.map {
            distance(transform.transformPoint($0.worldPoint), $0.modelPoint)
        }

        warnings.append("Roll and pitch came from gravity, not from the targets.")

        return RegistrationFit(
            worldToModel: transform,
            scale: scale,
            rmsError: rms(residuals),
            residuals: residuals,
            degreesOfFreedom: .gravityConstrained,
            warnings: warnings
        )
    }

    // MARK: - Three or more targets

    /// Full rigid fit by Horn's absolute-orientation method, plus a
    /// leave-one-out check for a mispaired target.
    private static func fitMany(
        _ pairs: [ControlPointPair], options: Options
    ) throws -> RegistrationFit {
        let solution = try solve(pairs, options: options)
        var warnings = solution.warnings

        if let culprit = mispairedTarget(in: pairs, options: options, baseline: solution.rms) {
            let pair = pairs[culprit.index]
            let name = pair.label.isEmpty ? "Target \(culprit.index + 1)" : pair.label
            warnings.append(String(
                format: "%@ looks mispaired: dropping it takes the fit from %.0f mm to %.0f mm. "
                      + "Check it against the model before trusting this alignment.",
                name, solution.rms * 1000, culprit.reducedRMS * 1000))
        }

        return RegistrationFit(
            worldToModel: solution.transform,
            scale: solution.scale,
            rmsError: solution.rms,
            residuals: solution.residuals,
            degreesOfFreedom: .full,
            warnings: warnings
        )
    }

    private struct Solution {
        var transform: float4x4
        var scale: Float
        var residuals: [Float]
        var rms: Float
        var warnings: [String]
    }

    /// The closed-form fit itself, with no diagnostics. Split out so the
    /// leave-one-out pass can re-run it without recursing into its own analysis.
    private static func solve(
        _ pairs: [ControlPointPair], options: Options
    ) throws -> Solution {
        let world = pairs.map(\.worldPoint)
        let model = pairs.map(\.modelPoint)

        let worldCentroid = centroid(world)
        let modelCentroid = centroid(model)
        let a = world.map { $0 - worldCentroid }
        let b = model.map { $0 - modelCentroid }

        let worldSpread = a.reduce(Float(0)) { $0 + length_squared($1) }
        guard worldSpread > 1e-6 else {
            throw RegistrationError.degenerate("All targets are at the same place.")
        }

        // Collinearity has to be caught here rather than left to the eigen-solve.
        // Horn's method is perfectly happy with targets on a line: it returns one
        // arbitrary member of the family of rotations about that line, fitting
        // the targets exactly while the rest of the building is rolled to a
        // random angle. A confident answer with an undetermined axis is the worst
        // possible outcome, so refuse instead.
        guard !isCollinear(a) else {
            throw RegistrationError.degenerate(
                "The targets lie on a straight line, which leaves the rotation about that line "
              + "undetermined. Add a target well off the line.")
        }

        guard let rotation = Horn.rotation(from: a, to: b) else {
            throw RegistrationError.degenerate(
                "The targets do not determine a rotation. Spread them out across the space.")
        }

        var warnings: [String] = []

        // Umeyama's least-squares scale: the projection of the rotated source
        // onto the target, over the source's own spread.
        var scale: Float = 1
        let projection = zip(a, b).reduce(Float(0)) { $0 + dot($1.1, rotation * $1.0) }
        let solvedScale = projection / worldSpread
        if options.allowScale {
            guard solvedScale > 0 else {
                throw RegistrationError.degenerate(
                    "The fit wants a negative scale, which means the target pairs are mismatched. "
                  + "Check that each scan point is paired with the right model point.")
            }
            scale = solvedScale
            warnings.append(String(format: "Scale solved as %.4f.", solvedScale))
        } else if abs(solvedScale - 1) > 0.02 {
            warnings.append(String(
                format: "Targets imply a %.1f%% scale error that has been ignored because scale is "
                      + "locked. Check the model units.", (solvedScale - 1) * 100))
        }

        let translation = modelCentroid - scale * (rotation * worldCentroid)
        let transform = float4x4(rotation: rotation, scale: scale, translation: translation)

        let residuals = pairs.map {
            distance(transform.transformPoint($0.worldPoint), $0.modelPoint)
        }

        return Solution(transform: transform, scale: scale, residuals: residuals,
                        rms: rms(residuals), warnings: warnings)
    }

    /// Finds a target whose removal transforms the fit.
    ///
    /// Comparing each residual against the RMS does not work, and it is worth
    /// being clear why: least squares distributes a bad pick's error across
    /// every pair and inflates the RMS at the same time, so the culprit ends up
    /// only modestly above a threshold it helped raise. Refitting without each
    /// pair sidesteps that entirely — a genuinely mispaired target is the one
    /// whose absence makes everything else snap into agreement.
    private static func mispairedTarget(
        in pairs: [ControlPointPair], options: Options, baseline: Float
    ) -> (index: Int, reducedRMS: Float)? {
        // Below four pairs there is nothing to leave out: dropping one from three
        // leaves a fit that is exact by construction and proves nothing.
        guard pairs.count >= 4 else { return nil }
        // A fit that is already tight has no outlier worth reporting, whatever
        // the ratios say.
        guard baseline > 0.005 else { return nil }

        var best: (index: Int, reducedRMS: Float)?
        for i in pairs.indices {
            var reduced = pairs
            reduced.remove(at: i)
            guard let solution = try? solve(reduced, options: options) else { continue }
            if solution.rms < (best?.reducedRMS ?? .greatestFiniteMagnitude) {
                best = (i, solution.rms)
            }
        }

        guard let best, best.reducedRMS < baseline * 0.4 else { return nil }
        return best
    }

    /// True when centred points lie on a line to within a fraction of their span.
    ///
    /// The reference direction is taken from the point furthest from the
    /// centroid, which is exact for genuinely collinear input and a reasonable
    /// principal axis otherwise — enough for a guard, and deterministic, which a
    /// power iteration would not be.
    private static func isCollinear(_ centred: [SIMD3<Float>]) -> Bool {
        guard let furthest = centred.max(by: { length_squared($0) < length_squared($1) })
        else { return true }
        let span = length(furthest)
        guard span > 1e-6 else { return true }
        let axis = furthest / span

        var maximumPerpendicular: Float = 0
        for point in centred {
            let perpendicular = point - axis * dot(point, axis)
            maximumPerpendicular = max(maximumPerpendicular, length(perpendicular))
        }
        return maximumPerpendicular < max(1e-3, span * 0.01)
    }

    // MARK: - Helpers

    private static func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        return points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
    }

    private static func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(values.count)).squareRoot()
    }
}

// MARK: - Horn's absolute orientation

/// Closed-form optimal rotation between two centred point sets.
///
/// Horn's quaternion formulation rather than the more familiar SVD one: it needs
/// only a symmetric 4x4 eigen-solve, which is a few dozen lines of Jacobi
/// rotations, and it cannot return a reflection. An SVD-based Kabsch has to
/// detect and correct the reflection case explicitly, and getting that wrong
/// produces a mirrored model that still fits the targets.
enum Horn {

    /// Optimal rotation taking `a` onto `b`. Nil when the configuration is
    /// degenerate (all points coincident, or collinear).
    static func rotation(from a: [SIMD3<Float>], to b: [SIMD3<Float>]) -> simd_float3x3? {
        guard a.count == b.count, a.count >= 3 else { return nil }

        // Cross-covariance, accumulated in double precision: the eigen-solve
        // below is sensitive to its conditioning and site coordinates are often
        // large numbers with small differences.
        var s = [Double](repeating: 0, count: 9)
        for i in 0..<a.count {
            let p = a[i], q = b[i]
            let pv = [Double(p.x), Double(p.y), Double(p.z)]
            let qv = [Double(q.x), Double(q.y), Double(q.z)]
            for j in 0..<3 {
                for k in 0..<3 {
                    s[j * 3 + k] += pv[j] * qv[k]
                }
            }
        }

        func sxx(_ j: Int, _ k: Int) -> Double { s[j * 3 + k] }
        let trace = sxx(0, 0) + sxx(1, 1) + sxx(2, 2)

        // Horn's N matrix. Its dominant eigenvector is the quaternion of the
        // optimal rotation, ordered (w, x, y, z).
        var n = [Double](repeating: 0, count: 16)
        func set(_ r: Int, _ c: Int, _ v: Double) { n[r * 4 + c] = v; n[c * 4 + r] = v }
        set(0, 0, trace)
        set(0, 1, sxx(1, 2) - sxx(2, 1))
        set(0, 2, sxx(2, 0) - sxx(0, 2))
        set(0, 3, sxx(0, 1) - sxx(1, 0))
        set(1, 1, sxx(0, 0) - sxx(1, 1) - sxx(2, 2))
        set(1, 2, sxx(0, 1) + sxx(1, 0))
        set(1, 3, sxx(2, 0) + sxx(0, 2))
        set(2, 2, -sxx(0, 0) + sxx(1, 1) - sxx(2, 2))
        set(2, 3, sxx(1, 2) + sxx(2, 1))
        set(3, 3, -sxx(0, 0) - sxx(1, 1) + sxx(2, 2))

        guard let q = dominantEigenvector(n) else { return nil }

        let quat = simd_quatf(ix: Float(q[1]), iy: Float(q[2]), iz: Float(q[3]), r: Float(q[0]))
        return simd_float3x3(quat)
    }

    /// Cyclic Jacobi eigen-decomposition of a symmetric 4x4, returning the
    /// eigenvector of the largest eigenvalue.
    ///
    /// Jacobi rather than a characteristic-polynomial root-finder because it is
    /// unconditionally stable for symmetric input and needs no case analysis for
    /// repeated eigenvalues — which is exactly the situation a symmetric target
    /// layout produces.
    private static func dominantEigenvector(_ input: [Double]) -> [Double]? {
        var a = input
        // Eigenvectors accumulate here as columns, starting from the identity.
        var v = [Double](repeating: 0, count: 16)
        for i in 0..<4 { v[i * 4 + i] = 1 }

        for _ in 0..<64 {
            // Largest off-diagonal magnitude drives both the choice of pivot and
            // the convergence test.
            var p = 0, q = 1
            var offDiagonal = 0.0
            for i in 0..<4 {
                for j in (i + 1)..<4 {
                    let magnitude = abs(a[i * 4 + j])
                    if magnitude > offDiagonal {
                        offDiagonal = magnitude
                        p = i; q = j
                    }
                }
            }
            if offDiagonal < 1e-14 { break }

            let app = a[p * 4 + p], aqq = a[q * 4 + q], apq = a[p * 4 + q]
            let theta = 0.5 * (aqq - app) / apq
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c

            for k in 0..<4 {
                let akp = a[k * 4 + p], akq = a[k * 4 + q]
                a[k * 4 + p] = c * akp - s * akq
                a[k * 4 + q] = s * akp + c * akq
            }
            for k in 0..<4 {
                let apk = a[p * 4 + k], aqk = a[q * 4 + k]
                a[p * 4 + k] = c * apk - s * aqk
                a[q * 4 + k] = s * apk + c * aqk
            }
            for k in 0..<4 {
                let vkp = v[k * 4 + p], vkq = v[k * 4 + q]
                v[k * 4 + p] = c * vkp - s * vkq
                v[k * 4 + q] = s * vkp + c * vkq
            }
        }

        var best = 0
        for i in 1..<4 where a[i * 4 + i] > a[best * 4 + best] { best = i }

        var vector = (0..<4).map { v[$0 * 4 + best] }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-12 else { return nil }
        vector = vector.map { $0 / norm }
        return vector
    }
}

// MARK: - Matrix construction

extension float4x4 {
    /// Builds a similarity transform: scale, then rotate, then translate.
    ///
    /// Named parameters rather than an overload of the rotation-only init in
    /// AlignmentCoordinator, so that a call site can never silently drop the
    /// scale by matching the shorter signature.
    init(rotation: simd_float3x3, scale: Float, translation: SIMD3<Float>) {
        self.init(
            SIMD4(rotation.columns.0 * scale, 0),
            SIMD4(rotation.columns.1 * scale, 0),
            SIMD4(rotation.columns.2 * scale, 0),
            SIMD4(translation, 1)
        )
    }

    /// Splits a similarity transform back into rotation, uniform scale and
    /// translation.
    ///
    /// Assumes uniform scale, which holds for everything this app produces:
    /// every path that can set a scale sets one number. A non-uniform matrix
    /// would come back with the average of its axis scales, which is the least
    /// surprising answer available and still keeps the rotation orthonormal.
    var decomposedSimilarity: (rotation: simd_float3x3, scale: Float, translation: SIMD3<Float>) {
        let c0 = columns.0.xyz, c1 = columns.1.xyz, c2 = columns.2.xyz
        let scales = SIMD3<Float>(length(c0), length(c1), length(c2))
        let scale = (scales.x + scales.y + scales.z) / 3

        guard scale > 1e-6 else {
            return (matrix_identity_float3x3, 1, columns.3.xyz)
        }
        let rotation = simd_float3x3(c0 / scales.x, c1 / scales.y, c2 / scales.z)
        return (rotation, scale, columns.3.xyz)
    }

    /// Worst-case distance between where this transform and `other` put the same
    /// point, over a sphere of the given radius.
    ///
    /// Comparing matrix entries would be meaningless. What an inspector sees is
    /// displacement, and a rotation error that is invisible at the origin is
    /// centimetres away at the far wall — so the comparison is made where the
    /// building actually is.
    func maximumDisplacement(from other: float4x4, atRadius radius: Float) -> Float {
        let probes: [SIMD3<Float>] = [
            SIMD3(radius, 0, 0), SIMD3(-radius, 0, 0),
            SIMD3(0, radius, 0), SIMD3(0, -radius, 0),
            SIMD3(0, 0, radius), SIMD3(0, 0, -radius),
            .zero,
        ]
        var worst: Float = 0
        for probe in probes {
            worst = max(worst, distance(transformPoint(probe), other.transformPoint(probe)))
        }
        return worst
    }
}

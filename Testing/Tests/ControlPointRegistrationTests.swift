import XCTest
import simd
@testable import TwinzoCore

/// Target-based registration is the stage an operator reaches for when ICP
/// cannot be trusted — a repetitive building, or a job with surveyed control.
/// It is closed-form, so these tests can assert exact answers rather than
/// convergence, and every degenerate configuration has to be refused loudly
/// rather than answered with an arbitrary member of the solution family.
final class ControlPointRegistrationTests: XCTestCase {

    private func pair(_ world: SIMD3<Float>, _ model: SIMD3<Float>,
                      _ label: String = "") -> ControlPointPair {
        ControlPointPair(worldPoint: world, modelPoint: model, label: label)
    }

    /// Builds pairs by pushing known world points through a known transform, so
    /// the fit has an exact answer to be measured against.
    private func pairs(
        through transform: float4x4, world: [SIMD3<Float>]
    ) -> [ControlPointPair] {
        world.map { pair($0, transform.transformPoint($0)) }
    }

    // MARK: - Three or more targets

    func testRecoversAKnownRigidTransform() throws {
        let truth = SyntheticScene.transform(
            yaw: 0.7, pitch: 0.2, translation: SIMD3(3, -1, 2))
        let world: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(0, 0, 4), SIMD3(1, 2.5, 3),
        ]

        let fit = try ControlPointRegistration.fit(pairs: pairs(through: truth, world: world))

        XCTAssertEqual(fit.degreesOfFreedom, .full)
        XCTAssertEqual(fit.scale, 1, accuracy: 1e-4)
        XCTAssertLessThan(fit.rmsError, 1e-4)
        let displacement = SyntheticScene.maximumDisplacement(
            fit.worldToModel, truth, over: SyntheticScene.probeCorners())
        XCTAssertLessThan(displacement, 1e-3)
    }

    /// The reflection case. An SVD-based Kabsch that forgets to correct for a
    /// negative determinant returns a mirrored "rotation" that fits the targets
    /// beautifully and renders the building inside out. Horn's quaternion form
    /// cannot express a reflection at all, and this pins that property down.
    func testFitIsNeverAReflection() throws {
        let world: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(0, 3, 0), SIMD3(0, 0, 2),
        ]
        // Model points are the world points mirrored through the X axis, which
        // no rotation can reach.
        let mirrored = world.map { SIMD3<Float>(-$0.x, $0.y, $0.z) }
        let fit = try ControlPointRegistration.fit(
            pairs: zip(world, mirrored).map { pair($0, $1) })

        let r = fit.worldToModel
        let determinant =
            dot(SIMD3(r.columns.0.x, r.columns.0.y, r.columns.0.z),
                cross(SIMD3(r.columns.1.x, r.columns.1.y, r.columns.1.z),
                      SIMD3(r.columns.2.x, r.columns.2.y, r.columns.2.z)))
        XCTAssertGreaterThan(determinant, 0,
                             "A mirrored target set must not produce a mirrored transform")
        // And it must not pretend the mirrored data fitted well.
        XCTAssertGreaterThan(fit.rmsError, 0.1)
    }

    func testCollinearTargetsAreRefused() {
        let world: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]
        let truth = SyntheticScene.transform(yaw: 0.3, translation: SIMD3(1, 0, 0))
        XCTAssertThrowsError(
            try ControlPointRegistration.fit(pairs: pairs(through: truth, world: world))
        ) { error in
            guard case RegistrationError.degenerate = error else {
                return XCTFail("Expected a degeneracy error, got \(error)")
            }
        }
    }

    // MARK: - Scale

    func testScaleStaysLockedByDefaultAndSaysSo() throws {
        // Model points are 5% larger than the scan: a units problem, not a pose.
        let world: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(0, 0, 3), SIMD3(1, 2, 1),
        ]
        let model = world.map { $0 * 1.05 }
        let fit = try ControlPointRegistration.fit(pairs: zip(world, model).map { pair($0, $1) })

        XCTAssertEqual(fit.scale, 1, accuracy: 1e-6,
                       "Scale must not float free unless it was explicitly unlocked")
        XCTAssertTrue(fit.warnings.contains { $0.contains("scale error") },
                      "An ignored scale error has to be surfaced, not swallowed")
    }

    func testScaleIsSolvedWhenExplicitlyUnlocked() throws {
        let world: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(0, 0, 3), SIMD3(1, 2, 1),
        ]
        let model = world.map { $0 * 1.05 }
        var options = ControlPointRegistration.Options.default
        options.allowScale = true

        let fit = try ControlPointRegistration.fit(
            pairs: zip(world, model).map { pair($0, $1) }, options: options)

        XCTAssertEqual(fit.scale, 1.05, accuracy: 1e-3)
        XCTAssertLessThan(fit.rmsError, 1e-4)
    }

    // MARK: - Two targets

    func testTwoTargetsRecoverYawAndPosition() throws {
        let truth = SyntheticScene.transform(yaw: -0.9, translation: SIMD3(2, 0.5, -3))
        let world: [SIMD3<Float>] = [SIMD3(-4, 0, -2), SIMD3(5, 1, 3)]

        let fit = try ControlPointRegistration.fit(pairs: pairs(through: truth, world: world))

        XCTAssertEqual(fit.degreesOfFreedom, .gravityConstrained)
        XCTAssertLessThan(fit.rmsError, 1e-3)
        let displacement = SyntheticScene.maximumDisplacement(
            fit.worldToModel, truth, over: SyntheticScene.probeCorners())
        XCTAssertLessThan(displacement, 1e-2)
    }

    /// Two points stacked vertically say nothing about heading. Answering
    /// anyway would put the model at an arbitrary rotation that looks committed.
    func testVerticallyStackedTargetsAreRefused() {
        let pairs = [
            pair(SIMD3(0, 0, 0), SIMD3(1, 0, 1)),
            pair(SIMD3(0, 3, 0), SIMD3(1, 3, 1)),
        ]
        XCTAssertThrowsError(try ControlPointRegistration.fit(pairs: pairs)) { error in
            guard case RegistrationError.degenerate = error else {
                return XCTFail("Expected a degeneracy error, got \(error)")
            }
        }
    }

    func testCloselySpacedTargetsWarnAboutHeadingPrecision() throws {
        let truth = SyntheticScene.transform(yaw: 0.4, translation: .zero)
        let world: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0.8, 0, 0.3)]
        let fit = try ControlPointRegistration.fit(pairs: pairs(through: truth, world: world))
        XCTAssertTrue(fit.warnings.contains { $0.contains("apart") })
    }

    func testTwoTargetsSolveScaleFromTheirSeparation() throws {
        var options = ControlPointRegistration.Options.default
        options.allowScale = true
        let pairs = [
            pair(SIMD3(0, 0, 0), SIMD3(0, 0, 0)),
            pair(SIMD3(10, 0, 0), SIMD3(12, 0, 0)),
        ]
        let fit = try ControlPointRegistration.fit(pairs: pairs, options: options)
        XCTAssertEqual(fit.scale, 1.2, accuracy: 1e-4)
    }

    // MARK: - One target

    func testSingleTargetPlacesExactlyAndAdmitsItsLimits() throws {
        var options = ControlPointRegistration.Options.default
        options.priorRotation = simd_float3x3(simd_quatf(angle: 0.5, axis: SIMD3(0, 1, 0)))

        let single = pair(SIMD3(1, 0, 2), SIMD3(7, 3, -4))
        let fit = try ControlPointRegistration.fit(pairs: [single], options: options)

        XCTAssertEqual(fit.degreesOfFreedom, .translationOnly)
        let landed = fit.worldToModel.transformPoint(single.worldPoint)
        XCTAssertLessThan(distance(landed, single.modelPoint), 1e-4)
        XCTAssertFalse(fit.warnings.isEmpty,
                       "A one-target fit must say that heading is unconstrained")
    }

    /// One point and three unknowns: scale is simply not in the data. The only
    /// safe answers are to refuse, or to use a number the operator supplied.
    func testSingleTargetCannotInventScale() {
        var options = ControlPointRegistration.Options.default
        options.allowScale = true
        XCTAssertThrowsError(
            try ControlPointRegistration.fit(
                pairs: [pair(SIMD3(1, 0, 0), SIMD3(2, 0, 0))], options: options)
        ) { error in
            guard case RegistrationError.scaleNotDeterminable = error else {
                return XCTFail("Expected scaleNotDeterminable, got \(error)")
            }
        }
    }

    func testSingleTargetAcceptsASuppliedScale() throws {
        var options = ControlPointRegistration.Options.default
        options.allowScale = true
        options.suppliedScale = 0.001  // a millimetre-unit model

        let single = pair(SIMD3(2, 0, 0), SIMD3(2, 0, 0))
        let fit = try ControlPointRegistration.fit(pairs: [single], options: options)

        XCTAssertEqual(fit.scale, 0.001, accuracy: 1e-9)
        XCTAssertLessThan(distance(fit.worldToModel.transformPoint(single.worldPoint),
                                   single.modelPoint), 1e-4)
    }

    // MARK: - Bad picks

    /// A mispaired target is the most common field mistake and the one the RMS
    /// hides best: four good picks and one wrong one still average to a
    /// respectable number.
    func testAMispairedTargetIsCalledOut() throws {
        let truth = SyntheticScene.transform(yaw: 0.2, translation: SIMD3(1, 0, 1))
        let world: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(6, 0, 0), SIMD3(0, 0, 5), SIMD3(6, 0, 5), SIMD3(3, 2, 2),
        ]
        var built = pairs(through: truth, world: world)
        built[4].label = "grid C/2"
        built[4].modelPoint += SIMD3(0.9, 0, 0)   // wrong point picked

        let fit = try ControlPointRegistration.fit(pairs: built)

        XCTAssertEqual(fit.residuals.count, 5)
        XCTAssertTrue(fit.warnings.contains { $0.contains("grid C/2") },
                      "The outlying pair has to be named, not just averaged in")
        XCTAssertGreaterThan(fit.maxResidual, fit.rmsError)
    }

    func testNoPairsIsRefused() {
        XCTAssertThrowsError(try ControlPointRegistration.fit(pairs: [])) { error in
            guard case RegistrationError.noPairs = error else {
                return XCTFail("Expected noPairs, got \(error)")
            }
        }
    }
}

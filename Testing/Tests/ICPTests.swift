import XCTest
import simd
@testable import TwinzoCore

/// Registration tests.
///
/// The pattern throughout: take a known ground-truth transform, perturb it to
/// simulate an imperfect hand placement, run ICP, and measure how far the
/// recovered pose puts the room's corners from where the truth puts them. That
/// last part matters — a residual rotation of a fraction of a degree is
/// invisible in the matrix and 20 mm of error at the far wall, which is exactly
/// the error an inspector would be shown.
final class ICPTests: XCTestCase {

    private let room = SyntheticScene.room()
    private lazy var mesh = BVH(triangles: room)
    private let probes = SyntheticScene.probeCorners()

    /// Builds a scan of the room as seen from world space, given the true
    /// model-to-world placement.
    private func scan(
        modelToWorld: float4x4, count: Int = 3000,
        noiseSigma: Float = 0, seed: UInt64 = 99
    ) -> [SIMD3<Float>] {
        var random = SyntheticScene.Random(seed: seed)
        let modelPoints = SyntheticScene.samplePoints(
            on: room, count: count, noiseSigma: noiseSigma, random: &random
        )
        return modelPoints.map { modelToWorld.transformPoint($0) }
    }

    // MARK: - Core convergence

    func testRecoversAKnownTransformFromCleanData() {
        let truth = SyntheticScene.transform(
            yaw: 0.6, translation: SIMD3(3.0, 0.5, -2.0)
        )
        let points = scan(modelToWorld: truth)

        // A hand placement roughly 4 degrees and 15 cm out.
        let guess = SyntheticScene.transform(
            yaw: 0.6 + 0.07, translation: SIMD3(3.10, 0.55, -1.90)
        )

        let result = PointToPlaneICP.align(
            points: points, to: mesh, initial: guess.inverse, parameters: .coarse
        )

        XCTAssertTrue(result.rmsError.isFinite, "ICP produced no usable residual")
        let error = SyntheticScene.maximumDisplacement(
            result.worldToModel, truth.inverse, over: probes
        )
        XCTAssertLessThan(error, 0.005,
                          "Recovered pose is \(error * 1000) mm out at the room corners")
    }

    func testTwoPassRefinementBeatsASinglePass() {
        // This is the sequence AlignmentCoordinator runs, and the reason it runs
        // two passes rather than one: verify the tight pass actually improves on
        // the loose one rather than just costing time.
        let truth = SyntheticScene.transform(yaw: -0.35, translation: SIMD3(-1.5, 0.2, 2.5))
        let points = scan(modelToWorld: truth, noiseSigma: 0.004)
        let guess = SyntheticScene.transform(yaw: -0.35 + 0.09, translation: SIMD3(-1.35, 0.28, 2.62))

        let coarse = PointToPlaneICP.align(
            points: points, to: mesh, initial: guess.inverse, parameters: .coarse
        )
        let fine = PointToPlaneICP.align(
            points: points, to: mesh, initial: coarse.worldToModel, parameters: .fine
        )

        let coarseError = SyntheticScene.maximumDisplacement(
            coarse.worldToModel, truth.inverse, over: probes)
        let fineError = SyntheticScene.maximumDisplacement(
            fine.worldToModel, truth.inverse, over: probes)

        XCTAssertLessThanOrEqual(fineError, coarseError + 1e-4,
                                 "The fine pass made the alignment worse")
        XCTAssertLessThan(fineError, 0.010)
    }

    func testConvergesUnderRealisticSensorNoise() {
        // 8 mm sigma is in the region of Apple LiDAR noise at close range.
        // Individual points are badly wrong; the fit over thousands should not be.
        let truth = SyntheticScene.transform(yaw: 0.2, translation: SIMD3(1.0, -0.3, 0.8))
        let points = scan(modelToWorld: truth, count: 4000, noiseSigma: 0.008)
        let guess = SyntheticScene.transform(yaw: 0.2 + 0.05, translation: SIMD3(1.08, -0.25, 0.9))

        let result = PointToPlaneICP.align(
            points: points, to: mesh, initial: guess.inverse, parameters: .coarse
        )

        let error = SyntheticScene.maximumDisplacement(
            result.worldToModel, truth.inverse, over: probes)
        XCTAssertLessThan(error, 0.015,
                          "Noise averaging failed: \(error * 1000) mm at the corners")
    }

    func testClutterDoesNotDragTheFit() {
        // A quarter of the scan is junk floating in mid-air — pallets, racking,
        // people. Without Huber weighting and correspondence rejection this is
        // the case that pulls the model off the walls.
        let truth = SyntheticScene.transform(yaw: 0.15, translation: SIMD3(0.5, 0, 0.5))
        var random = SyntheticScene.Random(seed: 7)

        var modelPoints = SyntheticScene.samplePoints(
            on: room, count: 3000, noiseSigma: 0.004, random: &random)
        modelPoints += SyntheticScene.clutter(
            count: 1000, extent: SIMD3(3.5, 1.2, 2.5), random: &random)
        let points = modelPoints.map { truth.transformPoint($0) }

        let guess = SyntheticScene.transform(yaw: 0.15 + 0.05, translation: SIMD3(0.6, 0.05, 0.58))
        let result = PointToPlaneICP.align(
            points: points, to: mesh, initial: guess.inverse, parameters: .coarse
        )

        let error = SyntheticScene.maximumDisplacement(
            result.worldToModel, truth.inverse, over: probes)
        XCTAssertLessThan(error, 0.020,
                          "Clutter dragged the registration \(error * 1000) mm off")
    }

    func testIdentityInputStaysPut() {
        // Already aligned: ICP must not wander. A solver that drifts when handed
        // a perfect fit will slowly destroy a good alignment on re-runs.
        let points = scan(modelToWorld: matrix_identity_float4x4)
        let result = PointToPlaneICP.align(
            points: points, to: mesh,
            initial: matrix_identity_float4x4, parameters: .fine
        )

        let error = SyntheticScene.maximumDisplacement(
            result.worldToModel, matrix_identity_float4x4, over: probes)
        XCTAssertLessThan(error, 0.002)
        XCTAssertTrue(result.converged, "ICP should converge immediately on an exact fit")
    }

    // MARK: - Reported diagnostics

    func testInlierRatioIsHighForACleanFit() {
        let points = scan(modelToWorld: matrix_identity_float4x4)
        let result = PointToPlaneICP.align(
            points: points, to: mesh,
            initial: matrix_identity_float4x4, parameters: .fine
        )
        // These are the numbers AlignmentCoordinator gates acceptance on, so a
        // clean fit must comfortably clear its thresholds.
        XCTAssertGreaterThan(result.inlierRatio, 0.9)
        XCTAssertLessThan(result.rmsError, 0.01)
    }

    func testGrosslyWrongPlacementIsReportedAsSuch() {
        // The model dropped in the wrong place entirely. The important property
        // is not that ICP recovers — it cannot — but that it reports a residual
        // or inlier ratio bad enough for the coordinator to reject the result.
        let points = scan(modelToWorld: matrix_identity_float4x4)
        let wrong = SyntheticScene.transform(yaw: 1.4, translation: SIMD3(25, 0, 25))

        let result = PointToPlaneICP.align(
            points: points, to: mesh, initial: wrong.inverse, parameters: .coarse
        )

        let plausible = result.rmsError.isFinite
            && result.rmsError <= 0.08
            && result.inlierRatio >= 0.35
        XCTAssertFalse(plausible,
                       "A 25 m placement error was reported as an acceptable fit "
                     + "(rms \(result.rmsError), inliers \(result.inlierRatio))")
    }

    // MARK: - Degenerate input

    func testEmptyPointCloudIsHandled() {
        let result = PointToPlaneICP.align(
            points: [], to: mesh, initial: matrix_identity_float4x4
        )
        XCTAssertFalse(result.converged)
        XCTAssertEqual(result.iterations, 0)
    }

    func testEmptyMeshIsHandled() {
        var random = SyntheticScene.Random(seed: 3)
        let points = SyntheticScene.samplePoints(on: room, count: 100, random: &random)
        let result = PointToPlaneICP.align(
            points: points, to: BVH(triangles: []), initial: matrix_identity_float4x4
        )
        XCTAssertFalse(result.converged)
    }

    func testTooFewPointsBailsOutWithoutCrashing() {
        var random = SyntheticScene.Random(seed: 4)
        let points = SyntheticScene.samplePoints(on: room, count: 10, random: &random)
        let result = PointToPlaneICP.align(
            points: points, to: mesh, initial: matrix_identity_float4x4
        )
        // Below `minimumInliers` the normal equations are underdetermined.
        XCTAssertFalse(result.converged)
    }
}

import XCTest
import simd
@testable import TwinzoCore

/// The similarity helpers sit under both target registration and the drift
/// monitor. A decomposition that loses scale would silently un-correct a
/// units fix on the next manual nudge, and a displacement metric measured at the
/// origin would report a rotational drift of zero right up until the far wall
/// was a hand's width out of place.
final class SimilarityTransformTests: XCTestCase {

    func testRoundTripsThroughDecomposition() {
        let rotation = simd_float3x3(simd_quatf(angle: 0.83, axis: normalize(SIMD3<Float>(1, 2, 3))))
        let original = float4x4(rotation: rotation, scale: 0.001,
                                translation: SIMD3(12, -3, 7))

        let parts = original.decomposedSimilarity
        XCTAssertEqual(parts.scale, 0.001, accuracy: 1e-7)
        XCTAssertEqual(parts.translation, SIMD3(12, -3, 7))

        let rebuilt = float4x4(rotation: parts.rotation, scale: parts.scale,
                               translation: parts.translation)
        let probes = SyntheticScene.probeCorners()
        XCTAssertLessThan(
            SyntheticScene.maximumDisplacement(original, rebuilt, over: probes), 1e-4)
    }

    /// The decomposition has to hand back an orthonormal basis even when the
    /// input has drifted, or repeated adopt-and-rebuild cycles would compound a
    /// shear through the model.
    func testDecomposedRotationStaysOrthonormal() {
        let drifted = float4x4(
            SIMD4(1.0001, 0.0002, 0, 0),
            SIMD4(0.0002, 0.9998, 0, 0),
            SIMD4(0, 0, 1.0003, 0),
            SIMD4(1, 2, 3, 1))
        let rotation = drifted.decomposedSimilarity.rotation

        XCTAssertEqual(length(rotation.columns.0), 1, accuracy: 1e-4)
        XCTAssertEqual(length(rotation.columns.1), 1, accuracy: 1e-4)
        XCTAssertEqual(length(rotation.columns.2), 1, accuracy: 1e-4)
    }

    func testDegenerateMatrixDecomposesToSomethingUsable() {
        let collapsed = float4x4(SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0),
                                 SIMD4(0, 0, 0, 0), SIMD4(4, 5, 6, 1))
        let parts = collapsed.decomposedSimilarity
        XCTAssertEqual(parts.scale, 1)
        XCTAssertEqual(parts.translation, SIMD3(4, 5, 6))
    }

    // MARK: - Drift measurement

    func testPureTranslationIsMeasuredAtItsFullMagnitude() {
        let a = matrix_identity_float4x4
        let b = SyntheticScene.transform(translation: SIMD3(0.03, 0, 0))
        XCTAssertEqual(a.maximumDisplacement(from: b, atRadius: 10), 0.03, accuracy: 1e-5)
    }

    /// The reason the metric takes a radius at all. A tenth of a degree is
    /// nothing at the origin and centimetres across a bay, and it is the second
    /// number the operator experiences.
    func testSmallRotationsShowUpAtWorkingDistance() {
        let a = matrix_identity_float4x4
        let b = SyntheticScene.transform(yaw: 0.1 * .pi / 180)  // a tenth of a degree

        let atOrigin = a.maximumDisplacement(from: b, atRadius: 0)
        let atTenMetres = a.maximumDisplacement(from: b, atRadius: 10)

        XCTAssertLessThan(atOrigin, 1e-5)
        XCTAssertEqual(atTenMetres, 10 * 0.1 * .pi / 180, accuracy: 1e-3)
        XCTAssertGreaterThan(atTenMetres, 0.015,
                             "A drift this size has to clear the silent-correction threshold")
    }

    func testIdenticalTransformsShowNoDrift() {
        let t = SyntheticScene.transform(yaw: 0.4, pitch: 0.2, translation: SIMD3(1, 2, 3))
        XCTAssertEqual(t.maximumDisplacement(from: t, atRadius: 10), 0, accuracy: 1e-5)
    }

    func testDisplacementIsSymmetric() {
        let a = SyntheticScene.transform(yaw: 0.2, translation: SIMD3(1, 0, 0))
        let b = SyntheticScene.transform(yaw: 0.25, translation: SIMD3(1.02, 0, 0))
        XCTAssertEqual(a.maximumDisplacement(from: b, atRadius: 8),
                       b.maximumDisplacement(from: a, atRadius: 8), accuracy: 1e-5)
    }
}

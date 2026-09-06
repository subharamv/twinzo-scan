import XCTest
import simd
@testable import TwinzoCore

/// Tests for the shim itself.
///
/// This matters more than it looks. Every other test in this suite is only as
/// trustworthy as the maths underneath it — a transposed matrix product or a
/// wrong quaternion convention here would make the ICP tests validate the wrong
/// thing while still passing. So the shim is checked against properties that
/// hold independently of any convention choice.
final class MathShimTests: XCTestCase {

    func testInverseUndoesARigidTransform() {
        let t = SyntheticScene.transform(
            yaw: 0.7, pitch: 0.3, translation: SIMD3(1.5, -2.0, 3.25))
        let identity = t * t.inverse

        for row in 0..<4 {
            for col in 0..<4 {
                let expected: Float = row == col ? 1 : 0
                XCTAssertEqual(element(identity, row, col), expected, accuracy: 1e-4)
            }
        }
    }

    func testTransformPointRoundTrips() {
        let t = SyntheticScene.transform(
            yaw: -1.1, pitch: 0.4, translation: SIMD3(-3, 2, 7))
        let p = SIMD3<Float>(1.25, -0.5, 4.0)
        let back = t.inverse.transformPoint(t.transformPoint(p))

        XCTAssertEqual(back.x, p.x, accuracy: 1e-4)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-4)
        XCTAssertEqual(back.z, p.z, accuracy: 1e-4)
    }

    func testRotationPreservesLength() {
        // Any correct rotation is an isometry, whatever the storage convention.
        let r = SyntheticScene.transform(yaw: 2.1, pitch: -0.8)
        let v = SIMD3<Float>(3, -4, 12)   // length 13
        XCTAssertEqual(length(r.transformDirection(v)), 13, accuracy: 1e-3)
    }

    func testMatrixProductIsNotTransposed() {
        // Applying A then B must equal (B * A) applied once. A transposed
        // product would still pass the round-trip tests above but would silently
        // reverse composition order everywhere in ICP.
        let a = SyntheticScene.transform(yaw: 0.5, translation: SIMD3(1, 0, 0))
        let b = SyntheticScene.transform(yaw: 0.0, translation: SIMD3(0, 0, 2))
        let p = SIMD3<Float>(1, 1, 1)

        let sequential = b.transformPoint(a.transformPoint(p))
        let combined = (b * a).transformPoint(p)

        XCTAssertEqual(sequential.x, combined.x, accuracy: 1e-5)
        XCTAssertEqual(sequential.y, combined.y, accuracy: 1e-5)
        XCTAssertEqual(sequential.z, combined.z, accuracy: 1e-5)
    }

    func testQuaternionMatchesExpectedRotationDirection() {
        // Right-handed, counter-clockwise looking down the axis toward the
        // origin. A quarter turn about +Y takes +X to -Z.
        let q = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let m = simd_float3x3(q)
        let rotated = m * SIMD3<Float>(1, 0, 0)

        XCTAssertEqual(rotated.x, 0, accuracy: 1e-5)
        XCTAssertEqual(rotated.y, 0, accuracy: 1e-5)
        XCTAssertEqual(rotated.z, -1, accuracy: 1e-5)
    }

    func testExponentialTwistIsOrthonormal() {
        // The ICP increment. If it drifts from orthonormal, error accumulates
        // silently over the tens of increments a full run applies.
        let twist = float4x4(
            exponentialTwist: SIMD3(0.02, -0.05, 0.03),
            translation: SIMD3(0.1, 0.2, -0.05)
        )
        var accumulated = matrix_identity_float4x4
        for _ in 0..<50 { accumulated = twist * accumulated }

        // Length preservation is the practical test of orthonormality.
        let v = SIMD3<Float>(1, 2, 2)   // length 3
        XCTAssertEqual(length(accumulated.transformDirection(v)), 3, accuracy: 1e-2)
    }

    func testCrossProductHandedness() {
        let x = SIMD3<Float>(1, 0, 0)
        let y = SIMD3<Float>(0, 1, 0)
        let z = cross(x, y)
        XCTAssertEqual(z.z, 1, accuracy: 1e-6, "Cross product is left-handed")
    }

    func testElementwiseMinMax() {
        let a = SIMD3<Float>(1, 5, -2)
        let b = SIMD3<Float>(3, 2, 0)
        let lo = min(a, b)
        let hi = max(a, b)
        XCTAssertEqual(lo, SIMD3(1, 2, -2))
        XCTAssertEqual(hi, SIMD3(3, 5, 0))
    }

    private func element(_ m: float4x4, _ row: Int, _ col: Int) -> Float {
        let columns = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        return columns[col][row]
    }
}

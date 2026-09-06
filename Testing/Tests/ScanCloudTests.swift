import XCTest
import simd
@testable import TwinzoCore

/// The scan cloud is what ICP actually sees. Its job is to cap the point count
/// and equalise density; if it does neither, registration quality degrades in
/// ways that look like an ICP bug.
final class ScanCloudTests: XCTestCase {

    func testPointsInTheSameVoxelCollapse() {
        let cloud = ScanCloud(voxelSize: 0.10)
        // Five points inside a single 10 cm cell.
        let points: [SIMD3<Float>] = [
            SIMD3(0.01, 0.01, 0.01),
            SIMD3(0.02, 0.03, 0.04),
            SIMD3(0.05, 0.05, 0.05),
            SIMD3(0.09, 0.02, 0.07),
            SIMD3(0.03, 0.08, 0.02),
        ]
        cloud.insert(points: points, transform: matrix_identity_float4x4)
        XCTAssertEqual(cloud.count, 1)
    }

    func testPointsInAdjacentVoxelsAreKept() {
        let cloud = ScanCloud(voxelSize: 0.10)
        cloud.insert(points: [SIMD3(0.05, 0, 0), SIMD3(0.15, 0, 0), SIMD3(0.25, 0, 0)],
                     transform: matrix_identity_float4x4)
        XCTAssertEqual(cloud.count, 3)
    }

    func testNegativeCoordinatesBinCorrectly() {
        // Rounding toward zero rather than down would merge the cells either
        // side of the origin — and ARKit's world origin sits wherever the
        // session started, so negative coordinates are the common case.
        let cloud = ScanCloud(voxelSize: 0.10)
        cloud.insert(points: [SIMD3(-0.05, 0, 0), SIMD3(0.05, 0, 0)],
                     transform: matrix_identity_float4x4)
        XCTAssertEqual(cloud.count, 2, "Cells either side of the origin were merged")
    }

    func testReinsertingTheSameSurfaceDoesNotGrowTheCloud() {
        // ARKit re-emits refined versions of the same chunk continuously. If
        // each re-emission added points, a stationary operator would exhaust the
        // cap in seconds.
        let cloud = ScanCloud(voxelSize: 0.05)
        var random = SyntheticScene.Random(seed: 21)
        let points = SyntheticScene.samplePoints(
            on: SyntheticScene.room(), count: 2000, random: &random)

        cloud.insert(points: points, transform: matrix_identity_float4x4)
        let afterFirst = cloud.count
        for _ in 0..<5 {
            cloud.insert(points: points, transform: matrix_identity_float4x4)
        }
        XCTAssertEqual(cloud.count, afterFirst)
    }

    func testTransformIsApplied() {
        let cloud = ScanCloud(voxelSize: 0.05)
        var shifted = matrix_identity_float4x4
        shifted.columns.3 = SIMD4(10, 0, 0, 1)

        cloud.insert(points: [SIMD3(0, 0, 0)], transform: shifted)
        guard let p = cloud.points().first else { return XCTFail("No point stored") }
        XCTAssertEqual(p.x, 10, accuracy: 1e-5)
    }

    func testEvictionBoundsTheWorkingSet() {
        let cap = 500
        let cloud = ScanCloud(voxelSize: 0.01, maximumPoints: cap)
        var random = SyntheticScene.Random(seed: 33)

        // Insert well past the cap in batches, as a long walkthrough would.
        for _ in 0..<10 {
            let batch = (0..<400).map { _ in
                SIMD3<Float>(random.range(-20, 20),
                             random.range(-20, 20),
                             random.range(-20, 20))
            }
            cloud.insert(points: batch, transform: matrix_identity_float4x4)
        }
        XCTAssertLessThanOrEqual(cloud.count, cap,
                                 "Cloud grew past its cap to \(cloud.count)")
        XCTAssertGreaterThan(cloud.count, 0)
    }

    func testRemoveAllClears() {
        let cloud = ScanCloud(voxelSize: 0.05)
        cloud.insert(points: [SIMD3(1, 2, 3)], transform: matrix_identity_float4x4)
        cloud.removeAll()
        XCTAssertEqual(cloud.count, 0)
        XCTAssertTrue(cloud.points().isEmpty)
    }

    /// A downsampled cloud must still register correctly — this is the actual
    /// contract between ScanCloud and ICP, and neither test alone would catch a
    /// voxel size that quietly destroyed too much geometry.
    func testDownsampledCloudStillRegisters() {
        let room = SyntheticScene.room()
        let mesh = BVH(triangles: room)
        let truth = SyntheticScene.transform(yaw: 0.25, translation: SIMD3(1.2, 0.1, -0.8))

        var random = SyntheticScene.Random(seed: 55)
        let dense = SyntheticScene.samplePoints(
            on: room, count: 20_000, noiseSigma: 0.004, random: &random)

        let cloud = ScanCloud(voxelSize: 0.05)
        cloud.insert(points: dense, transform: truth)
        XCTAssertLessThan(cloud.count, dense.count, "Downsampling had no effect")

        let guess = SyntheticScene.transform(yaw: 0.30, translation: SIMD3(1.3, 0.15, -0.72))
        let result = PointToPlaneICP.align(
            points: cloud.points(), to: mesh, initial: guess.inverse, parameters: .coarse
        )

        let error = SyntheticScene.maximumDisplacement(
            result.worldToModel, truth.inverse, over: SyntheticScene.probeCorners())
        XCTAssertLessThan(error, 0.020,
                          "Registration from a downsampled cloud was \(error * 1000) mm out")
    }

    // MARK: - Depth confidence

    func testLowConfidencePointsAreRefusedEntry() {
        let cloud = ScanCloud(voxelSize: 0.10)
        let points: [SIMD3<Float>] = (0..<10).map { SIMD3(Float($0) * 0.2, 0, 0) }

        // Score the first half low, the second half high.
        cloud.insert(points: points, transform: matrix_identity_float4x4,
                     minimumConfidence: 1) { world in
            world.x < 0.9 ? 0 : 2
        }
        XCTAssertEqual(cloud.count, 5, "Low-confidence returns were accumulated")
    }

    func testUnscorablePointsAreKept() {
        // A vertex outside the current frame cannot be scored. Dropping those
        // would discard nearly the whole mesh, since anchors far outnumber what
        // is in view at any moment.
        let cloud = ScanCloud(voxelSize: 0.10)
        let points: [SIMD3<Float>] = (0..<6).map { SIMD3(Float($0) * 0.2, 0, 0) }

        cloud.insert(points: points, transform: matrix_identity_float4x4,
                     minimumConfidence: 2) { _ in nil }
        XCTAssertEqual(cloud.count, 6, "Points the sensor could not score were dropped")

        let exported = cloud.pointsWithConfidence()
        XCTAssertEqual(exported.confidences, [UInt8](repeating: ScanCloud.unknownConfidence,
                                                     count: 6))
    }

    func testConfidenceTravelsWithTheExportedPoint() {
        let cloud = ScanCloud(voxelSize: 0.10)
        cloud.insert(points: [SIMD3(0.05, 0, 0)], transform: matrix_identity_float4x4,
                     minimumConfidence: 0) { _ in 1 }
        cloud.insert(points: [SIMD3(0.25, 0, 0)], transform: matrix_identity_float4x4,
                     minimumConfidence: 0) { _ in 2 }

        let exported = cloud.pointsWithConfidence()
        XCTAssertEqual(exported.points.count, 2)
        // Ordered by insertion, so the medium point comes first.
        XCTAssertEqual(exported.confidences, [1, 2])
        XCTAssertEqual(exported.points[0].x, 0.05, accuracy: 1e-6)
    }

    func testARejectedPointDoesNotClaimItsVoxel() {
        // If a low-confidence return were allowed to fill a voxel and only then
        // be discarded, the better reading arriving later would find the cell
        // taken and be dropped by first-point-wins.
        let cloud = ScanCloud(voxelSize: 0.10)
        let cell = SIMD3<Float>(0.05, 0, 0)

        cloud.insert(points: [cell], transform: matrix_identity_float4x4,
                     minimumConfidence: 2) { _ in 0 }
        XCTAssertEqual(cloud.count, 0)

        cloud.insert(points: [cell], transform: matrix_identity_float4x4,
                     minimumConfidence: 2) { _ in 2 }
        XCTAssertEqual(cloud.count, 1, "The high-confidence reading was locked out")
        XCTAssertEqual(cloud.pointsWithConfidence().confidences, [2])
    }
}

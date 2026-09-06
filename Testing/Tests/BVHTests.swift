import XCTest
import simd
@testable import TwinzoCore

/// The BVH is the shared foundation: ICP correspondences and the GPU deviation
/// field both come from it. If it returns the wrong nearest surface, every
/// number the app displays is wrong in a way that still looks plausible — so
/// these tests check it against exhaustive search rather than against itself.
final class BVHTests: XCTestCase {

    // MARK: - Closest point on triangle

    func testClosestPointInFaceRegion() {
        let tri = GPUTriangle(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        // Directly above the interior: the closest point is the projection.
        let p = BVH.closestPointOnTriangle(SIMD3(0.25, 0.25, 1), tri)
        assertClose(p, SIMD3(0.25, 0.25, 0))
    }

    func testClosestPointInVertexRegion() {
        let tri = GPUTriangle(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        // Beyond vertex A along both edge normals.
        let p = BVH.closestPointOnTriangle(SIMD3(-1, -1, 0), tri)
        assertClose(p, SIMD3(0, 0, 0))
    }

    func testClosestPointInEdgeRegion() {
        let tri = GPUTriangle(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        // Off the middle of edge AB, outside the triangle.
        let p = BVH.closestPointOnTriangle(SIMD3(0.5, -1, 0), tri)
        assertClose(p, SIMD3(0.5, 0, 0))
    }

    func testClosestPointOnDegenerateTriangleDoesNotProduceNaN() {
        // Zero-area triangles reach this code from real BIM exports, where
        // collapsed faces are common. It must degrade, not produce NaN.
        let tri = GPUTriangle(SIMD3(1, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, 1))
        let p = BVH.closestPointOnTriangle(SIMD3(5, 5, 5), tri)
        XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite,
                      "Degenerate triangle produced a non-finite closest point")
    }

    // MARK: - Tree correctness

    func testMatchesBruteForceSearch() {
        let triangles = SyntheticScene.room()
        let bvh = BVH(triangles: triangles)
        var random = SyntheticScene.Random(seed: 12345)

        var checked = 0
        for _ in 0..<400 {
            let query = SIMD3<Float>(random.range(-6, 6),
                                     random.range(-3, 3),
                                     random.range(-5, 5))

            let expected = bruteForceClosest(to: query, in: bvh.triangles)
            guard let actual = bvh.closestPoint(to: query) else {
                XCTFail("BVH found nothing for a query the brute force resolved")
                continue
            }
            checked += 1

            // Compare distances, not points: on an edge shared by two triangles
            // both answers are equally correct and the tie-break is arbitrary.
            XCTAssertEqual(actual.distance, expected, accuracy: 1e-3,
                           "BVH disagreed with exhaustive search at \(query)")
        }
        XCTAssertEqual(checked, 400)
    }

    func testRespectsMaximumDistance() {
        let bvh = BVH(triangles: SyntheticScene.room())
        // The room centre is 1.5 m from the nearest surface (floor/ceiling).
        let centre = SIMD3<Float>(0, 0, 0)

        XCTAssertNil(bvh.closestPoint(to: centre, maxDistance: 1.0),
                     "Query inside the cull radius should have been rejected")
        XCTAssertNotNil(bvh.closestPoint(to: centre, maxDistance: 2.0))
    }

    func testEmptyMesh() {
        let bvh = BVH(triangles: [])
        XCTAssertTrue(bvh.isEmpty)
        XCTAssertNil(bvh.closestPoint(to: .zero))
    }

    func testAllTrianglesSurviveConstruction() {
        // Subdivision partitions the triangle array in place. An off-by-one in
        // the partition would silently drop geometry, and the deviation field
        // would then report holes in the model as clutter.
        let input = SyntheticScene.room()
        let bvh = BVH(triangles: input)
        XCTAssertEqual(bvh.triangles.count, input.count)
        XCTAssertEqual(bvh.normals.count, input.count)

        let inputCentroids = Set(input.map(centroidKey))
        let outputCentroids = Set(bvh.triangles.map(centroidKey))
        XCTAssertEqual(inputCentroids, outputCentroids,
                       "Triangles were lost or duplicated during subdivision")
    }

    func testLeafRangesCoverEveryTriangleExactlyOnce() {
        let bvh = BVH(triangles: SyntheticScene.room())
        var covered = [Int](repeating: 0, count: bvh.triangles.count)

        for node in bvh.nodes where node.isLeaf {
            let first = Int(node.leftFirst)
            for i in first..<(first + Int(node.triCount)) {
                covered[i] += 1
            }
        }
        XCTAssertFalse(covered.contains(0), "Some triangles are in no leaf")
        XCTAssertFalse(covered.contains(where: { $0 > 1 }), "Some triangles are in two leaves")
    }

    func testNodeBoundsContainTheirTriangles() {
        let bvh = BVH(triangles: SyntheticScene.room())
        for node in bvh.nodes where node.isLeaf {
            let first = Int(node.leftFirst)
            for i in first..<(first + Int(node.triCount)) {
                let tri = bvh.triangles[i]
                for vertex in [tri.a, tri.b, tri.c] {
                    XCTAssertTrue(
                        contains(bounds: node, vertex),
                        "Vertex \(vertex) escaped its node bounds"
                    )
                }
            }
        }
    }

    func testRootBoundsMatchTheRoom() {
        let bvh = BVH(triangles: SyntheticScene.room(width: 8, height: 3, depth: 6))
        assertClose(bvh.bounds.min, SIMD3(-4, -1.5, -3), accuracy: 1e-4)
        assertClose(bvh.bounds.max, SIMD3(4, 1.5, 3), accuracy: 1e-4)
    }

    // MARK: - Helpers

    private func bruteForceClosest(to query: SIMD3<Float>, in triangles: [GPUTriangle]) -> Float {
        var best = Float.greatestFiniteMagnitude
        for tri in triangles {
            let p = BVH.closestPointOnTriangle(query, tri)
            best = Swift.min(best, distance(p, query))
        }
        return best
    }

    private func centroidKey(_ tri: GPUTriangle) -> String {
        let c = tri.centroid
        return String(format: "%.5f/%.5f/%.5f", c.x, c.y, c.z)
    }

    /// Component-wise containment with a tolerance for float rounding in the
    /// bounds refit.
    private func contains(bounds node: GPUBVHNode, _ v: SIMD3<Float>) -> Bool {
        let epsilon: Float = 1e-4
        let lo = node.boundsMin, hi = node.boundsMax
        return v.x >= lo.x - epsilon && v.x <= hi.x + epsilon
            && v.y >= lo.y - epsilon && v.y <= hi.y + epsilon
            && v.z >= lo.z - epsilon && v.z <= hi.z + epsilon
    }

    private func assertClose(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>,
        accuracy: Float = 1e-5, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }
}

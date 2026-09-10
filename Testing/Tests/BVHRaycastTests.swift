import XCTest
import simd
@testable import TwinzoCore

/// Tapping a surface to find out what it is underpins target picking, element
/// identification and measurement snapping. All three are wrong in the same way
/// if the raycast returns the second surface along instead of the first, and
/// that failure is invisible on screen — the operator gets an element, just not
/// the one they pointed at.
final class BVHRaycastTests: XCTestCase {

    /// A room, with each of the six faces tagged as its own element. The face
    /// order matches SyntheticScene.room: floor, ceiling, -Z, +Z, -X, +X.
    private func room(divisions: Int = 6) -> BVH {
        let plain = SyntheticScene.room(divisions: divisions)
        let perFace = plain.count / 6
        return BVH(triangles: plain.enumerated().map { index, tri in
            GPUTriangle(tri.a, tri.b, tri.c, element: UInt32(min(5, index / perFace)))
        })
    }

    private enum Face {
        static let floor: UInt32 = 0
        static let ceiling: UInt32 = 1
        static let minusZ: UInt32 = 2
        static let plusZ: UInt32 = 3
        static let minusX: UInt32 = 4
        static let plusX: UInt32 = 5
    }

    func testHitsTheFloorBelowTheOrigin() throws {
        let mesh = room()
        let hit = try XCTUnwrap(
            mesh.raycast(origin: SIMD3(0, 1, 0), direction: SIMD3(0, -1, 0)))

        XCTAssertEqual(hit.point.y, -1.5, accuracy: 1e-3)
        XCTAssertEqual(hit.distance, 2.5, accuracy: 1e-3)
        XCTAssertEqual(hit.elementIndex, Face.floor)
    }

    /// The property everything else rests on. A ray down the length of the room
    /// passes through the far wall too; returning that one would attribute a
    /// finding to the element behind the one the operator touched.
    func testReturnsTheNearestSurfaceNotJustAnyOne() throws {
        let mesh = room()
        // From outside the -X wall, aimed across the whole room.
        let hit = try XCTUnwrap(
            mesh.raycast(origin: SIMD3(-10, 0, 0), direction: SIMD3(1, 0, 0)))

        XCTAssertEqual(hit.elementIndex, Face.minusX)
        XCTAssertEqual(hit.point.x, -4, accuracy: 1e-3)
        XCTAssertEqual(hit.distance, 6, accuracy: 1e-3)
    }

    /// Cast from inside, the same ray must find the far wall — proving the near
    /// wall is skipped because it is behind the origin, not because of a cull.
    func testHitsFromInsideTheRoom() throws {
        let mesh = room()
        let hit = try XCTUnwrap(
            mesh.raycast(origin: .zero, direction: SIMD3(1, 0, 0)))
        XCTAssertEqual(hit.elementIndex, Face.plusX)
        XCTAssertEqual(hit.point.x, 4, accuracy: 1e-3)
    }

    /// BIM exports are inconsistent about winding. A back-face cull would make
    /// tapping a wall work from one side of the building and do nothing from the
    /// other, which reads as a broken app rather than a modelling problem.
    func testSurfacesAreHitFromBothSides() throws {
        let mesh = room()
        let outside = try XCTUnwrap(
            mesh.raycast(origin: SIMD3(0, 0, -10), direction: SIMD3(0, 0, 1)))
        let inside = try XCTUnwrap(
            mesh.raycast(origin: SIMD3(0, 0, -1), direction: SIMD3(0, 0, -1)))

        XCTAssertEqual(outside.elementIndex, Face.minusZ)
        XCTAssertEqual(inside.elementIndex, Face.minusZ)
        XCTAssertEqual(outside.point.z, inside.point.z, accuracy: 1e-3)
    }

    func testMissReturnsNothing() {
        let mesh = room()
        // Parallel to the floor, well above the ceiling.
        XCTAssertNil(mesh.raycast(origin: SIMD3(0, 50, 0), direction: SIMD3(1, 0, 0)))
        // Pointing away from the building entirely.
        XCTAssertNil(mesh.raycast(origin: SIMD3(0, 0, -10), direction: SIMD3(0, 0, -1)))
    }

    func testMaxDistanceIsRespected() {
        let mesh = room()
        // The floor is 2.5 m below; a 1 m reach must not find it.
        XCTAssertNil(mesh.raycast(origin: SIMD3(0, 1, 0), direction: SIMD3(0, -1, 0),
                                  maxDistance: 1.0))
        XCTAssertNotNil(mesh.raycast(origin: SIMD3(0, 1, 0), direction: SIMD3(0, -1, 0),
                                     maxDistance: 3.0))
    }

    func testDirectionNeedNotBeNormalised() throws {
        let mesh = room()
        let unit = try XCTUnwrap(
            mesh.raycast(origin: SIMD3(0, 1, 0), direction: SIMD3(0, -1, 0)))
        let scaled = try XCTUnwrap(
            mesh.raycast(origin: SIMD3(0, 1, 0), direction: SIMD3(0, -37, 0)))

        XCTAssertEqual(unit.distance, scaled.distance, accuracy: 1e-3,
                       "Distance is in scene units, not multiples of the direction vector")
        XCTAssertEqual(unit.point, scaled.point)
    }

    func testZeroDirectionIsRejected() {
        XCTAssertNil(room().raycast(origin: .zero, direction: .zero))
    }

    func testEmptyMeshIsHandled() {
        XCTAssertNil(BVH(triangles: []).raycast(origin: .zero, direction: SIMD3(0, 0, 1)))
    }

    func testNormalIsUnitLength() throws {
        let mesh = room()
        let hit = try XCTUnwrap(
            mesh.raycast(origin: SIMD3(0, 1, 0), direction: SIMD3(0, -1, 0)))
        XCTAssertEqual(length(hit.normal), 1, accuracy: 1e-4)
    }

    /// The accelerated descent has to agree with brute force on every ray, not
    /// just the easy axis-aligned ones. A traversal bug that only shows up on
    /// oblique rays is exactly the kind that survives hand-checking.
    func testAcceleratedTraversalMatchesBruteForce() {
        let mesh = room(divisions: 5)
        var random = SyntheticScene.Random(seed: 97)

        for _ in 0..<300 {
            let origin = SIMD3<Float>(random.range(-3, 3),
                                      random.range(-1, 1),
                                      random.range(-2, 2))
            let direction = normalize(SIMD3<Float>(random.range(-1, 1),
                                                   random.range(-1, 1),
                                                   random.range(-1, 1)))
            guard length(direction) > 0.1 else { continue }

            let accelerated = mesh.raycast(origin: origin, direction: direction)

            // Brute force over every triangle, taking the nearest.
            var expected: Float = .greatestFiniteMagnitude
            for tri in mesh.triangles {
                guard let d = Self.mollerTrumbore(origin, direction, tri) else { continue }
                expected = Swift.min(expected, d)
            }

            if expected == .greatestFiniteMagnitude {
                XCTAssertNil(accelerated)
            } else {
                XCTAssertEqual(accelerated?.distance ?? -1, expected, accuracy: 1e-3)
            }
        }
    }

    /// An independent reimplementation, kept in the test so the comparison above
    /// is against something other than the code under test.
    private static func mollerTrumbore(
        _ origin: SIMD3<Float>, _ direction: SIMD3<Float>, _ tri: GPUTriangle
    ) -> Float? {
        let e1 = tri.b - tri.a
        let e2 = tri.c - tri.a
        let h = cross(direction, e2)
        let det = dot(e1, h)
        guard abs(det) > 1e-9 else { return nil }
        let inv = 1 / det
        let s = origin - tri.a
        let u = dot(s, h) * inv
        guard u >= -1e-6, u <= 1 + 1e-6 else { return nil }
        let q = cross(s, e1)
        let v = dot(direction, q) * inv
        guard v >= -1e-6, u + v <= 1 + 1e-6 else { return nil }
        let t = dot(e2, q) * inv
        return t > 1e-5 ? t : nil
    }
}

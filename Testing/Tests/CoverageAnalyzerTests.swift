import XCTest
import simd
@testable import TwinzoCore

/// Coverage is the answer to "what did nobody look at". It is the one number in
/// this app whose absence would be actively dangerous — a deviation pass alone
/// reports an unscanned wall as flawless — so these tests are mostly about the
/// analyser refusing to overstate what the scan reached.
final class CoverageAnalyzerTests: XCTestCase {

    /// A room whose six faces are six separately addressable elements, so
    /// coverage can be checked per element rather than only in aggregate.
    private func roomWithFaceElements(divisions: Int = 6) -> BVH {
        let plain = SyntheticScene.room(divisions: divisions)
        // SyntheticScene emits the faces in order, an equal number of triangles
        // each, so the face index is recoverable from position in the array.
        let perFace = plain.count / 6
        let tagged = plain.enumerated().map { index, tri in
            GPUTriangle(tri.a, tri.b, tri.c,
                        element: UInt32(min(5, index / perFace)))
        }
        return BVH(triangles: tagged)
    }

    private var parameters: CoverageAnalyzer.Parameters {
        CoverageAnalyzer.Parameters.forVoxelSize(0.05)
    }

    func testAFullyScannedModelReportsFullCoverage() {
        let mesh = roomWithFaceElements()
        var random = SyntheticScene.Random(seed: 11)
        let scan = SyntheticScene.samplePoints(
            on: mesh.triangles, count: 40_000, noiseSigma: 0.004, random: &random)

        let report = CoverageAnalyzer.analyze(
            mesh: mesh, scanPoints: scan,
            worldToModel: matrix_identity_float4x4, parameters: parameters)

        XCTAssertGreaterThan(report.overall, 0.98)
        XCTAssertGreaterThan(report.totalArea, 0)
    }

    func testAnEmptyScanCoversNothing() {
        let mesh = roomWithFaceElements()
        let report = CoverageAnalyzer.analyze(
            mesh: mesh, scanPoints: [],
            worldToModel: matrix_identity_float4x4, parameters: parameters)

        XCTAssertEqual(report.overall, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(report.totalArea, 0, "The denominator is the design surface, "
                           + "which exists whether or not anyone scanned it")
    }

    /// The case the whole feature exists for: five walls walked, one skipped.
    /// The deviation pass sees nothing wrong with the sixth because it has no
    /// data about it at all.
    func testASkippedWallIsIsolatedToItsOwnElement() {
        let mesh = roomWithFaceElements()
        let skipped: UInt32 = 5
        let scannedTriangles = mesh.triangles.filter { $0.elementIndex != skipped }

        var random = SyntheticScene.Random(seed: 23)
        let scan = SyntheticScene.samplePoints(
            on: scannedTriangles, count: 40_000, noiseSigma: 0.004, random: &random)

        let report = CoverageAnalyzer.analyze(
            mesh: mesh, scanPoints: scan,
            worldToModel: matrix_identity_float4x4, parameters: parameters)

        XCTAssertLessThan(report.byElement[skipped] ?? 1, 0.15,
                          "The unscanned face must show as unscanned")
        for element in UInt32(0)...4 {
            XCTAssertGreaterThan(report.byElement[element] ?? 0, 0.9,
                                 "Face \(element) was scanned and should read as covered")
        }
        XCTAssertLessThan(report.overall, 0.95)
        XCTAssertGreaterThan(report.overall, 0.7)
    }

    /// Coverage is measured in model space, so a misaligned scan must not be
    /// credited. This also guards the transform being applied at all: dropping
    /// it would make every scan look perfectly placed.
    func testCoverageIsMeasuredAfterAlignment() {
        let mesh = roomWithFaceElements()
        var random = SyntheticScene.Random(seed: 31)
        let scan = SyntheticScene.samplePoints(
            on: mesh.triangles, count: 30_000, noiseSigma: 0.003, random: &random)

        // Same scan, shifted a long way out of the building.
        let displaced = SyntheticScene.transform(translation: SIMD3(50, 0, 0))
        let report = CoverageAnalyzer.analyze(
            mesh: mesh, scanPoints: scan, worldToModel: displaced, parameters: parameters)

        XCTAssertEqual(report.overall, 0, accuracy: 1e-6)
    }

    func testEveryElementAppearsInTheDenominator() {
        let mesh = roomWithFaceElements()
        let report = CoverageAnalyzer.analyze(
            mesh: mesh, scanPoints: [],
            worldToModel: matrix_identity_float4x4, parameters: parameters)

        // All six faces present, each at zero — not simply missing.
        XCTAssertEqual(Set(report.byElement.keys), Set(UInt32(0)...5))
        for value in report.byElement.values {
            XCTAssertEqual(value, 0, accuracy: 1e-6)
        }
    }

    /// Sampling is area-weighted, so a coarsely tessellated face must carry the
    /// same weight as a finely tessellated one of equal area. Otherwise coverage
    /// silently becomes a measure of the exporter's meshing settings.
    func testCoverageIsIndependentOfTessellationDensity() {
        let coarse = roomWithFaceElements(divisions: 2)
        let fine = roomWithFaceElements(divisions: 10)

        var random = SyntheticScene.Random(seed: 47)
        // Scan only the floor (element 0) in both cases.
        let floorOnly = coarse.triangles.filter { $0.elementIndex == 0 }
        let scan = SyntheticScene.samplePoints(
            on: floorOnly, count: 20_000, noiseSigma: 0.003, random: &random)

        let coarseReport = CoverageAnalyzer.analyze(
            mesh: coarse, scanPoints: scan,
            worldToModel: matrix_identity_float4x4, parameters: parameters)
        let fineReport = CoverageAnalyzer.analyze(
            mesh: fine, scanPoints: scan,
            worldToModel: matrix_identity_float4x4, parameters: parameters)

        XCTAssertEqual(coarseReport.overall, fineReport.overall, accuracy: 0.05)
        XCTAssertEqual(coarseReport.totalArea, fineReport.totalArea, accuracy: 0.5)
    }

    // MARK: - The spatial hash underneath

    func testOccupancyGridFindsPointsAcrossCellBoundaries() {
        // Two points either side of a cell boundary at the origin.
        let grid = OccupancyGrid(points: [SIMD3(-0.01, 0, 0)], cellSize: 0.1)
        XCTAssertTrue(grid.hasPoint(near: SIMD3(0.01, 0, 0), within: 0.1))
        XCTAssertFalse(grid.hasPoint(near: SIMD3(0.5, 0, 0), within: 0.1))
    }

    func testOccupancyGridHandlesNegativeCoordinates() {
        let grid = OccupancyGrid(
            points: [SIMD3(-5.02, -3.01, -1.04)], cellSize: 0.1)
        XCTAssertTrue(grid.hasPoint(near: SIMD3(-5.0, -3.0, -1.0), within: 0.1))
        XCTAssertFalse(grid.hasPoint(near: SIMD3(5.0, 3.0, 1.0), within: 0.1))
    }

    /// A zero or negative cell size would divide by zero in the key arithmetic
    /// and hash everything into one bucket, turning every query into a full scan
    /// that still returns the right answer — a performance cliff with no
    /// symptom. The clamp has to hold.
    func testOccupancyGridSurvivesADegenerateCellSize() {
        let grid = OccupancyGrid(points: [SIMD3(1, 2, 3)], cellSize: 0)
        XCTAssertTrue(grid.hasPoint(near: SIMD3(1, 2, 3), within: 0.01))
    }

    func testEmptyGridIsEmpty() {
        let grid = OccupancyGrid(points: [], cellSize: 0.1)
        XCTAssertTrue(grid.isEmpty)
        XCTAssertFalse(grid.hasPoint(near: .zero, within: 1))
    }

    // MARK: - Surface sampling

    func testSurfaceSamplingIsReproducible() {
        let mesh = roomWithFaceElements()
        let first = mesh.sampleSurface(spacing: 0.2)
        let second = mesh.sampleSurface(spacing: 0.2)

        XCTAssertEqual(first.count, second.count)
        XCTAssertFalse(first.isEmpty)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.point, b.point, "A coverage figure that changes between runs "
                         + "cannot be defended when the report is challenged")
        }
    }

    func testSampledAreaMatchesTheMeshArea() {
        let mesh = roomWithFaceElements()
        let sampled = mesh.sampleSurface(spacing: 0.15)
            .reduce(Float(0)) { $0 + $1.area }
        let actual = mesh.triangles.reduce(Float(0)) { $0 + $1.area }
        XCTAssertEqual(sampled, actual, accuracy: actual * 0.01)
    }

    func testEveryTriangleContributesAtLeastOneSample() {
        // Spacing far coarser than the geometry: small elements must still be
        // represented, or they vanish from the coverage denominator entirely.
        let mesh = roomWithFaceElements(divisions: 8)
        let samples = mesh.sampleSurface(spacing: 100)
        XCTAssertEqual(samples.count, mesh.triangles.count)
        XCTAssertEqual(Set(samples.map(\.elementIndex)), Set(UInt32(0)...5))
    }

    func testAreaByElementSumsToTheWholeMesh() {
        let mesh = roomWithFaceElements()
        let byElement = mesh.areaByElement()
        let total = byElement.values.reduce(0, +)
        let actual = mesh.triangles.reduce(Float(0)) { $0 + $1.area }
        XCTAssertEqual(total, actual, accuracy: actual * 1e-3)
        XCTAssertEqual(byElement.count, 6)
    }
}

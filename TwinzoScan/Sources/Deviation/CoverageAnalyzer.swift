import Foundation
import simd

/// How much of the design model the scan actually reached.
struct CoverageReport: Sendable {
    /// Area-weighted covered fraction per element index, 0...1.
    var byElement: [UInt32: Float]
    /// Design surface area reached, square metres.
    var coveredArea: Float
    /// Total design surface area considered, square metres.
    var totalArea: Float
    /// Sample spacing used, metres — the resolution the number is good to.
    var spacing: Float

    var overall: Float { totalArea > 0 ? coveredArea / totalArea : 0 }
}

/// Answers the question the deviation pass structurally cannot: which parts of
/// the model did nobody look at?
///
/// The deviation kernel walks scan vertices and asks what design surface is near
/// them. That direction can only ever report on surfaces that were scanned. A
/// wall the operator never walked past produces no vertices, contributes nothing
/// to the statistics, and therefore reads as flawless — the failure mode that
/// turns an inspection record into a liability.
///
/// This walks the other direction: it samples the *design* surface and asks
/// whether any scan return landed near each sample. Everything with no return is
/// unverified, and says so.
///
/// Free of ARKit and Metal so it can be tested off Apple hardware.
enum CoverageAnalyzer {

    struct Parameters: Sendable {
        /// Spacing of design-surface samples, metres. Finer costs time linearly
        /// in area; 10 cm over a warehouse bay is a few tens of thousands of
        /// samples and about a frame's worth of work on a background queue.
        var spacing: Float = 0.10
        /// A sample counts as covered when a scan point lies within this of it.
        ///
        /// Must exceed the scan cloud's voxel pitch, or a perfectly scanned
        /// surface reports gaps that are really just the grid: the nearest
        /// retained point can legitimately sit most of a voxel diagonal away.
        var searchRadius: Float = 0.12
        /// Cap on design samples, to bound the cost on a whole-building model.
        var sampleLimit: Int = 200_000

        /// Derives coherent parameters from the scan cloud's own resolution,
        /// which is the thing that actually limits what coverage can mean.
        static func forVoxelSize(_ voxelSize: Float) -> Parameters {
            Parameters(
                spacing: max(0.05, voxelSize * 2),
                // Half a voxel diagonal (sqrt(3)/2 ~ 0.87) plus a margin for the
                // surface offset the sample is allowed to sit at.
                searchRadius: voxelSize * 0.87 + 0.05
            )
        }
    }

    /// - Parameters:
    ///   - mesh: the BIM geometry, in model space.
    ///   - scanPoints: accumulated scan cloud, in LiDAR world space.
    ///   - worldToModel: current alignment.
    static func analyze(
        mesh: BVH,
        scanPoints: [SIMD3<Float>],
        worldToModel: float4x4,
        parameters: Parameters = Parameters()
    ) -> CoverageReport {
        let samples = mesh.sampleSurface(spacing: parameters.spacing,
                                         limit: parameters.sampleLimit)
        guard !samples.isEmpty else {
            return CoverageReport(byElement: [:], coveredArea: 0, totalArea: 0,
                                  spacing: parameters.spacing)
        }

        // Bin the scan into a grid at the search radius so each design sample
        // only tests the 27 cells around it. A linear scan over 60k points per
        // sample would be tens of billions of distance tests.
        let occupancy = OccupancyGrid(
            points: scanPoints.map { worldToModel.transformPoint($0) },
            cellSize: parameters.searchRadius
        )

        var coveredByElement: [UInt32: Float] = [:]
        var totalByElement: [UInt32: Float] = [:]
        var coveredArea: Float = 0
        var totalArea: Float = 0

        for sample in samples {
            totalArea += sample.area
            totalByElement[sample.elementIndex, default: 0] += sample.area
            if occupancy.hasPoint(near: sample.point, within: parameters.searchRadius) {
                coveredArea += sample.area
                coveredByElement[sample.elementIndex, default: 0] += sample.area
            }
        }

        var byElement: [UInt32: Float] = [:]
        byElement.reserveCapacity(totalByElement.count)
        for (element, total) in totalByElement where total > 0 {
            byElement[element] = (coveredByElement[element] ?? 0) / total
        }

        return CoverageReport(byElement: byElement, coveredArea: coveredArea,
                              totalArea: totalArea, spacing: parameters.spacing)
    }
}

/// Uniform spatial hash over the scan cloud, for radius queries.
///
/// A hash rather than a k-d tree because the query is "is anything near here",
/// not "what is nearest": no ordering is needed, the cloud is already
/// voxel-uniform, and building this is a single linear pass.
struct OccupancyGrid: Sendable {

    private struct Cell: Hashable {
        var x: Int32, y: Int32, z: Int32
    }

    private let cellSize: Float
    private var cells: [Cell: [SIMD3<Float>]] = [:]

    var isEmpty: Bool { cells.isEmpty }

    init(points: [SIMD3<Float>], cellSize: Float) {
        // A non-positive cell size would make the key arithmetic divide by zero
        // and hash every point into one bucket, quietly turning every query into
        // a full scan.
        self.cellSize = max(cellSize, 1e-4)
        cells.reserveCapacity(points.count / 2 + 1)
        for point in points {
            cells[key(for: point), default: []].append(point)
        }
    }

    private func key(for point: SIMD3<Float>) -> Cell {
        Cell(x: Int32((point.x / cellSize).rounded(.down)),
             y: Int32((point.y / cellSize).rounded(.down)),
             z: Int32((point.z / cellSize).rounded(.down)))
    }

    /// True when any stored point lies within `radius` of `query`.
    ///
    /// Scans the 3x3x3 cell neighbourhood, which is exhaustive for any radius up
    /// to the cell size — the caller builds the grid at the radius it intends to
    /// query, so that holds.
    func hasPoint(near query: SIMD3<Float>, within radius: Float) -> Bool {
        guard !cells.isEmpty else { return false }
        let centre = key(for: query)
        let radiusSquared = radius * radius

        for dx in Int32(-1)...1 {
            for dy in Int32(-1)...1 {
                for dz in Int32(-1)...1 {
                    let cell = Cell(x: centre.x + dx, y: centre.y + dy, z: centre.z + dz)
                    guard let bucket = cells[cell] else { continue }
                    for point in bucket
                    where distance_squared(point, query) <= radiusSquared {
                        return true
                    }
                }
            }
        }
        return false
    }
}

import Foundation
import simd

/// Voxel-downsampled accumulation of everything the LiDAR has seen, in world space.
///
/// ARKit's mesh anchors are a moving target: chunks are added, refined and
/// re-emitted continuously, and the raw vertex count across a warehouse bay runs
/// into the hundreds of thousands. Feeding that straight into ICP is neither
/// affordable nor useful — dense regions near the operator would simply outvote
/// the far geometry that actually constrains rotation.
///
/// A voxel grid fixes both problems at once: it caps the point count, and it
/// makes the sample density uniform, so every part of the scan pulls on the fit
/// with equal weight.
final class ScanCloud {

    /// Grid pitch in metres. 5 cm keeps a warehouse bay in the low tens of
    /// thousands of points, which is a comfortable ICP working set.
    private let voxelSize: Float
    /// Above this, the oldest voxels are evicted. Bounds both memory and the
    /// per-iteration cost of ICP on a long walkthrough.
    private let maximumPoints: Int

    /// Confidence recorded for a point the depth map could not score, because it
    /// was outside the frame when its voxel was first filled.
    static let unknownConfidence: UInt8 = 255

    /// Voxel key -> (representative point, insertion order).
    private var voxels: [VoxelKey: Entry] = [:]
    private var insertionCounter: UInt64 = 0

    private struct VoxelKey: Hashable {
        var x: Int32, y: Int32, z: Int32
    }

    private struct Entry {
        var point: SIMD3<Float>
        var order: UInt64
        /// ARKit depth confidence at the moment this voxel was filled, kept so an
        /// exported cloud can be filtered downstream on the same evidence the app
        /// used. Never re-scored: the point is never replaced either.
        var confidence: UInt8 = ScanCloud.unknownConfidence
    }

    init(voxelSize: Float = 0.05, maximumPoints: Int = 60_000) {
        self.voxelSize = voxelSize
        self.maximumPoints = maximumPoints
    }

    var count: Int { voxels.count }

    func removeAll() {
        voxels.removeAll(keepingCapacity: true)
        insertionCounter = 0
    }

    /// Folds one mesh anchor's vertices into the grid.
    ///
    /// - Parameters:
    ///   - points: vertices in the anchor's local space.
    ///   - transform: that anchor's pose, local -> world.
    ///   - minimumConfidence: points the sensor scored below this are dropped.
    ///     Zero admits everything, which is the behaviour without a sampler.
    ///   - confidence: scores one world-space point, or returns nil when it
    ///     cannot be scored. Taken as a closure rather than a parallel array so
    ///     this type stays free of any Apple dependency and keeps running under
    ///     `swift test` on Windows and Linux.
    func insert(
        points: [SIMD3<Float>],
        transform: float4x4,
        minimumConfidence: UInt8 = 0,
        confidence: ((SIMD3<Float>) -> UInt8?)? = nil
    ) {
        for local in points {
            let world = transform.transformPoint(local)

            // Score before the voxel lookup: an unreliable return should not be
            // able to claim a voxel and lock a better later reading out of it.
            var level = ScanCloud.unknownConfidence
            if let confidence, let scored = confidence(world) {
                guard scored >= minimumConfidence else { continue }
                level = scored
            }

            let key = VoxelKey(
                x: Int32((world.x / voxelSize).rounded(.down)),
                y: Int32((world.y / voxelSize).rounded(.down)),
                z: Int32((world.z / voxelSize).rounded(.down))
            )
            // First point wins rather than averaging: ARKit re-emits refined
            // versions of the same surface constantly, and averaging across
            // successive refinements smears the surface it is meant to sharpen.
            if voxels[key] == nil {
                insertionCounter += 1
                voxels[key] = Entry(point: world, order: insertionCounter, confidence: level)
            }
        }
        evictIfNeeded()
    }

    /// Snapshot for ICP. Returned as a plain array so the caller can hand it to a
    /// background queue without holding a lock on this object.
    func points() -> [SIMD3<Float>] {
        voxels.values.map(\.point)
    }

    /// Snapshot for export, ordered oldest first so a re-imported cloud walks the
    /// space in the order it was scanned rather than in hash order.
    func pointsWithConfidence() -> (points: [SIMD3<Float>], confidences: [UInt8]) {
        let ordered = voxels.values.sorted { $0.order < $1.order }
        return (ordered.map(\.point), ordered.map(\.confidence))
    }

    private func evictIfNeeded() {
        guard voxels.count > maximumPoints else { return }
        // Drop the oldest quarter rather than trimming to exactly the cap, so
        // eviction runs rarely instead of on almost every insert.
        let target = voxels.count - (maximumPoints * 3 / 4)
        let doomed = voxels
            .sorted { $0.value.order < $1.value.order }
            .prefix(target)
            .map(\.key)
        for key in doomed { voxels.removeValue(forKey: key) }
    }
}

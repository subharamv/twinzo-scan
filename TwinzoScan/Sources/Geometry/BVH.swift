import Foundation
import simd

/// Result of a closest-point query against the BIM mesh.
struct SurfaceHit {
    /// Closest point on the mesh, in model space.
    var point: SIMD3<Float>
    /// Unit normal of the triangle that owns `point`.
    var normal: SIMD3<Float>
    /// Euclidean distance from the query point.
    var distance: Float
    var triangleIndex: Int
}

/// Binned-SAH bounding volume hierarchy over the BIM triangle soup.
///
/// Built once when a model is loaded, then used for two things:
///   * CPU: nearest-surface correspondences for point-to-plane ICP.
///   * GPU: the flattened `nodes`/`triangles` arrays upload verbatim to Metal so
///     the per-frame deviation kernel traverses the exact same tree.
///
/// Both consumers work in *model space*; query points are transformed into it
/// rather than the tree being rebuilt whenever the alignment changes.
final class BVH {
    private(set) var nodes: [GPUBVHNode] = []
    /// Triangles reordered to match leaf ranges. This is the array the GPU sees.
    private(set) var triangles: [GPUTriangle] = []
    /// Unit face normals, parallel to `triangles`.
    private(set) var normals: [SIMD3<Float>] = []

    private static let maxLeafSize = 4
    private static let binCount = 12

    var isEmpty: Bool { triangles.isEmpty }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let root = nodes.first else { return (.zero, .zero) }
        return (root.boundsMin, root.boundsMax)
    }

    init(triangles input: [GPUTriangle]) {
        guard !input.isEmpty else { return }
        triangles = input
        normals = input.map { tri in
            let n = tri.faceNormal
            let len = length(n)
            return len > 1e-12 ? n / len : SIMD3<Float>(0, 1, 0)
        }
        build()
    }

    // MARK: - Construction

    private func build() {
        let count = triangles.count
        nodes = Array(
            repeating: GPUBVHNode(boundsMin: .zero, boundsMax: .zero, leftFirst: 0, triCount: 0),
            count: max(2, 2 * count)
        )
        var centroids = triangles.map { $0.centroid }
        var nodeCount = 1

        nodes[0].leftFirst = 0
        nodes[0].triCount = UInt32(count)
        updateBounds(of: 0)

        subdivide(node: 0, centroids: &centroids, nodeCount: &nodeCount)
        nodes.removeSubrange(nodeCount...)
    }

    private func updateBounds(of index: Int) {
        let first = Int(nodes[index].leftFirst)
        let count = Int(nodes[index].triCount)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in first..<(first + count) {
            let t = triangles[i]
            lo = min(lo, min(t.a, min(t.b, t.c)))
            hi = max(hi, max(t.a, max(t.b, t.c)))
        }
        nodes[index] = GPUBVHNode(
            boundsMin: lo, boundsMax: hi,
            leftFirst: UInt32(first), triCount: UInt32(count)
        )
    }

    private func subdivide(node index: Int, centroids: inout [SIMD3<Float>], nodeCount: inout Int) {
        let first = Int(nodes[index].leftFirst)
        let count = Int(nodes[index].triCount)
        guard count > Self.maxLeafSize else { return }
        guard let split = bestSplit(node: index, first: first, count: count, centroids: centroids)
        else { return }

        // In-place partition of the triangle array and everything parallel to it.
        var i = first
        var j = first + count - 1
        while i <= j {
            if centroids[i][split.axis] < split.position {
                i += 1
            } else {
                triangles.swapAt(i, j)
                normals.swapAt(i, j)
                centroids.swapAt(i, j)
                j -= 1
            }
        }

        let leftCount = i - first
        // A degenerate split (everything landing on one side) would recurse forever.
        guard leftCount > 0, leftCount < count else { return }

        let leftIndex = nodeCount
        nodeCount += 2

        nodes[leftIndex].leftFirst = UInt32(first)
        nodes[leftIndex].triCount = UInt32(leftCount)
        updateBounds(of: leftIndex)

        nodes[leftIndex + 1].leftFirst = UInt32(i)
        nodes[leftIndex + 1].triCount = UInt32(count - leftCount)
        updateBounds(of: leftIndex + 1)

        // This node becomes interior: it points at children and owns no triangles.
        nodes[index].leftFirst = UInt32(leftIndex)
        nodes[index].triCount = 0

        subdivide(node: leftIndex, centroids: &centroids, nodeCount: &nodeCount)
        subdivide(node: leftIndex + 1, centroids: &centroids, nodeCount: &nodeCount)
    }

    /// Binned surface-area-heuristic split search over all three axes.
    /// Returns nil when no candidate split beats keeping the node as a leaf.
    private func bestSplit(
        node index: Int, first: Int, count: Int, centroids: [SIMD3<Float>]
    ) -> (axis: Int, position: Float)? {
        // Cost of leaving this node as a leaf, in the same units as the split
        // costs below: triangle count weighted by surface area.
        let parentArea = halfArea(lo: nodes[index].boundsMin, hi: nodes[index].boundsMax)
        var bestCost = Float(count) * max(parentArea, 1e-6)
        var best: (axis: Int, position: Float)?

        for axis in 0..<3 {
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            for i in first..<(first + count) {
                lo = Swift.min(lo, centroids[i][axis])
                hi = Swift.max(hi, centroids[i][axis])
            }
            guard hi - lo > 1e-6 else { continue }

            let emptyBin = (
                lo: SIMD3<Float>(repeating: .greatestFiniteMagnitude),
                hi: SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            )
            var binBounds = Array(repeating: emptyBin, count: Self.binCount)
            var binCounts = Array(repeating: 0, count: Self.binCount)
            let scale = Float(Self.binCount) / (hi - lo)

            for i in first..<(first + count) {
                let bin = Swift.min(Self.binCount - 1, Int((centroids[i][axis] - lo) * scale))
                let t = triangles[i]
                binCounts[bin] += 1
                binBounds[bin].lo = min(binBounds[bin].lo, min(t.a, min(t.b, t.c)))
                binBounds[bin].hi = max(binBounds[bin].hi, max(t.a, max(t.b, t.c)))
            }

            // Sweep from both ends so prefix/suffix areas cost one pass each.
            let planes = Self.binCount - 1
            var leftArea = [Float](repeating: 0, count: planes)
            var rightArea = [Float](repeating: 0, count: planes)
            var leftCounts = [Int](repeating: 0, count: planes)
            var rightCounts = [Int](repeating: 0, count: planes)

            var accLo = emptyBin.lo
            var accHi = emptyBin.hi
            var accCount = 0
            for b in 0..<planes {
                accCount += binCounts[b]
                accLo = min(accLo, binBounds[b].lo)
                accHi = max(accHi, binBounds[b].hi)
                leftCounts[b] = accCount
                leftArea[b] = halfArea(lo: accLo, hi: accHi)
            }
            accLo = emptyBin.lo
            accHi = emptyBin.hi
            accCount = 0
            for b in stride(from: Self.binCount - 1, through: 1, by: -1) {
                accCount += binCounts[b]
                accLo = min(accLo, binBounds[b].lo)
                accHi = max(accHi, binBounds[b].hi)
                rightCounts[b - 1] = accCount
                rightArea[b - 1] = halfArea(lo: accLo, hi: accHi)
            }

            let binWidth = (hi - lo) / Float(Self.binCount)
            for b in 0..<planes {
                guard leftCounts[b] > 0, rightCounts[b] > 0 else { continue }
                let cost = Float(leftCounts[b]) * leftArea[b] + Float(rightCounts[b]) * rightArea[b]
                if cost < bestCost {
                    bestCost = cost
                    best = (axis, lo + binWidth * Float(b + 1))
                }
            }
        }
        return best
    }

    private func halfArea(lo: SIMD3<Float>, hi: SIMD3<Float>) -> Float {
        let e = max(hi - lo, SIMD3<Float>.zero)
        return e.x * e.y + e.y * e.z + e.z * e.x
    }

    // MARK: - Queries

    /// Closest point on the mesh to `query` (model space), or nil if nothing lies
    /// within `maxDistance`. A nearest-child-first descent with an aggressively
    /// shrinking radius is what keeps ICP affordable on the CPU.
    func closestPoint(
        to query: SIMD3<Float>, maxDistance: Float = .greatestFiniteMagnitude
    ) -> SurfaceHit? {
        guard !nodes.isEmpty else { return nil }

        var bestDistSq = maxDistance * maxDistance
        var hit: SurfaceHit?

        // Explicit stack: recursion shows up badly in the ICP profile.
        var stack = [Int](repeating: 0, count: 64)
        var stackTop = 0
        stack[stackTop] = 0
        stackTop += 1

        while stackTop > 0 {
            stackTop -= 1
            let node = nodes[stack[stackTop]]

            if boxDistanceSquared(query, node.boundsMin, node.boundsMax) > bestDistSq { continue }

            if node.isLeaf {
                let first = Int(node.leftFirst)
                for t in first..<(first + Int(node.triCount)) {
                    let p = Self.closestPointOnTriangle(query, triangles[t])
                    let d2 = distance_squared(p, query)
                    if d2 < bestDistSq {
                        bestDistSq = d2
                        hit = SurfaceHit(
                            point: p, normal: normals[t],
                            distance: sqrt(d2), triangleIndex: t
                        )
                    }
                }
            } else {
                let left = Int(node.leftFirst)
                let right = left + 1
                // Visit the nearer child first so the search radius shrinks sooner.
                let dl = boxDistanceSquared(query, nodes[left].boundsMin, nodes[left].boundsMax)
                let dr = boxDistanceSquared(query, nodes[right].boundsMin, nodes[right].boundsMax)
                let (near, far) = dl < dr ? (left, right) : (right, left)
                if stackTop + 2 <= stack.count {
                    stack[stackTop] = far
                    stackTop += 1
                    stack[stackTop] = near
                    stackTop += 1
                }
            }
        }
        return hit
    }

    private func boxDistanceSquared(
        _ p: SIMD3<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>
    ) -> Float {
        let d = max(max(lo - p, p - hi), SIMD3<Float>.zero)
        return dot(d, d)
    }

    /// Ericson, Real-Time Collision Detection section 5.1.5 - closest point on a
    /// triangle via Voronoi region tests. Branchy, but exact and allocation-free.
    static func closestPointOnTriangle(_ p: SIMD3<Float>, _ tri: GPUTriangle) -> SIMD3<Float> {
        let a = tri.a, b = tri.b, c = tri.c
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }

        let bp = p - b
        let d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            return a + (d1 / (d1 - d3)) * ab
        }

        let cp = p - c
        let d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            return a + (d2 / (d2 - d6)) * ac
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return b + ((d4 - d3) / ((d4 - d3) + (d5 - d6))) * (c - b)
        }

        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }
}

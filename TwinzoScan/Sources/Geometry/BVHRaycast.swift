import Foundation
import simd

/// Where a ray met the design surface.
struct RayHit {
    /// Intersection point, in model space.
    var point: SIMD3<Float>
    /// Unit face normal of the triangle that was hit.
    var normal: SIMD3<Float>
    /// Distance along the ray from its origin, metres.
    var distance: Float
    var triangleIndex: Int
    var elementIndex: UInt32
}

extension BVH {

    /// First intersection of a ray with the mesh, nearest first.
    ///
    /// This is what lets an operator point at something and have the app know
    /// what it is. Three separate features rest on it — picking the model half of
    /// a target pair, tapping a surface to pull up its element, and snapping a
    /// measurement to the design geometry — and all three need the same thing:
    /// the identity of the surface under the finger, not merely the nearest one
    /// to some point in space.
    ///
    /// - Parameters:
    ///   - origin: ray origin in model space.
    ///   - direction: ray direction in model space. Need not be normalised;
    ///     `distance` is reported in the same units as `origin` regardless.
    ///   - maxDistance: ignore intersections beyond this.
    func raycast(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float = .greatestFiniteMagnitude
    ) -> RayHit? {
        guard !nodes.isEmpty else { return nil }
        let length = simd.length(direction)
        guard length > 1e-9 else { return nil }
        let unit = direction / length

        // Reciprocal direction, computed once: a descent visits a lot of nodes
        // and the slab test would otherwise divide on every one of them. The
        // infinities a zero component produces are never used — `slabDistance`
        // takes the parallel axis out before it reaches the arithmetic.
        let inverse = SIMD3<Float>(1 / unit.x, 1 / unit.y, 1 / unit.z)

        var nearest = maxDistance
        var hit: RayHit?

        var stack = [Int](repeating: 0, count: 64)
        var stackTop = 0
        stack[stackTop] = 0
        stackTop += 1

        while stackTop > 0 {
            stackTop -= 1
            let node = nodes[stack[stackTop]]

            guard let entry = Self.slabDistance(
                origin: origin, direction: unit, inverse: inverse,
                lo: node.boundsMin, hi: node.boundsMax, limit: nearest
            ) else { continue }
            // A box that starts further away than the closest hit so far cannot
            // contain a nearer one.
            if entry > nearest { continue }

            if node.isLeaf {
                let first = Int(node.leftFirst)
                for t in first..<(first + Int(node.triCount)) {
                    guard let distance = Self.intersect(
                        origin: origin, direction: unit, triangle: triangles[t])
                    else { continue }
                    if distance < nearest {
                        nearest = distance
                        hit = RayHit(
                            point: origin + unit * distance,
                            normal: normals[t],
                            distance: distance,
                            triangleIndex: t,
                            elementIndex: triangles[t].elementIndex
                        )
                    }
                }
            } else {
                let left = Int(node.leftFirst)
                let right = left + 1
                let dl = Self.slabDistance(origin: origin, direction: unit,
                                           inverse: inverse,
                                           lo: nodes[left].boundsMin,
                                           hi: nodes[left].boundsMax, limit: nearest)
                let dr = Self.slabDistance(origin: origin, direction: unit,
                                           inverse: inverse,
                                           lo: nodes[right].boundsMin,
                                           hi: nodes[right].boundsMax, limit: nearest)

                // Push the further child first so the nearer one is popped next:
                // hitting it shrinks `nearest` and lets the far subtree be
                // rejected outright rather than traversed.
                switch (dl, dr) {
                case let (l?, r?):
                    let (near, far) = l < r ? (left, right) : (right, left)
                    if stackTop + 2 <= stack.count {
                        stack[stackTop] = far;  stackTop += 1
                        stack[stackTop] = near; stackTop += 1
                    }
                case (.some, .none):
                    if stackTop < stack.count { stack[stackTop] = left; stackTop += 1 }
                case (.none, .some):
                    if stackTop < stack.count { stack[stackTop] = right; stackTop += 1 }
                case (.none, .none):
                    break
                }
            }
        }
        return hit
    }

    /// Distance at which a ray enters an axis-aligned box, or nil if it misses.
    /// Zero when the origin is already inside.
    private static func slabDistance(
        origin: SIMD3<Float>, direction: SIMD3<Float>, inverse: SIMD3<Float>,
        lo: SIMD3<Float>, hi: SIMD3<Float>, limit: Float
    ) -> Float? {
        var entry: Float = 0
        var exit = limit

        for axis in 0..<3 {
            // A ray travelling exactly along one axis is parallel to the other
            // two slabs, and that case has to be taken out before any arithmetic
            // rather than left to the infinities to sort out.
            //
            // The tempting version — multiply by the reciprocal and let ±inf
            // flow through — is wrong in a way that is easy to miss and hard to
            // see. Where the box boundary sits exactly on the ray origin, and BIM
            // geometry makes that ordinary rather than freakish, the product is
            // 0 * infinity = NaN. Feed that to an ordinary comparison and the box
            // is rejected; feed it to IEEE minNum/maxNum and the NaN is replaced
            // by the *other* operand, which for the exit bound is -infinity, and
            // the box is rejected just as wrongly. Either way the ray sails
            // through solid geometry and the operator taps a wall and gets the
            // element behind it.
            //
            // A parallel ray imposes no constraint on entry or exit at all. It
            // either lies within the slab for its whole length or misses the box
            // outright, and that is a containment test, not an intersection one.
            if abs(direction[axis]) < 1e-9 {
                if origin[axis] < lo[axis] || origin[axis] > hi[axis] { return nil }
                continue
            }
            let a = (lo[axis] - origin[axis]) * inverse[axis]
            let b = (hi[axis] - origin[axis]) * inverse[axis]
            entry = Swift.max(entry, Swift.min(a, b))
            exit = Swift.min(exit, Swift.max(a, b))
        }
        return entry <= exit ? entry : nil
    }

    /// Möller–Trumbore. Returns the distance along `direction`, or nil.
    ///
    /// Two-sided on purpose: BIM exports are inconsistent about winding, and a
    /// back-face cull would make tapping a wall work from one side of the
    /// building and silently do nothing from the other.
    private static func intersect(
        origin: SIMD3<Float>, direction: SIMD3<Float>, triangle: GPUTriangle
    ) -> Float? {
        let edge1 = triangle.b - triangle.a
        let edge2 = triangle.c - triangle.a
        let h = cross(direction, edge2)
        let determinant = dot(edge1, h)
        guard abs(determinant) > 1e-9 else { return nil }   // ray parallel to the face

        let inverseDeterminant = 1 / determinant
        let s = origin - triangle.a
        let u = dot(s, h) * inverseDeterminant
        guard u >= -1e-6, u <= 1 + 1e-6 else { return nil }

        let q = cross(s, edge1)
        let v = dot(direction, q) * inverseDeterminant
        guard v >= -1e-6, u + v <= 1 + 1e-6 else { return nil }

        let distance = dot(edge2, q) * inverseDeterminant
        // Reject intersections behind the origin, and the origin itself: a ray
        // cast from a point already on the surface must not hit that surface.
        return distance > 1e-5 ? distance : nil
    }
}

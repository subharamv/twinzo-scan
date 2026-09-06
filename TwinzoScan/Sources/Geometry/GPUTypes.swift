import simd

/// Layout-compatible mirrors of the structs declared in `Deviation.metal`.
///
/// Every field is a `SIMD4<Float>` so that Swift's and Metal's alignment rules
/// agree without any manual padding: `float4` is 16-byte aligned in both.
/// Integer payloads are bit-cast into the unused `w` lane.

/// A BVH node. Interior nodes store the index of their first child (children
/// are always adjacent, so `right == left + 1`); leaves store the index of
/// their first triangle. `triCount == 0` marks an interior node.
struct GPUBVHNode {
    var boundsMinAndLeftFirst: SIMD4<Float>
    var boundsMaxAndCount: SIMD4<Float>

    init(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, leftFirst: UInt32, triCount: UInt32) {
        boundsMinAndLeftFirst = SIMD4(boundsMin, Float(bitPattern: leftFirst))
        boundsMaxAndCount = SIMD4(boundsMax, Float(bitPattern: triCount))
    }

    var boundsMin: SIMD3<Float> { boundsMinAndLeftFirst.xyz }
    var boundsMax: SIMD3<Float> { boundsMaxAndCount.xyz }
    var leftFirst: UInt32 {
        get { boundsMinAndLeftFirst.w.bitPattern }
        set { boundsMinAndLeftFirst.w = Float(bitPattern: newValue) }
    }
    var triCount: UInt32 {
        get { boundsMaxAndCount.w.bitPattern }
        set { boundsMaxAndCount.w = Float(bitPattern: newValue) }
    }
    var isLeaf: Bool { triCount != 0 }
}

/// A triangle in BIM-model space. `w` lanes are unused padding.
struct GPUTriangle {
    var v0: SIMD4<Float>
    var v1: SIMD4<Float>
    var v2: SIMD4<Float>

    init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        v0 = SIMD4(a, 0); v1 = SIMD4(b, 0); v2 = SIMD4(c, 0)
    }

    var a: SIMD3<Float> { v0.xyz }
    var b: SIMD3<Float> { v1.xyz }
    var c: SIMD3<Float> { v2.xyz }

    var centroid: SIMD3<Float> { (a + b + c) / 3 }

    /// Unnormalised geometric normal; degenerate triangles yield ~zero length.
    var faceNormal: SIMD3<Float> { cross(b - a, c - a) }
}

/// Parameters handed to the deviation kernel each frame.
struct DeviationUniforms {
    /// LiDAR-vertex space -> BIM-model space. The BVH lives in model space, so
    /// we move the (far fewer) query points instead of rebuilding the tree.
    var worldToModel: float4x4
    /// Deviations at or below this (metres) are "in tolerance" and shade green.
    var toleranceMeters: Float
    /// Deviation at which the heat ramp saturates (metres).
    var saturationMeters: Float
    /// Anything beyond this is treated as "no corresponding BIM surface" and is
    /// shaded transparent rather than red — avoids painting furniture, people
    /// and clutter as construction defects.
    var rejectMeters: Float
    var vertexCount: UInt32
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

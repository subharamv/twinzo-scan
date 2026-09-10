#include <metal_stdlib>
using namespace metal;

// Layout mirrors of the Swift structs in GPUTypes.swift. Every field is a
// float4 so Swift and Metal agree on alignment without manual padding.

struct BVHNode {
    float4 boundsMinAndLeftFirst;  // xyz = min corner, w = child/triangle index
    float4 boundsMaxAndCount;      // xyz = max corner, w = triangle count (0 = interior)
};

// v0.w carries the owning element's index, bit-cast to uint. See GPUTypes.swift.
struct Triangle {
    float4 v0;
    float4 v1;
    float4 v2;
};

constant uint kUnattributedElement = 0xFFFFFFFFu;

struct DeviationUniforms {
    float4x4 worldToModel;
    float toleranceMeters;
    float saturationMeters;
    float rejectMeters;
    uint vertexCount;
};

// Running totals for the on-screen readout. Distances accumulate as scaled
// integers because atomic float add is not available across all target GPUs.
struct DeviationStats {
    atomic_uint inToleranceCount;
    atomic_uint outOfToleranceCount;
    atomic_uint unmatchedCount;
    // Distances accumulate in tenths of a millimetre: micrometres would overflow
    // 32 bits once a large scan accumulates a few tens of thousands of vertices.
    atomic_uint summedTenthMillimetres;
    atomic_uint maxTenthMillimetres;
};

// MARK: - Geometry helpers

static inline float boxDistanceSquared(float3 p, float3 lo, float3 hi) {
    float3 d = max(max(lo - p, p - hi), float3(0.0));
    return dot(d, d);
}

// Ericson, Real-Time Collision Detection 5.1.5. Identical to the Swift version
// in BVH.swift; the two must stay in step or CPU alignment and GPU deviation
// will disagree about where a surface is.
static inline float3 closestPointOnTriangle(float3 p, Triangle tri) {
    float3 a = tri.v0.xyz, b = tri.v1.xyz, c = tri.v2.xyz;
    float3 ab = b - a, ac = c - a, ap = p - a;

    float d1 = dot(ab, ap), d2 = dot(ac, ap);
    if (d1 <= 0.0 && d2 <= 0.0) return a;

    float3 bp = p - b;
    float d3 = dot(ab, bp), d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) return b;

    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        return a + (d1 / (d1 - d3)) * ab;
    }

    float3 cp = p - c;
    float d5 = dot(ab, cp), d6 = dot(ac, cp);
    if (d6 >= 0.0 && d5 <= d6) return c;

    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        return a + (d2 / (d2 - d6)) * ac;
    }

    float va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        return b + ((d4 - d3) / ((d4 - d3) + (d5 - d6))) * (c - b);
    }

    float denom = 1.0 / (va + vb + vc);
    return a + ab * (vb * denom) + ac * (vc * denom);
}

struct ClosestResult {
    float distance;
    float signedDistance;  // negative = scanned surface sits behind the BIM face
    // Model-space vector from the design surface to the scanned point. Its
    // per-axis components are what the element readout reports as dX/dY/dZ; a
    // scalar distance cannot tell an inspector which way a column leans.
    float3 delta;
    uint element;
    bool found;
};

// Stackless-friendly traversal with a fixed 32-entry stack. Depth is bounded by
// the SAH builder in practice; a deeper tree would silently drop branches, so
// the builder caps leaf size rather than depth growing without limit.
static ClosestResult closestSurface(float3 query,
                                    device const BVHNode *nodes,
                                    device const Triangle *triangles,
                                    device const float4 *normals,
                                    float maxDistance) {
    ClosestResult result;
    result.distance = maxDistance;
    result.signedDistance = maxDistance;
    result.delta = float3(0.0);
    result.element = kUnattributedElement;
    result.found = false;

    float bestDistSq = maxDistance * maxDistance;

    uint stack[32];
    int stackTop = 0;
    stack[stackTop++] = 0u;

    while (stackTop > 0) {
        uint index = stack[--stackTop];
        BVHNode node = nodes[index];
        float3 lo = node.boundsMinAndLeftFirst.xyz;
        float3 hi = node.boundsMaxAndCount.xyz;

        if (boxDistanceSquared(query, lo, hi) > bestDistSq) continue;

        uint leftFirst = as_type<uint>(node.boundsMinAndLeftFirst.w);
        uint triCount = as_type<uint>(node.boundsMaxAndCount.w);

        if (triCount > 0u) {
            for (uint t = leftFirst; t < leftFirst + triCount; ++t) {
                float3 p = closestPointOnTriangle(query, triangles[t]);
                float3 delta = query - p;
                float d2 = dot(delta, delta);
                if (d2 < bestDistSq) {
                    bestDistSq = d2;
                    float d = sqrt(d2);
                    result.distance = d;
                    // Sign against the face normal so "material where the model
                    // has none" reads differently from "missing material".
                    result.signedDistance = (dot(delta, normals[t].xyz) < 0.0) ? -d : d;
                    result.delta = delta;
                    result.element = as_type<uint>(triangles[t].v0.w);
                    result.found = true;
                }
            }
        } else {
            uint left = leftFirst;
            uint right = leftFirst + 1u;
            float dl = boxDistanceSquared(query,
                                          nodes[left].boundsMinAndLeftFirst.xyz,
                                          nodes[left].boundsMaxAndCount.xyz);
            float dr = boxDistanceSquared(query,
                                          nodes[right].boundsMinAndLeftFirst.xyz,
                                          nodes[right].boundsMaxAndCount.xyz);
            uint nearChild = (dl < dr) ? left : right;
            uint farChild  = (dl < dr) ? right : left;
            if (stackTop + 2 <= 32) {
                stack[stackTop++] = farChild;
                stack[stackTop++] = nearChild;
            }
        }
    }
    return result;
}

// MARK: - Deviation banding

// The overlay is drawn with one flat material per band rather than per-vertex
// colour: RealityKit's MeshDescriptor exposes per-face material segmentation on
// every iOS version this app targets, but not vertex colours. Eight bands is
// enough to read a heat map at arm's length and cheap enough to rebuild per frame.
//
// 0        within tolerance
// 1 2 3    material closer to the scanner than designed, increasing
// 4 5 6    material behind the design surface, increasing
// 7        no corresponding BIM surface
constant uint kBandInTolerance = 0u;
constant uint kBandUnmatched   = 7u;

static inline uint deviationBand(float signedDistance, float tolerance, float saturation) {
    float magnitude = abs(signedDistance);
    if (magnitude <= tolerance) return kBandInTolerance;

    float t = saturate((magnitude - tolerance) / max(saturation - tolerance, 1e-4));
    uint step = min(2u, (uint)(t * 3.0));
    return (signedDistance >= 0.0) ? (1u + step) : (4u + step);
}

// MARK: - Kernel

kernel void computeDeviation(
    // packed_float3, not float3: ARKit hands us a 12-byte-stride vertex buffer
    // and Metal's float3 is 16-byte aligned, so the padded type would misread it.
    device const packed_float3 *vertices  [[buffer(0)]],  // LiDAR mesh, anchor space
    device       uint          *bands     [[buffer(1)]],  // per-vertex band index out
    device       float         *distances [[buffer(2)]],  // signed metres out
    device const BVHNode       *nodes     [[buffer(3)]],
    device const Triangle      *triangles [[buffer(4)]],
    device const float4        *normals   [[buffer(5)]],
    constant     DeviationUniforms &u     [[buffer(6)]],
    device       DeviationStats  &stats   [[buffer(7)]],
    device       uint          *elements  [[buffer(8)]],  // owning BIM element per vertex
    device       float4        *deltas    [[buffer(9)]],  // model-space dX/dY/dZ out
    uint gid [[thread_position_in_grid]])
{
    if (gid >= u.vertexCount) return;

    float3 query = (u.worldToModel * float4(float3(vertices[gid]), 1.0)).xyz;
    ClosestResult hit = closestSurface(query, nodes, triangles, normals, u.rejectMeters);

    if (!hit.found) {
        // No BIM surface nearby: almost always clutter, people or scan noise
        // rather than a construction defect. Fade it out instead of flagging it.
        bands[gid] = kBandUnmatched;
        distances[gid] = NAN;
        elements[gid] = kUnattributedElement;
        deltas[gid] = float4(0.0);
        atomic_fetch_add_explicit(&stats.unmatchedCount, 1u, memory_order_relaxed);
        return;
    }

    bands[gid] = deviationBand(hit.signedDistance, u.toleranceMeters, u.saturationMeters);
    distances[gid] = hit.signedDistance;
    elements[gid] = hit.element;
    deltas[gid] = float4(hit.delta, hit.signedDistance);

    uint tenthMillimetres = (uint)clamp(hit.distance * 1.0e4, 0.0, 1.0e7);
    atomic_fetch_add_explicit(&stats.summedTenthMillimetres, tenthMillimetres, memory_order_relaxed);
    atomic_fetch_max_explicit(&stats.maxTenthMillimetres, tenthMillimetres, memory_order_relaxed);

    if (hit.distance <= u.toleranceMeters) {
        atomic_fetch_add_explicit(&stats.inToleranceCount, 1u, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&stats.outOfToleranceCount, 1u, memory_order_relaxed);
    }
}

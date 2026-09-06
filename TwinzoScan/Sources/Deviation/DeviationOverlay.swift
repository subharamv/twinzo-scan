import Foundation
import RealityKit
import UIKit
import ARKit
import simd

/// Colour scheme for the deviation heat map.
///
/// Band indices are assigned on the GPU in `Deviation.metal`; this table must
/// stay in the same order as the `deviationBand` function there.
enum DeviationPalette {

    struct Band {
        var color: UIColor
        var opacity: Float
        var label: String
    }

    /// Diverging rather than sequential: the sign of the error matters as much as
    /// its size. Warm means material sits closer to the scanner than the design
    /// says; cool means it sits behind the design surface or is absent entirely.
    static let bands: [Band] = [
        Band(color: UIColor(red: 0.15, green: 0.85, blue: 0.35, alpha: 1), opacity: 0.45,
             label: "Within tolerance"),

        Band(color: UIColor(red: 1.00, green: 0.85, blue: 0.15, alpha: 1), opacity: 0.60,
             label: "Proud, slight"),
        Band(color: UIColor(red: 0.98, green: 0.55, blue: 0.10, alpha: 1), opacity: 0.72,
             label: "Proud, moderate"),
        Band(color: UIColor(red: 0.95, green: 0.12, blue: 0.12, alpha: 1), opacity: 0.85,
             label: "Proud, severe"),

        Band(color: UIColor(red: 0.35, green: 0.75, blue: 1.00, alpha: 1), opacity: 0.60,
             label: "Recessed, slight"),
        Band(color: UIColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1), opacity: 0.72,
             label: "Recessed, moderate"),
        Band(color: UIColor(red: 0.10, green: 0.15, blue: 0.85, alpha: 1), opacity: 0.85,
             label: "Recessed, severe"),

        Band(color: UIColor(white: 0.5, alpha: 1), opacity: 0.05,
             label: "No matching surface"),
    ]

    static let inToleranceIndex = 0
    static let unmatchedIndex = bands.count - 1

    /// Materials are built once and shared across every overlay chunk — a scan of
    /// a large bay produces hundreds of anchors and per-anchor materials would
    /// dominate memory.
    static let materials: [Material] = bands.map { band in
        var material = UnlitMaterial(color: band.color)
        material.blending = .transparent(opacity: .init(floatLiteral: band.opacity))
        // The overlay is diagnostic, not physical: drawing it unlit and
        // unshadowed keeps colour readable under factory lighting.
        return material
    }
}

/// Builds the coloured overlay geometry for one ARKit mesh anchor.
enum DeviationOverlay {

    /// Converts an anchor plus its per-vertex bands into a renderable entity.
    ///
    /// Faces are assigned to materials with `MeshDescriptor.segmentedFaces`,
    /// which is the only per-primitive colouring RealityKit offers without
    /// dropping to a custom Metal material. A face takes the worst band among its
    /// three vertices: for defect inspection, under-reporting is the dangerous
    /// direction.
    /// - Parameter positions: the anchor's vertices in anchor space. Passed in
    ///   rather than re-read: copying ARKit's buffer is one of the more expensive
    ///   things in the frame, and the caller has already paid for it once.
    static func makeEntity(
        for anchor: ARMeshAnchor,
        field: DeviationField,
        positions: [SIMD3<Float>],
        showInTolerance: Bool
    ) -> ModelEntity? {
        let geometry = anchor.geometry
        let vertexCount = positions.count
        guard vertexCount == field.bands.count, geometry.faces.count > 0 else { return nil }

        let indices = geometry.faceIndices()
        guard !positions.isEmpty, indices.count >= 3 else { return nil }

        // Only vertices belonging to a surviving face are uploaded. In the normal
        // working mode most faces are in tolerance and hidden, so keeping the
        // full vertex array would send thousands of unreferenced vertices to the
        // GPU for every chunk, every frame.
        var remap = [Int32](repeating: -1, count: vertexCount)
        var keptPositions: [SIMD3<Float>] = []
        var keptIndices: [UInt32] = []
        var faceMaterials: [UInt32] = []
        keptIndices.reserveCapacity(indices.count)
        faceMaterials.reserveCapacity(indices.count / 3)

        @inline(__always)
        func indexFor(_ original: Int) -> UInt32 {
            if remap[original] < 0 {
                remap[original] = Int32(keptPositions.count)
                keptPositions.append(positions[original])
            }
            return UInt32(remap[original])
        }

        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }

            let band = severestBand(field.bands[a], field.bands[b], field.bands[c])

            // Hiding the passing surface is the default working mode: an operator
            // walking a bay wants defects to pop, not a wall of green.
            if !showInTolerance && band == UInt32(DeviationPalette.inToleranceIndex) { continue }
            if band == UInt32(DeviationPalette.unmatchedIndex) { continue }

            keptIndices.append(indexFor(a))
            keptIndices.append(indexFor(b))
            keptIndices.append(indexFor(c))
            faceMaterials.append(band)
        }

        guard !faceMaterials.isEmpty else { return nil }

        var descriptor = MeshDescriptor(name: "deviation-\(anchor.identifier.uuidString)")
        descriptor.positions = MeshBuffers.Positions(keptPositions)
        descriptor.primitives = .triangles(keptIndices)
        descriptor.materials = .perFace(faceMaterials)

        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }

        let entity = ModelEntity(mesh: mesh, materials: DeviationPalette.materials)
        // The overlay lives in the anchor's own frame; the caller parents it to
        // an AnchorEntity tracking that anchor, so it follows ARKit's refinements.
        entity.name = anchor.identifier.uuidString
        return entity
    }

    /// Worst-case band across a face. Ordering is by severity, not by raw index:
    /// index 3 (severe proud) and index 6 (severe recessed) are equally bad, and
    /// "no matching surface" is not a defect at all.
    /// Compared directly rather than through a temporary array: this runs once
    /// per triangle, for every chunk, every frame.
    @inline(__always)
    private static func severestBand(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        var best = a
        var bestSeverity = severity(a)
        let sb = severity(b)
        if sb > bestSeverity { best = b; bestSeverity = sb }
        if severity(c) > bestSeverity { best = c }
        return best
    }

    private static func severity(_ band: UInt32) -> Int {
        switch Int(band) {
        case DeviationPalette.unmatchedIndex: return -1
        case DeviationPalette.inToleranceIndex: return 0
        case 1, 4: return 1
        case 2, 5: return 2
        default: return 3
        }
    }
}

extension ARMeshGeometry {

    /// Copies the anchor's vertex positions out of ARKit's Metal buffer.
    ///
    /// The buffer is 12-byte-stride packed float3 and is owned by ARKit, which
    /// may recycle it once the frame is released — so anything outliving the
    /// frame has to copy rather than alias.
    func vertexPositions() -> [SIMD3<Float>] {
        let source = vertices
        guard source.format == .float3 else { return [] }
        var result = [SIMD3<Float>](repeating: .zero, count: source.count)
        let base = source.buffer.contents().advanced(by: source.offset)
        for i in 0..<source.count {
            // Read three scalars rather than binding to SIMD3<Float>: that type
            // is 16 bytes wide and would over-read past the end of the last
            // vertex in a 12-byte-stride buffer.
            let pointer = base.advanced(by: i * source.stride)
                .assumingMemoryBound(to: Float.self)
            result[i] = SIMD3<Float>(pointer[0], pointer[1], pointer[2])
        }
        return result
    }

    /// Flattens the face index buffer. ARKit emits 32-bit triangle indices; the
    /// guard is there so a future format change fails loudly rather than
    /// producing scrambled geometry.
    func faceIndices() -> [UInt32] {
        let source = faces
        guard source.primitive == .triangle,
              source.bytesPerIndex == MemoryLayout<UInt32>.size
        else { return [] }

        let total = source.count * source.indexCountPerPrimitive
        let base = source.buffer.contents().assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: base, count: total))
    }
}

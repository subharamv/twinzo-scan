import Foundation
import RealityKit
import simd

/// A BIM model prepared for on-device comparison.
///
/// `entity` is what RealityKit draws; `bvh` is the same geometry flattened into a
/// triangle soup for distance queries. They are produced together so the overlay
/// and the numbers can never drift apart.
struct BIMModel {
    var name: String
    var entity: ModelEntity
    var bvh: BVH
    var triangleCount: Int
    /// Axis-aligned extents in model space, used to seed a sensible initial
    /// placement distance and to sanity-check units.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)
    /// Every addressable thing in the model, indexed positionally. Triangles
    /// carry an index into this array; the GPU hands that index straight back.
    var elements: [BIMElement]
    /// Model version this geometry belongs to, when the sidecar declared one.
    /// Findings are stamped with it so a deviation is always attributable to the
    /// revision it was measured against.
    var modelVersionID: String?
    /// Metres per source unit that was applied on load.
    var unitScale: Float

    var sizeMeters: SIMD3<Float> { bounds.max - bounds.min }

    /// Fraction of elements that can be written back to the authoring model.
    /// Shown on the model sheet: a low number means findings from this scan will
    /// not round-trip, and the operator should know that before scanning, not
    /// after.
    var addressableFraction: Float {
        guard !elements.isEmpty else { return 0 }
        let addressable = elements.reduce(into: 0) { $0 += $1.isAddressable ? 1 : 0 }
        return Float(addressable) / Float(elements.count)
    }

    func element(at index: UInt32) -> BIMElement? {
        guard index != GPUTriangle.unattributedElement,
              Int(index) < elements.count else { return nil }
        return elements[Int(index)]
    }
}

enum BIMLoaderError: LocalizedError {
    case unreadable(URL)
    case noGeometry
    case suspiciousScale(SIMD3<Float>)
    case metadataVersionMismatch(expected: String, found: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not open \(url.lastPathComponent). Convert Revit/IFC exports to USDZ first."
        case .noGeometry:
            return "The model loaded but contains no triangles."
        case .suspiciousScale(let size):
            let d = size.max()
            return String(
                format: "Model spans %.1f units on its longest axis, which is unlikely in metres. "
                      + "Check the export units (Revit commonly writes millimetres or feet).", d)
        case .metadataVersionMismatch(let expected, let found):
            return "The element metadata is for model version \(found) but this geometry is "
                 + "version \(expected). Re-export both together — mismatched metadata would "
                 + "attribute deviations to the wrong elements."
        }
    }
}

/// Loads converted BIM geometry (USDZ or .reality) and prepares it for comparison.
///
/// Revit and IFC do not load natively on iOS. The expected pipeline is a
/// server-side conversion — Revit -> IFC4 -> tessellated USDZ, plus an
/// `<model>.elements.json` sidecar carrying the properties USDZ cannot hold.
/// This loader validates scale on the way in, because a millimetre-unit export
/// silently produces a model 1000x too large and every downstream deviation
/// number becomes meaningless.
enum BIMModelLoader {

    /// Longest-axis extent beyond which the model is almost certainly not in metres.
    private static let implausibleExtentMeters: Float = 5_000

    /// - Parameters:
    ///   - url: the USDZ or `.reality` file.
    ///   - unitScale: metres per source unit. Overridden by the sidecar when it
    ///     declares one, since the exporter knows the source units and the
    ///     operator is guessing.
    ///   - expectedVersionID: model version the caller believes it is loading.
    static func load(
        from url: URL,
        unitScale: Float = 1.0,
        expectedVersionID: String? = nil
    ) throws -> BIMModel {
        let entity: ModelEntity
        do {
            entity = try ModelEntity.loadModel(contentsOf: url)
        } catch {
            throw BIMLoaderError.unreadable(url)
        }

        let sidecar = BIMMetadataSidecar.load(besides: url)
        if let expectedVersionID, let found = sidecar?.modelVersionID, found != expectedVersionID {
            throw BIMLoaderError.metadataVersionMismatch(expected: expectedVersionID, found: found)
        }

        let appliedScale = sidecar?.unitScale ?? unitScale
        if appliedScale != 1.0 {
            entity.scale = SIMD3<Float>(repeating: appliedScale)
        }

        // Sidecar records are joined to the scene graph by node name, so index
        // them once rather than scanning the array at every node.
        let recordsByNode = Dictionary(
            (sidecar?.elements ?? []).map { ($0.node, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var builder = ElementBuilder(records: recordsByNode)
        var triangles: [GPUTriangle] = []
        collectTriangles(
            from: entity,
            parentTransform: matrix_identity_float4x4,
            element: GPUTriangle.unattributedElement,
            builder: &builder,
            into: &triangles
        )
        guard !triangles.isEmpty else { throw BIMLoaderError.noGeometry }

        let bvh = BVH(triangles: triangles)
        let bounds = bvh.bounds
        let size = bounds.max - bounds.min
        guard size.max() < implausibleExtentMeters else {
            throw BIMLoaderError.suspiciousScale(size)
        }

        return BIMModel(
            name: url.deletingPathExtension().lastPathComponent,
            entity: entity,
            bvh: bvh,
            triangleCount: triangles.count,
            bounds: bounds,
            elements: builder.elements,
            modelVersionID: sidecar?.modelVersionID,
            unitScale: appliedScale
        )
    }

    // MARK: - Element identity

    /// Accumulates elements as the scene graph is walked, so an index is only
    /// spent on a node that turns out to own geometry.
    private struct ElementBuilder {
        let records: [String: BIMElementRecord]
        private(set) var elements: [BIMElement] = []

        /// Allocates an element for `node`, or returns nil when the node carries
        /// no identity worth splitting on.
        mutating func element(forNode node: String) -> UInt32? {
            guard !node.isEmpty else { return nil }
            let index = UInt32(elements.count)

            if let record = records[node] {
                let ifcType = record.ifcType
                let category = record.category
                elements.append(BIMElement(
                    index: index,
                    ifcGuid: record.ifcGuid,
                    name: record.name ?? node,
                    ifcType: ifcType,
                    category: category,
                    level: record.level,
                    mark: record.mark,
                    toleranceClass: record.toleranceClass
                        ?? .inferred(ifcType: ifcType, category: category),
                    properties: record.properties ?? [:]
                ))
                return index
            }

            // No sidecar entry. Recover a label from the node name, but leave
            // `ifcGuid` nil — see BIMNodeName for why a guessed id is refused.
            let parsed = BIMNodeName.parse(node)
            var properties: [String: String] = [:]
            if let guidLike = parsed.guidLike {
                properties["nodeGuidCandidate"] = guidLike
            }
            elements.append(BIMElement(
                index: index,
                ifcGuid: nil,
                name: parsed.label,
                ifcType: parsed.ifcType,
                category: nil,
                level: nil,
                mark: nil,
                toleranceClass: .inferred(ifcType: parsed.ifcType, category: nil),
                properties: properties
            ))
            return index
        }
    }

    // MARK: - Triangle extraction

    /// Walks the entity hierarchy, baking each node's transform into its
    /// triangles so the BVH lives in a single flat model space, and tagging each
    /// triangle with the element that owns it.
    ///
    /// Element identity is inherited: a named node claims an index and every
    /// descendant without a name of its own belongs to it. That matches how
    /// exporters actually nest geometry — one named element containing a handful
    /// of anonymous mesh parts per material.
    private static func collectTriangles(
        from entity: Entity,
        parentTransform: float4x4,
        element: UInt32,
        builder: inout ElementBuilder,
        into triangles: inout [GPUTriangle]
    ) {
        let worldTransform = parentTransform * entity.transform.matrix
        // Only claim a new index when this node names itself; otherwise stay
        // with whatever ancestor owns us.
        let element = builder.element(forNode: entity.name) ?? element

        // The subscript's typing differs between SDK versions: newer RealityKit
        // emits the typed `ModelComponent?`, while the Xcode 15.4 SDK emits
        // `any Component`. Casting covers both.
        if let model = entity.components[ModelComponent.self] as? ModelComponent {
            append(mesh: model.mesh, transform: worldTransform,
                   element: element, into: &triangles)
        }
        for child in entity.children {
            collectTriangles(from: child, parentTransform: worldTransform,
                             element: element, builder: &builder, into: &triangles)
        }
    }

    private static func append(
        mesh: MeshResource,
        transform: float4x4,
        element: UInt32,
        into triangles: inout [GPUTriangle]
    ) {
        let contents = mesh.contents

        // A MeshResource may instance the same model geometry several times with
        // different transforms — common for repeated BIM families such as columns
        // or door sets. Each instance has to be baked out separately.
        var instancesByModel: [String: [float4x4]] = [:]
        for instance in contents.instances {
            instancesByModel[instance.model, default: []].append(instance.transform)
        }

        for model in contents.models {
            let instanceTransforms = instancesByModel[model.id] ?? [matrix_identity_float4x4]

            for part in model.parts {
                let positions = part.positions.elements
                guard let indices = part.triangleIndices?.elements, indices.count >= 3 else { continue }

                for instanceTransform in instanceTransforms {
                    let full = transform * instanceTransform
                    triangles.reserveCapacity(triangles.count + indices.count / 3)

                    var i = 0
                    while i + 2 < indices.count {
                        let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
                        i += 3
                        guard a < positions.count, b < positions.count, c < positions.count else { continue }

                        let p0 = full.transformPoint(positions[a])
                        let p1 = full.transformPoint(positions[b])
                        let p2 = full.transformPoint(positions[c])

                        // Drop slivers: they contribute nothing but numerical
                        // noise to closest-point queries and normal estimates.
                        let area = length(cross(p1 - p0, p2 - p0)) * 0.5
                        guard area > 1e-9 else { continue }

                        triangles.append(GPUTriangle(p0, p1, p2, element: element))
                    }
                }
            }
        }
    }
}

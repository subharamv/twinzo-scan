import Foundation

/// Which set of thresholds an element is signed off against.
///
/// A single project-wide tolerance is never right: structural steel, MEP routing
/// and architectural finishes are accepted against limits that differ by an order
/// of magnitude. Carrying the class on the element is what lets one scan report
/// each element against the limit it was actually specified to.
enum ToleranceClass: String, Codable, CaseIterable, Sendable {
    case structural
    case mep
    case finishes
    case unclassified

    var settings: ToleranceSettings {
        switch self {
        case .structural:   return .structural
        case .mep:          return .mep
        case .finishes:     return .finishes
        case .unclassified: return ToleranceSettings()
        }
    }

    var displayName: String {
        switch self {
        case .structural:   return "Structural"
        case .mep:          return "MEP"
        case .finishes:     return "Finishes"
        case .unclassified: return "Unclassified"
        }
    }

    /// Best-effort classification from an IFC type or Revit category string.
    ///
    /// Deliberately conservative: anything unrecognised lands in `.unclassified`
    /// and is measured against the project default rather than being quietly
    /// assigned a tolerance nobody chose.
    static func inferred(ifcType: String?, category: String?) -> ToleranceClass {
        let haystack = [ifcType, category]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return .unclassified }

        let structural = ["column", "beam", "slab", "footing", "pile", "member",
                          "plate", "brace", "wall", "foundation", "stair", "ramp"]
        let mep = ["pipe", "duct", "cable", "conduit", "flowsegment", "flowfitting",
                   "flowterminal", "flowcontroller", "sanitary", "valve", "sprinkler",
                   "airterminal", "electric", "lightfixture", "mechanical", "plumbing"]
        let finishes = ["covering", "furnishing", "ceiling", "finish", "railing",
                        "curtainwall", "curtain wall", "window", "door", "casework",
                        "cladding"]

        // Finishes and MEP are tested before structural on purpose: "curtain
        // wall" contains "wall" and would otherwise be graded against a
        // structural tolerance it is never expected to meet.
        if finishes.contains(where: haystack.contains) { return .finishes }
        if mep.contains(where: haystack.contains) { return .mep }
        if structural.contains(where: haystack.contains) { return .structural }
        return .unclassified
    }
}

/// One addressable thing in the BIM model — a column, a duct run, a wall panel.
///
/// The index is positional within `BIMModel.elements` and is what the BVH, the
/// GPU kernel and the inspection log all pass around; `ifcGuid` is what the
/// server, Revit and BCF speak. Keeping both, and never conflating them, is what
/// lets a finding survive the trip back to the model author.
struct BIMElement: Identifiable, Codable, Equatable, Sendable {
    /// Positional index — the value packed into `GPUTriangle.elementIndex`.
    var index: UInt32
    /// IFC global id (22-character base-64 form), when the export carried one.
    /// Without it an element is reportable but not addressable: findings cannot
    /// round-trip to Revit.
    var ifcGuid: String?
    /// Human label, e.g. "Level 2 Slab".
    var name: String
    /// IFC entity type, e.g. `IfcColumn`.
    var ifcType: String?
    /// Revit category, e.g. `Structural Columns`.
    var category: String?
    /// Building storey or level name.
    var level: String?
    /// Revit "Mark" — the label printed on drawings and the one an inspector
    /// will actually say out loud.
    var mark: String?
    var toleranceClass: ToleranceClass
    /// Everything else the exporter carried, kept verbatim so the server can
    /// index properties this app has no opinion about.
    var properties: [String: String]

    var id: UInt32 { index }

    /// What to show in a list, falling through the identifiers most likely to
    /// mean something on site.
    var displayName: String {
        if let mark, !mark.isEmpty { return mark }
        if !name.isEmpty { return name }
        if let ifcGuid, !ifcGuid.isEmpty { return String(ifcGuid.prefix(8)) }
        return "Element \(index)"
    }

    var subtitle: String {
        [category ?? ifcType, level].compactMap { $0 }.joined(separator: " · ")
    }

    /// True when a finding against this element can be written back to the
    /// authoring model.
    var isAddressable: Bool { ifcGuid?.isEmpty == false }

    static func placeholder(index: UInt32, name: String) -> BIMElement {
        BIMElement(index: index, ifcGuid: nil, name: name, ifcType: nil,
                   category: nil, level: nil, mark: nil,
                   toleranceClass: .unclassified, properties: [:])
    }
}

// MARK: - Metadata sidecar

/// One record in the `<model>.elements.json` sidecar.
///
/// The sidecar is how Revit/IFC metadata survives conversion to USDZ, which
/// preserves geometry and node names but no properties. It is written by the
/// same server-side step that tessellates the model, keyed by the node name that
/// step emitted.
struct BIMElementRecord: Codable, Sendable {
    /// USDZ / `.reality` node name this record describes. The join key.
    var node: String
    var ifcGuid: String?
    var name: String?
    var ifcType: String?
    var category: String?
    var level: String?
    var mark: String?
    var toleranceClass: ToleranceClass?
    var properties: [String: String]?
}

struct BIMMetadataSidecar: Codable, Sendable {
    /// Model version this metadata belongs to, checked against the geometry the
    /// device loaded. Metadata from a different revision would attribute
    /// deviations to the wrong elements, which is worse than having none.
    var modelVersionID: String?
    var sourceFile: String?
    /// Metres per model unit. A Revit export in millimetres arrives as 0.001.
    var unitScale: Float?
    var elements: [BIMElementRecord]

    /// Looks for `<model>.elements.json` alongside the geometry.
    static func load(besides modelURL: URL) -> BIMMetadataSidecar? {
        let sidecar = modelURL
            .deletingPathExtension()
            .appendingPathExtension("elements.json")
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? JSONDecoder().decode(BIMMetadataSidecar.self, from: data)
    }
}

// MARK: - Node name parsing

/// Recovers what it can from a bare node name when no sidecar is present.
///
/// Conversion pipelines commonly emit names like
/// `IfcColumn_C-12_1a$Bc0De7F9gHiJkLmNoP`. Reading those is strictly better than
/// nothing — it gets an operator a usable label on site. But an element
/// identified this way is never marked addressable: a guessed GUID that is wrong
/// files a defect against someone else's column, which is far more damaging than
/// filing it against no column at all.
enum BIMNodeName {

    /// IFC global ids are 22 characters of a base-64 variant using `_` and `$`.
    private static let guidCharacters = Set(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$")

    static func looksLikeIfcGuid<S: StringProtocol>(_ token: S) -> Bool {
        token.count == 22 && token.allSatisfy { guidCharacters.contains($0) }
    }

    /// Splits a node name into its plausible parts.
    ///
    /// `guidLike` is reported separately from any real identifier so the caller
    /// can label with it without claiming the element is addressable.
    static func parse(_ node: String) -> (ifcType: String?, label: String, guidLike: String?) {
        let tokens = node.split(whereSeparator: { $0 == "_" || $0 == "|" || $0 == ":" })
        guard !tokens.isEmpty else { return (nil, node, nil) }

        let ifcType = tokens.first
            .map(String.init)
            .flatMap { $0.lowercased().hasPrefix("ifc") ? $0 : nil }
        let guidLike = tokens.first(where: looksLikeIfcGuid).map(String.init)

        let label = tokens
            .dropFirst(ifcType == nil ? 0 : 1)
            .filter { !looksLikeIfcGuid($0) }
            .joined(separator: " ")

        return (ifcType, label.isEmpty ? node : label, guidLike)
    }
}

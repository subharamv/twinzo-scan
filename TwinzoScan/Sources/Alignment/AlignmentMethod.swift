import Foundation

// Kept in its own file, free of Combine, so the wire-format mapping that
// depends on it can be compiled and tested off Apple hardware alongside the
// rest of the registration code.

/// How a registration was arrived at. Carried through to the report, because
/// "surveyed against four control points" and "lined up by eye" are not the same
/// evidence even when they produce the same residual.
enum AlignmentMethod: String, Codable, Sendable {
    case manual
    case controlPoints
    case icp
    case controlPointsThenICP

    var displayName: String {
        switch self {
        case .manual:              return "Manual"
        case .controlPoints:       return "Targets"
        case .icp:                 return "ICP"
        case .controlPointsThenICP: return "Targets + ICP"
        }
    }
}

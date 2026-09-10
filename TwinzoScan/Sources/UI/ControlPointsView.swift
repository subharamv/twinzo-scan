import SwiftUI
import simd

/// Manages the surveyed targets and runs the fit.
///
/// The screen is mostly about telling the operator what their targets can and
/// cannot determine. Three or more fixes a pose; two fixes a heading and takes
/// the rest from gravity; one fixes only a position. Registering from one target
/// and believing the numbers is the mistake this view exists to prevent.
struct ControlPointsView: View {
    @ObservedObject var session: ScanSession
    @Environment(\.dismiss) private var dismiss

    @State private var allowScale = false
    @State private var suppliedScaleText = ""

    private var coordinator: AlignmentCoordinator { session.alignment }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(capabilityDescription, systemImage: capabilityIcon)
                        .font(.callout)
                } header: {
                    Text("\(coordinator.controlPoints.count) targets")
                } footer: {
                    Text("Tap a real feature, then the same point on the overlaid model. "
                       + "Spread targets across the space: heading error grows as they get "
                       + "closer together.")
                }

                if !coordinator.controlPoints.isEmpty {
                    Section("Targets") {
                        ForEach(coordinator.controlPoints) { pair in
                            TargetRow(pair: pair, session: session)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                coordinator.removeControlPoint(
                                    id: coordinator.controlPoints[index].id)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Solve for scale", isOn: $allowScale)
                    if allowScale && coordinator.controlPoints.count == 1 {
                        TextField("Scale from a measured reference", text: $suppliedScaleText)
                            .keyboardType(.decimalPad)
                    }
                } footer: {
                    Text("Leave this off unless you know the model units are wrong. LiDAR output "
                       + "is already metric, so a free scale parameter does not measure anything "
                       + "real — it absorbs registration error into a 0.98x fit and makes every "
                       + "deviation 2% wrong while the residual looks better than ever.")
                }

                Section {
                    Button {
                        coordinator.alignToControlPoints(
                            allowScale: allowScale,
                            suppliedScale: Float(suppliedScaleText))
                        if case .aligned = coordinator.state { dismiss() }
                    } label: {
                        Label("Align to targets", systemImage: "scope")
                    }
                    .disabled(coordinator.controlPoints.isEmpty)

                    Button("Remove all targets", role: .destructive) {
                        coordinator.removeAllControlPoints()
                    }
                    .disabled(coordinator.controlPoints.isEmpty)
                }

                if !coordinator.registrationWarnings.isEmpty {
                    Section("What this fit could not determine") {
                        ForEach(coordinator.registrationWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if case .failed(let reason) = coordinator.state {
                    Section {
                        Label(reason, systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var capabilityDescription: String {
        switch coordinator.controlPoints.count {
        case 0:  return "No targets yet. Switch to Targets mode and tap a feature."
        case 1:  return "One target fixes position only. Heading stays as you set it by hand."
        case 2:  return "Two targets fix heading and position. Roll and pitch come from gravity."
        default: return "\(coordinator.controlPoints.count) targets fix the full pose."
        }
    }

    private var capabilityIcon: String {
        switch coordinator.controlPoints.count {
        case 0:  return "circle.dashed"
        case 1:  return "1.circle"
        case 2:  return "2.circle"
        default: return "checkmark.circle"
        }
    }
}

private struct TargetRow: View {
    let pair: ControlPointPair
    @ObservedObject var session: ScanSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pair.label.isEmpty ? "Target" : pair.label)
                .font(.subheadline.weight(.medium))
            Text(coordinates)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if let index = pair.elementIndex,
               let element = session.model?.element(at: index) {
                Text("on \(element.displayName)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var coordinates: String {
        String(format: "scan %.2f, %.2f, %.2f  →  model %.2f, %.2f, %.2f",
               pair.worldPoint.x, pair.worldPoint.y, pair.worldPoint.z,
               pair.modelPoint.x, pair.modelPoint.y, pair.modelPoint.z)
    }
}

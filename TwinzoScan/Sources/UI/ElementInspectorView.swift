import SwiftUI
import simd

/// Shared formatting. Deviations are read in millimetres on site, always signed,
/// because "+19" and "-19" call for opposite remedies and an unsigned number
/// makes the reader guess.
enum DeviationFormat {
    static func millimetres(_ metres: Float, signed: Bool = false) -> String {
        guard metres.isFinite else { return "—" }
        return String(format: signed ? "%+.0f mm" : "%.0f mm", metres * 1000)
    }

    static func percent(_ fraction: Float?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return String(format: "%.0f%%", fraction * 100)
    }
}

extension ElementStatus {
    var label: String {
        switch self {
        case .pass:             return "In Tolerance"
        case .fail:             return "Out of Tolerance"
        case .insufficientData: return "Insufficient Data"
        case .unverified:       return "Not Scanned"
        }
    }

    var tint: Color {
        switch self {
        case .pass:             return .green
        case .fail:             return .red
        case .insufficientData: return .orange
        // Grey, deliberately not green. An unscanned element is an open question,
        // and colouring it like a pass is how a report ends up claiming coverage
        // nobody achieved.
        case .unverified:       return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .pass:             return "checkmark.circle.fill"
        case .fail:             return "exclamationmark.triangle.fill"
        case .insufficientData: return "questionmark.circle.fill"
        case .unverified:       return "circle.dashed"
        }
    }
}

/// The card from the field workflow: which element, how far out, and which way.
///
/// Per-axis offsets rather than one distance because they answer different
/// questions. "19 mm out" tells an engineer there is a problem; "+4, -6, +18"
/// tells them the column is leaning along Z and roughly how to pack it.
struct ElementDeviationCard: View {
    let inspection: ElementInspection
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 6) {
                axisRow("ΔX", inspection.meanOffset.x)
                axisRow("ΔY", inspection.meanOffset.y)
                axisRow("ΔZ", inspection.meanOffset.z)
                Divider()
                HStack {
                    Text("Overall").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(DeviationFormat.millimetres(inspection.meanSigned, signed: true))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                HStack {
                    Text("Worst").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(DeviationFormat.millimetres(inspection.maxAbsolute))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(inspection.status.tint)
                }
            }

            StatusChip(status: inspection.status)

            // The tolerance the verdict was reached against, spelled out. Two
            // elements showing the same millimetres and different verdicts is
            // correct behaviour and looks like a bug unless this is on screen.
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(inspection.element.displayName)
                    .font(.headline)
                let subtitle = inspection.element.subtitle
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss element")
            }
        }
    }

    private func axisRow(_ label: String, _ value: Float) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(DeviationFormat.millimetres(value, signed: true))
                .font(.subheadline.monospacedDigit())
        }
    }

    private var footnote: String {
        var parts = [
            "Tolerance \(DeviationFormat.millimetres(inspection.tolerance))",
            "\(inspection.accumulator.sampleCount) samples",
        ]
        if let coverage = inspection.coverage {
            parts.append("\(DeviationFormat.percent(coverage)) covered")
        }
        if !inspection.element.isAddressable {
            parts.append("no IFC id — will not round-trip")
        }
        return parts.joined(separator: " · ")
    }
}

struct StatusChip: View {
    let status: ElementStatus

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(status.tint)
    }
}

/// The full per-element list, with the roll-up that keeps the pass rate honest.
struct ElementInspectorView: View {
    @ObservedObject var session: ScanSession
    @Environment(\.dismiss) private var dismiss

    @State private var filter: Filter = .problems
    @State private var search = ""

    enum Filter: String, CaseIterable, Identifiable {
        case problems = "Problems"
        case all = "All"
        case unverified = "Not scanned"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { SummaryPanel(summary: session.inspectionSummary,
                                       coverage: session.coverage) }

                Section {
                    if session.isComputingCoverage {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Measuring coverage…").font(.caption)
                        }
                    } else {
                        Button {
                            session.computeCoverage()
                        } label: {
                            Label(session.coverage == nil
                                    ? "Measure coverage"
                                    : "Re-measure coverage",
                                  systemImage: "square.dashed.inset.filled")
                        }
                        .disabled(!session.alignment.state.allowsDeviationAnalysis)
                    }
                } footer: {
                    Text("Coverage samples the design surface and asks whether anything was "
                       + "scanned near it. Without it, a wall nobody walked past reports no "
                       + "defects — because there was no data, not because it was built right.")
                }

                Section {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("\(filtered.count) elements") {
                    ForEach(filtered.prefix(300)) { inspection in
                        ElementRow(inspection: inspection) {
                            session.selectElement(inspection.element.index)
                            dismiss()
                        }
                    }
                    if filtered.count > 300 {
                        Text("\(filtered.count - 300) more not shown. Narrow the search.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $search, prompt: "Mark, name or IFC id")
            .navigationTitle("Elements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var filtered: [ElementInspection] {
        let base: [ElementInspection]
        switch filter {
        case .problems:
            base = session.elementInspections
                .filter { $0.status == .fail || $0.status == .insufficientData }
                .sorted { $0.maxAbsolute > $1.maxAbsolute }
        case .unverified:
            base = session.elementInspections.filter { $0.status == .unverified }
        case .all:
            base = session.elementInspections.sorted { $0.maxAbsolute > $1.maxAbsolute }
        }

        guard !search.isEmpty else { return base }
        let needle = search.lowercased()
        return base.filter { inspection in
            let element = inspection.element
            return element.displayName.lowercased().contains(needle)
                || element.name.lowercased().contains(needle)
                || (element.ifcGuid?.lowercased().contains(needle) ?? false)
                || (element.category?.lowercased().contains(needle) ?? false)
        }
    }
}

private struct ElementRow: View {
    let inspection: ElementInspection
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: inspection.status.systemImage)
                    .foregroundStyle(inspection.status.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(inspection.element.displayName)
                        .font(.subheadline.weight(.medium))
                    let subtitle = inspection.element.subtitle
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(inspection.status == .unverified
                            ? "—"
                            : DeviationFormat.millimetres(inspection.maxAbsolute))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(inspection.status.tint)
                    if let coverage = inspection.coverage {
                        Text(DeviationFormat.percent(coverage))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The front page of a report.
///
/// Pass rate and verified fraction are shown side by side and never apart. A
/// 100% pass rate over 12% of a building is not a passing building, and a panel
/// that shows only the first number invites exactly that reading.
struct SummaryPanel: View {
    let summary: InspectionSummary
    let coverage: CoverageReport?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                metric("Pass rate", DeviationFormat.percent(summary.passRate),
                       tint: summary.passRate > 0.95 ? .green : .orange,
                       caption: "of \(summary.measured) measured")
                Divider().frame(height: 34)
                metric("Verified", DeviationFormat.percent(summary.verifiedFraction),
                       tint: summary.verifiedFraction > 0.8 ? .green : .orange,
                       caption: "of \(summary.total) elements")
            }

            HStack(spacing: 0) {
                count("Pass", summary.pass, .green)
                count("Fail", summary.fail, .red)
                count("Partial", summary.insufficient, .orange)
                count("Unscanned", summary.unverified, .secondary)
            }

            if let coverage {
                Text(String(
                    format: "%.1f m² of %.1f m² design surface reached, sampled at %.0f cm.",
                    coverage.coveredArea, coverage.totalArea, coverage.spacing * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ label: String, _ value: String,
                        tint: Color, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
            Text(label).font(.caption)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func count(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

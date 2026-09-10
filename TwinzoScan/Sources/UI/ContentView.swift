import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Top-level screen: camera feed underneath, workflow controls on top.
struct ContentView: View {

    @StateObject private var session = ScanSession()
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var showingElements = false
    @State private var showingTargets = false

    var body: some View {
        ZStack(alignment: .top) {
            ARViewContainer(session: session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                StatusBanner(session: session)

                if case .drifting(_, let drift) = session.alignment.state {
                    DriftBanner(drift: drift) { session.alignment.acknowledgeDrift() }
                }

                if session.alignment.state.allowsDeviationAnalysis {
                    DeviationReadout(statistics: session.statistics,
                                     summary: session.inspectionSummary,
                                     tolerances: session.tolerances)
                }

                Spacer()

                // The identify card takes precedence: the operator asked for this
                // element specifically. Otherwise show the worst failure, which is
                // what they would have gone looking for anyway.
                if let inspection = session.selectedInspection {
                    ElementDeviationCard(inspection: inspection) {
                        session.selectElement(nil)
                    }
                } else if let worst = session.failedInspections.first {
                    ElementDeviationCard(inspection: worst)
                }

                if let message = session.errorMessage {
                    MessageBanner(text: message) { session.dismissError() }
                }

                ControlBar(
                    session: session,
                    onImport: { showingImporter = true },
                    onSettings: { showingSettings = true },
                    onElements: { showingElements = true },
                    onTargets: { showingTargets = true }
                )
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showingImporter,
            // Revit and IFC do not load on iOS; the expected input is a USDZ (or
            // .reality) produced by the server-side conversion, with its
            // elements.json sidecar alongside it.
            allowedContentTypes: [UTType.usdz, UTType(filenameExtension: "reality") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                session.loadModel(from: url)
            }
        }
        .sheet(isPresented: $showingSettings) {
            ToleranceSettingsView(session: session)
        }
        .sheet(isPresented: $showingElements) {
            ElementInspectorView(session: session)
        }
        .sheet(isPresented: $showingTargets) {
            ControlPointsView(session: session)
        }
        .onDisappear { session.pause() }
    }
}

// MARK: - Status

private struct StatusBanner: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .refining = session.alignment.state {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var title: String {
        switch session.alignment.state {
        case .waitingForModel:
            return "No model loaded"
        case .placing:
            return session.interactionMode == .target ? "Placing targets" : "Place the model"
        case .refining:
            return "Aligning to scan"
        case .aligned(let quality):
            return String(format: "Aligned — %.0f mm RMS", quality.rmsError * 1000)
        case .drifting(let quality, _):
            return String(format: "Drifting — was %.0f mm RMS", quality.rmsError * 1000)
        case .failed:
            return "Alignment rejected"
        }
    }

    private var detail: String {
        switch session.alignment.state {
        case .waitingForModel:
            return "Import a converted BIM model to begin."
        case .placing:
            if session.interactionMode == .target {
                return session.pendingTargetWorldPoint == nil
                    ? "Tap the feature on site."
                    : "Now tap the same point on the model."
            }
            return "Tap the floor to drop it, two fingers to slide, twist to rotate."
        case .refining:
            return "Running ICP against \(session.scanPointCount) scan points."
        case .aligned(let quality):
            var parts = [quality.method.displayName]
            if quality.inlierRatio > 0 {
                parts.append(String(format: "%.0f%% matched", quality.inlierRatio * 100))
            }
            if abs(quality.scale - 1) > 1e-4 {
                parts.append(String(format: "scale %.4f", quality.scale))
            }
            parts.append("\(session.meshAnchorCount) chunks")
            return parts.joined(separator: " · ")
        case .drifting(_, let drift):
            return String(format: "World frame moved %.0f mm at 10 m.", drift * 1000)
        case .failed(let reason):
            return reason
        }
    }

    private var indicatorColor: Color {
        switch session.alignment.state {
        case .aligned:  return .green
        case .drifting: return .orange
        case .refining: return .yellow
        case .failed:   return .red
        default:        return .gray
        }
    }
}

/// Drift is surfaced rather than silently absorbed once it is big enough to
/// matter. A finding taken either side of a 40 mm correction is not comparable
/// with one taken before it, and the operator is the only one who can decide
/// whether to re-register or carry on.
private struct DriftBanner: View {
    let drift: Float
    let onAcknowledge: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tracking has drifted").font(.caption.weight(.semibold))
                Text(String(format: "%.0f mm at working distance. Re-align against targets if "
                                  + "this scan has to be defended.", drift * 1000))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("OK", action: onAcknowledge).font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DeviationReadout: View {
    let statistics: DeviationStatistics
    let summary: InspectionSummary
    let tolerances: ToleranceSettings

    var body: some View {
        HStack(spacing: 0) {
            metric("Pass", DeviationFormat.percent(statistics.passRate),
                   tint: statistics.passRate > 0.95 ? .green : .orange)
            divider
            metric("Mean", DeviationFormat.millimetres(statistics.meanDeviation))
            divider
            metric("Max", DeviationFormat.millimetres(statistics.maxDeviation),
                   tint: statistics.maxDeviation > tolerances.saturation ? .red : .primary)
            divider
            // Failing elements, not vertex counts. A vertex total tells the
            // operator how hard the GPU is working; this tells them how many
            // things are wrong.
            metric("Failing", "\(summary.fail)",
                   tint: summary.fail > 0 ? .red : .green)
            divider
            metric("Verified", DeviationFormat.percent(summary.verifiedFraction),
                   tint: summary.verifiedFraction > 0.8 ? .green : .orange)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var divider: some View {
        Divider().frame(height: 26)
    }

    private func metric(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MessageBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Controls

private struct ControlBar: View {
    @ObservedObject var session: ScanSession
    let onImport: () -> Void
    let onSettings: () -> Void
    let onElements: () -> Void
    let onTargets: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if session.interactionMode == .place,
               case .placing = session.alignment.state {
                HeightNudge(session: session)
            }

            Picker("Mode", selection: $session.interactionMode) {
                ForEach(ScanSession.InteractionMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(session.model == nil)

            HStack(spacing: 10) {
                circleButton("square.and.arrow.down", label: "Import", action: onImport)
                circleButton("scope", label: "Targets", action: onTargets)

                Button(action: session.refineAlignment) {
                    Label("Align", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
                .disabled(!canAlign)
                .opacity(canAlign ? 1 : 0.4)

                circleButton("list.bullet.rectangle", label: "Elements", action: onElements)
                circleButton("slider.horizontal.3", label: "Settings", action: onSettings)
            }
        }
    }

    /// ICP needs both a model and enough scanned surface to constrain the fit.
    /// Offering the button before that is offering a guaranteed failure.
    private var canAlign: Bool {
        session.model != nil
            && session.scanPointCount > 500
            && session.alignment.state != .refining
    }

    private func circleButton(
        _ systemImage: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

/// Vertical placement is separated from the pan gesture because the model datum
/// and the scanned floor almost never agree, and it needs finer control than a
/// drag gives.
private struct HeightNudge: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Height").font(.caption).foregroundStyle(.secondary)
            ForEach([-0.10, -0.01, 0.01, 0.10], id: \.self) { delta in
                Button(String(format: "%+.0f", delta * 100)) {
                    session.alignment.adjustHeight(by: Float(delta))
                }
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("cm").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

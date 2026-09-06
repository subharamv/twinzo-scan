import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Top-level screen: camera feed underneath, workflow controls on top.
struct ContentView: View {

    @StateObject private var session = ScanSession()
    @State private var showingImporter = false
    @State private var showingSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            ARViewContainer(session: session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                StatusBanner(session: session)

                if session.alignment.state.allowsDeviationAnalysis {
                    DeviationReadout(statistics: session.statistics,
                                     tolerances: session.tolerances)
                }

                Spacer()

                if let message = session.errorMessage {
                    MessageBanner(text: message) { session.dismissError() }
                }

                ControlBar(
                    session: session,
                    onImport: { showingImporter = true },
                    onSettings: { showingSettings = true }
                )
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showingImporter,
            // Revit and IFC do not load on iOS; the expected input is a USDZ (or
            // .reality) produced by an offline conversion step.
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
        case .waitingForModel: return "No model loaded"
        case .placing: return "Place the model"
        case .refining: return "Aligning to scan"
        case .aligned(let rms, _): return String(format: "Aligned — %.0f mm RMS", rms * 1000)
        case .failed: return "Alignment rejected"
        }
    }

    private var detail: String {
        switch session.alignment.state {
        case .waitingForModel:
            return "Import a converted BIM model to begin."
        case .placing:
            return "Tap the floor to drop it, two fingers to slide, twist to rotate."
        case .refining:
            return "Running ICP against \(session.scanPointCount) scan points."
        case .aligned(_, let inliers):
            return String(format: "%.0f%% of the scan matched · %d mesh chunks",
                          inliers * 100, session.meshAnchorCount)
        case .failed(let reason):
            return reason
        }
    }

    private var indicatorColor: Color {
        switch session.alignment.state {
        case .aligned: return .green
        case .refining: return .yellow
        case .failed: return .red
        default: return .gray
        }
    }
}

private struct DeviationReadout: View {
    let statistics: DeviationStatistics
    let tolerances: ToleranceSettings

    var body: some View {
        HStack(spacing: 0) {
            metric("Pass", String(format: "%.1f%%", statistics.passRate * 100),
                   tint: statistics.passRate > 0.95 ? .green : .orange)
            divider
            metric("Mean", millimetres(statistics.meanDeviation))
            divider
            metric("Max", millimetres(statistics.maxDeviation),
                   tint: statistics.maxDeviation > tolerances.saturation ? .red : .primary)
            divider
            metric("Points", "\(statistics.comparedCount)")
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

    private func millimetres(_ metres: Float) -> String {
        metres.isFinite ? String(format: "%.0f mm", metres * 1000) : "—"
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

    var body: some View {
        VStack(spacing: 12) {
            if case .placing = session.alignment.state {
                HeightNudge(session: session)
            }

            HStack(spacing: 12) {
                circleButton("square.and.arrow.down", label: "Import", action: onImport)

                Button(action: session.refineAlignment) {
                    Label("Align", systemImage: "scope")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
                .disabled(!canAlign)
                .opacity(canAlign ? 1 : 0.4)

                circleButton("slider.horizontal.3", label: "Settings", action: onSettings)
                circleButton("arrow.counterclockwise", label: "Reset",
                             action: session.resetAlignment)
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
                .font(.system(size: 18, weight: .medium))
                .frame(width: 50, height: 50)
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

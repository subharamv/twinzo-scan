import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Top-level screen: camera feed underneath, workflow controls on top.
struct ContentView: View {

    @StateObject private var session = ScanSession()
    @StateObject private var sensorMonitor = SensorMonitor()
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var showingElements = false
    @State private var showingTargets = false
    @State private var showingSensorDebug = false
    @State private var showingScanMode = false
    @State private var showingFreeScanMode = false
    @State private var isExporting = false

    var body: some View {
        ZStack {
            ARViewContainer(session: session)
                .ignoresSafeArea()
            
            VStack(spacing: 8) {
                // Top section with status and sensor button
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        StatusBanner(session: session)
                        
                        // Sensor button at top
                        Button(action: { showingSensorDebug.toggle() }) {
                            Image(systemName: showingSensorDebug ? "sensor.fill" : "sensor")
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 46, height: 46)
                                .background(
                                    showingSensorDebug ? Color.blue.opacity(0.3) : Color.clear,
                                    in: Circle()
                                )
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Sensors")
                    }
                    
                    // Standalone scan mode banner
                    if session.model == nil {
                        ScanModeBanner(
                            scanPointCount: session.scanPointCount,
                            meshAnchorCount: session.meshAnchorCount,
                            isExporting: isExporting,
                            onExport: { exportPointCloud() }
                        )
                    }

                    if case .drifting(_, let drift) = session.alignment.state {
                        DriftBanner(drift: drift) { session.alignment.acknowledgeDrift() }
                    }

                    if session.alignment.state.allowsDeviationAnalysis {
                        DeviationReadout(statistics: session.statistics,
                                         summary: session.inspectionSummary,
                                         tolerances: session.tolerances)
                    }
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
                    showingSensorDebug: $showingSensorDebug,
                    showingFreeScanMode: $showingFreeScanMode,
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
        .sheet(isPresented: $showingSensorDebug) {
            SensorDebugSheet(monitor: sensorMonitor)
        }
        .fullScreenCover(isPresented: $showingFreeScanMode) {
            FreeScanModeView(session: session)
        }
        .onAppear {
            sensorMonitor.start()
        }
        .onDisappear {
            session.pause()
            sensorMonitor.stop()
        }
    }
    
    // MARK: - Export Point Cloud
    
    private func exportPointCloud() {
        isExporting = true
        Task {
            do {
                let url = try session.exportScanCloud()
                
                // Share the file
                await MainActor.run {
                    let activityController = UIActivityViewController(
                        activityItems: [url],
                        applicationActivities: nil
                    )
                    
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first,
                       let rootVC = window.rootViewController {
                        activityController.popoverPresentationController?.sourceView = window
                        rootVC.present(activityController, animated: true)
                    }
                    
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    session.reportStartupFailure(error)
                    isExporting = false
                }
            }
        }
    }
}

// MARK: - Status

private struct ScanModeBanner: View {
    let scanPointCount: Int
    let meshAnchorCount: Int
    let isExporting: Bool
    let onExport: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.blue)
                    .frame(width: 10, height: 10)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free Scan Mode").font(.subheadline.weight(.semibold))
                    Text("Scanning room without model • Live mesh visible")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            
            // Stats row
            HStack(spacing: 12) {
                statItem(icon: "point.3.filled.connected.trianglepath.dotted", 
                        value: formatPoints(scanPointCount), 
                        label: "Points")
                
                Divider().frame(height: 20)
                
                statItem(icon: "cube.transparent", 
                        value: "\(meshAnchorCount)", 
                        label: "Meshes")
                
                Spacer()
                
                // Export button
                Button(action: onExport) {
                    HStack(spacing: 4) {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
                }
                .disabled(scanPointCount == 0 || isExporting)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    
    private func statItem(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func formatPoints(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}

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
    @Binding var showingSensorDebug: Bool
    @Binding var showingFreeScanMode: Bool
    let onImport: () -> Void
    let onSettings: () -> Void
    let onElements: () -> Void
    let onTargets: () -> Void

    var body: some View {
        VStack(spacing: 10) {
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
            
            // Free Scan Mode Button
            Button(action: { showingFreeScanMode.toggle() }) {
                HStack {
                    Image(systemName: "dot.scope")
                    Text("Free Scan Mode")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(.white)
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
        _ systemImage: String, 
        label: String, 
        action: @escaping () -> Void
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

// MARK: - Sensor Debug Sheet

private struct SensorDebugSheet: View {
    @ObservedObject var monitor: SensorMonitor
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Gyroscope
                    SensorDetailSection(
                        title: "Gyroscope",
                        icon: "gyroscope",
                        unit: "rad/s",
                        iconColor: .blue,
                        isAvailable: monitor.isGyroAvailable,
                        values: [
                            ("X-axis", monitor.gyroX),
                            ("Y-axis", monitor.gyroY),
                            ("Z-axis", monitor.gyroZ)
                        ]
                    )
                    
                    // Accelerometer
                    SensorDetailSection(
                        title: "Accelerometer",
                        icon: "arrow.up.down.square",
                        unit: "G",
                        iconColor: .green,
                        isAvailable: monitor.isAccelAvailable,
                        values: [
                            ("X-axis", monitor.accelX),
                            ("Y-axis", monitor.accelY),
                            ("Z-axis", monitor.accelZ)
                        ]
                    )
                    
                    // Magnetometer
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "location.north.circle.fill")
                                .foregroundStyle(.purple)
                            Text("Magnetometer")
                                .font(.headline)
                            Spacer()
                            if monitor.isMagnetometerAvailable {
                                Text(accuracyText(monitor.magnetometerAccuracy))
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(accuracyColor(monitor.magnetometerAccuracy).opacity(0.2))
                                    .foregroundStyle(accuracyColor(monitor.magnetometerAccuracy))
                                    .cornerRadius(8)
                            }
                        }
                        
                        if monitor.isMagnetometerAvailable {
                            VStack(spacing: 8) {
                                SensorValueRow(label: "X-axis", value: monitor.magnetometerX, unit: "μT")
                                SensorValueRow(label: "Y-axis", value: monitor.magnetometerY, unit: "μT")
                                SensorValueRow(label: "Z-axis", value: monitor.magnetometerZ, unit: "μT")
                                
                                Divider()
                                
                                SensorValueRow(
                                    label: "Magnitude",
                                    value: sqrt(
                                        monitor.magnetometerX * monitor.magnetometerX +
                                        monitor.magnetometerY * monitor.magnetometerY +
                                        monitor.magnetometerZ * monitor.magnetometerZ
                                    ),
                                    unit: "μT",
                                    highlighted: true
                                )
                            }
                            
                            if monitor.magnetometerAccuracy < 1 {
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.orange)
                                    Text("Move device in figure-8 pattern to calibrate")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 8)
                            }
                        } else {
                            Text("Magnetometer not available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    
                    // Device Attitude
                    if monitor.isDeviceMotionAvailable {
                        SensorDetailSection(
                            title: "Device Attitude",
                            icon: "rotate.3d",
                            unit: "degrees",
                            iconColor: .orange,
                            isAvailable: true,
                            values: [
                                ("Heading", monitor.heading),
                                ("Pitch", monitor.pitch),
                                ("Roll", monitor.roll)
                            ]
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Sensor Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func accuracyText(_ accuracy: Int32) -> String {
        switch accuracy {
        case -1: return "Uncalibrated"
        case 0: return "Low Accuracy"
        case 1: return "Medium Accuracy"
        case 2: return "High Accuracy"
        default: return "Unknown"
        }
    }
    
    private func accuracyColor(_ accuracy: Int32) -> Color {
        switch accuracy {
        case -1: return .red
        case 0: return .orange
        case 1: return .yellow
        case 2: return .green
        default: return .gray
        }
    }
}

private struct SensorDetailSection: View {
    let title: String
    let icon: String
    let unit: String
    let iconColor: Color
    let isAvailable: Bool
    let values: [(String, Double)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.headline)
                Spacer()
                if !isAvailable {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            
            if isAvailable {
                VStack(spacing: 8) {
                    ForEach(values, id: \.0) { label, value in
                        SensorValueRow(label: label, value: value, unit: unit)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SensorValueRow: View {
    let label: String
    let value: Double
    let unit: String
    var highlighted: Bool = false
    
    var body: some View {
        HStack {
            Text(label)
                .font(highlighted ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(highlighted ? .primary : .secondary)
            Spacer()
            HStack(spacing: 4) {
                Text(String(format: "%.4f", value))
                    .font(.system(.body, design: .monospaced).weight(highlighted ? .semibold : .regular))
                    .foregroundStyle(valueColor(value))
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    private func valueColor(_ value: Double) -> Color {
        let absValue = abs(value)
        if absValue < 0.01 {
            return .primary
        } else if absValue < 0.5 {
            return .green
        } else if absValue < 1.0 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Free Scan Mode

struct FreeScanModeView: View {
    @ObservedObject var session: ScanSession
    @Environment(\.dismiss) private var dismiss
    @State private var isScanning = false
    @State private var isExporting = false
    
    var body: some View {
        ZStack {
            // AR View with mesh visualization
            ARViewContainer(session: session)
                .ignoresSafeArea()
            
            VStack {
                // Top bar
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding()
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    
                    Spacer()
                    
                    Text("Free Scan Mode")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    
                    Spacer()
                    
                    // Scan indicator
                    if isScanning {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 10, height: 10)
                            Text("SCANNING")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.3), in: Capsule())
                    }
                }
                .padding()
                
                Spacer()
                
                // Stats panel
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        StatCard(
                            icon: "point.3.filled.connected.trianglepath.dotted",
                            value: formatPoints(session.scanPointCount),
                            label: "Points"
                        )
                        
                        StatCard(
                            icon: "cube.transparent",
                            value: "\(session.meshAnchorCount)",
                            label: "Meshes"
                        )
                    }
                    
                    // Control buttons
                    HStack(spacing: 12) {
                        // Start/Stop button
                        Button(action: toggleScanning) {
                            HStack {
                                Image(systemName: isScanning ? "stop.circle.fill" : "play.circle.fill")
                                Text(isScanning ? "Stop Scan" : "Start Scan")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isScanning ? Color.red : Color.green, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        
                        // Export button
                        Button(action: exportScan) {
                            HStack {
                                if isExporting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export")
                                        .font(.headline)
                                }
                            }
                            .frame(width: 120)
                            .padding()
                            .background(.blue, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .disabled(session.scanPointCount == 0 || isExporting)
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Ensure AR session is running
            isScanning = true
        }
        .onDisappear {
            isScanning = false
        }
    }
    
    private func toggleScanning() {
        isScanning.toggle()
        if !isScanning {
            // Pause accumulation but keep AR running
        }
    }
    
    private func exportScan() {
        isExporting = true
        Task {
            do {
                let url = try session.exportScanCloud()
                
                await MainActor.run {
                    let activityController = UIActivityViewController(
                        activityItems: [url],
                        applicationActivities: nil
                    )
                    
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first,
                       let rootVC = window.rootViewController {
                        activityController.popoverPresentationController?.sourceView = window
                        rootVC.present(activityController, animated: true)
                    }
                    
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                }
            }
        }
    }
    
    private func formatPoints(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ContentView()
}

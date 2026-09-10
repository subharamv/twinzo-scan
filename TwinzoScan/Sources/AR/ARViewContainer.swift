import SwiftUI
import RealityKit
import ARKit

/// Hosts the RealityKit view and translates touch gestures into coarse
/// placement commands.
struct ARViewContainer: UIViewRepresentable {

    @ObservedObject var session: ScanSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.session = session

        // Placement gestures are only meaningful before the model is registered;
        // the coordinator gates them on alignment state rather than adding and
        // removing recognisers, which would fight with SwiftUI's update cycle.
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        let rotate = UIRotationGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleRotate(_:)))

        for recogniser in [tap, pan, rotate] as [UIGestureRecognizer] {
            recogniser.delegate = context.coordinator
            view.addGestureRecognizer(recogniser)
        }

        do {
            try session.start(in: view)
        } catch {
            // Surfaced through the session so the failure reaches the UI rather
            // than leaving a blank camera feed with no explanation. Called
            // directly: makeUIView already runs on the main actor, and hopping
            // through a Task would push a non-Sendable Error across an isolation
            // boundary for no benefit.
            session.reportStartupFailure(error)
        }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.session = session
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var session: ScanSession?

        /// Metres of model movement per point of finger travel. Tuned so a full
        /// screen-width drag moves the model a couple of metres: enough to be
        /// useful, fine enough to line a wall up by eye.
        private let panSensitivity: Float = 0.004

        /// Gating lives in the session now: identifying an element and dropping a
        /// target are both wanted *after* registration, and only placement has to
        /// stop once the model is registered.
        @objc func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard let session else { return }
            session.handleTap(atScreenPoint: recogniser.location(in: recogniser.view))
        }

        @objc func handlePan(_ recogniser: UIPanGestureRecognizer) {
            guard let session, session.interactionMode == .place,
                  !session.alignment.state.allowsDeviationAnalysis else { return }
            let translation = recogniser.translation(in: recogniser.view)
            recogniser.setTranslation(.zero, in: recogniser.view)

            // Drag maps to the ground plane in camera-relative axes, so "push
            // away" moves the model away from the operator regardless of heading.
            session.nudgeModelInCameraPlane(
                right: Float(translation.x) * panSensitivity,
                forward: Float(-translation.y) * panSensitivity
            )
        }

        @objc func handleRotate(_ recogniser: UIRotationGestureRecognizer) {
            guard let session, session.interactionMode == .place,
                  !session.alignment.state.allowsDeviationAnalysis else { return }
            session.alignment.rotate(byRadians: Float(-recogniser.rotation))
            recogniser.rotation = 0
        }

        /// Two-finger pan and rotation are naturally used together while lining
        /// a model up, so let them run simultaneously.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

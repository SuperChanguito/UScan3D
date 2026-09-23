import RealityKit
import SwiftUI

/// The live guided-capture screen: RealityKit's ObjectCaptureView renders the
/// camera feed, point cloud, and reticle; we overlay the stage controls.
struct CaptureView: View {
    let session: ObjectCaptureSession
    let mode: ScanMode
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                Spacer()
                controls
                    .padding(.bottom, 24)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch session.state {
        case .ready:
            VStack(spacing: 12) {
                instruction(mode == .face
                    ? "Have your subject sit still, then point the camera at their head and shoulders. Tap Continue."
                    : "Point the camera at your object, then tap Continue.")
                actionButton("Continue") { _ = session.startDetecting() }
            }
        case .detecting:
            VStack(spacing: 12) {
                instruction("Move closer or farther until the box hugs the object.")
                HStack(spacing: 12) {
                    Button("Reset") { session.resetDetection() }
                        .buttonStyle(.bordered)
                    actionButton("Start Capture") { session.startCapturing() }
                }
            }
        case .capturing:
            if session.userCompletedScanPass {
                VStack(spacing: 12) {
                    instruction(mode == .face
                        ? "Orbit complete. Keep scanning for more coverage, or finish."
                        : "Orbit complete. Flip the object to capture its underside, keep scanning this side, or finish.")
                    if mode == .object && !session.feedback.contains(.objectNotFlippable) {
                        actionButton("Flip Object & Continue") { session.beginNewScanPassAfterFlip() }
                    }
                    HStack(spacing: 12) {
                        Button("Scan More") { session.beginNewScanPass() }
                            .buttonStyle(.bordered)
                        actionButton("Finish Scan") { session.finish() }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    instruction(mode == .face
                        ? "Orbit slowly around the head and shoulders — \(session.numberOfShotsTaken) photos so far."
                        : "Orbit the object slowly — \(session.numberOfShotsTaken) photos so far.")
                    actionButton("Finish Scan") { session.finish() }
                }
            }
        case .finishing:
            ProgressView("Finishing…")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        default:
            EmptyView()
        }
    }

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
    }
}

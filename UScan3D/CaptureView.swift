import RealityKit
import SwiftUI

/// The live guided-capture screen: RealityKit's ObjectCaptureView renders the
/// camera feed, point cloud, and reticle; we overlay the stage controls.
struct CaptureView: View {
    let session: ObjectCaptureSession
    let mode: ScanMode
    /// Called just before a new pass begins; `true` if the object was flipped.
    let onNewPass: (_ flipped: Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            captureView
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

    /// Area mode has no bounding box, so the object reticle is hidden.
    @ViewBuilder
    private var captureView: some View {
        if #available(iOS 18.0, *), mode.usesAreaMode {
            ObjectCaptureView(session: session)
                .hideObjectReticle(true)
        } else {
            ObjectCaptureView(session: session)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch session.state {
        case .ready:
            VStack(spacing: 12) {
                instruction(mode.readyInstruction)
                if mode.usesAreaMode {
                    // Skipping startDetecting() is what starts area mode.
                    actionButton("Start Capture") { session.startCapturing() }
                } else {
                    actionButton("Continue") { _ = session.startDetecting() }
                }
            }
        case .detecting:
            VStack(spacing: 12) {
                instruction(mode.detectingInstruction)
                HStack(spacing: 12) {
                    Button("Reset") { session.resetDetection() }
                        .buttonStyle(.bordered)
                    actionButton("Start Capture") { session.startCapturing() }
                }
            }
        case .capturing:
            // Area mode is one continuous capture: the low/middle/high loops
            // are all part of it, so there are no separate passes.
            if session.userCompletedScanPass && !mode.usesAreaMode {
                VStack(spacing: 12) {
                    instruction(mode.orbitCompleteInstruction)
                    if mode.allowsFlip && !session.feedback.contains(.objectNotFlippable) {
                        Text("Flipping works best on objects with detail on every side. Try laying it on its side instead of upside down, keep it in the same spot, and don't change the lighting. Flat-bottomed objects: skip the flip and use Flat base instead.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        actionButton("Flip Object & Continue") {
                            onNewPass(true)
                            session.beginNewScanPassAfterFlip()
                        }
                    }
                    HStack(spacing: 12) {
                        Button("Scan More") {
                            onNewPass(false)
                            session.beginNewScanPass()
                        }
                            .buttonStyle(.bordered)
                        actionButton("Finish Scan") { session.finish() }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    instruction(mode.orbitInstruction(photos: session.numberOfShotsTaken))
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

import SwiftUI

/// Full-screen container that walks one scan through its phases:
/// capture -> reconstruction -> preview/export.
struct ScanFlowView: View {
    @StateObject private var flow = ScanFlowModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
        }
        .interactiveDismissDisabled()
        .onAppear {
            if case .setup = flow.phase {
                flow.startCapture()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .setup:
            ProgressView("Starting camera…")

        case .capturing:
            if let session = flow.session {
                CaptureView(session: session) {
                    flow.cancelAndCleanUp()
                    dismiss()
                }
                .task { await flow.observeSession() }
                .toolbar(.hidden, for: .navigationBar)
            }

        case .reconstructing(let progress):
            VStack(spacing: 20) {
                ProgressView(value: progress) {
                    Text("Building your 3D model…")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)

                Text("Keep U-Scan3D open — this can take a few minutes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Cancel", role: .destructive) {
                    flow.cancelReconstruction()
                }
            }

        case .finished(let modelURL):
            ModelPreviewView(modelURL: modelURL) {
                dismiss()
            }

        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Close") {
                    flow.cancelAndCleanUp()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

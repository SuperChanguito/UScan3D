import SwiftUI

/// Full-screen container that walks one scan through its phases:
/// mode selection -> capture -> reconstruction -> preview/export.
struct ScanFlowView: View {
    @StateObject private var flow = ScanFlowModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: ScanMode = .object

    var body: some View {
        NavigationStack {
            content
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .setup:
            setupView

        case .capturing:
            if let session = flow.session {
                CaptureView(session: session, mode: flow.mode) {
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

        case .failed(let message, let canRetry):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if canRetry {
                    Button("Try Again") {
                        flow.retryReconstruction()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Discard Scan", role: .destructive) {
                        flow.cancelAndCleanUp()
                        dismiss()
                    }
                } else {
                    Button("Close") {
                        flow.cancelAndCleanUp()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var setupView: some View {
        VStack(spacing: 24) {
            Text("New Scan")
                .font(.title2.bold())

            Picker("Scan mode", selection: $selectedMode) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedMode.setupHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Start Scanning") {
                flow.startCapture(mode: selectedMode)
            }
            .buttonStyle(.borderedProminent)

            Button("Cancel", role: .cancel) { dismiss() }
        }
        .padding()
        .navigationBarBackButtonHidden()
    }
}

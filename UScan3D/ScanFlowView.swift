import SwiftUI
import UIKit

/// Full-screen container that walks one scan through its phases:
/// mode selection -> capture -> reconstruction -> preview/export.
struct ScanFlowView: View {
    @StateObject private var flow = ScanFlowModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: ScanMode = .object
    @State private var showingRebuildOptions = false

    var body: some View {
        NavigationStack {
            content
        }
        .interactiveDismissDisabled()
        // Capture and reconstruction take minutes; don't let the screen
        // auto-lock (which backgrounds the app) in the middle of them.
        .onChange(of: keepsScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var keepsScreenAwake: Bool {
        switch flow.phase {
        case .capturing, .reconstructing:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .setup:
            setupView

        case .capturing:
            if let session = flow.session {
                CaptureView(session: session, mode: flow.mode) { flipped in
                    flow.recordPassBoundary(flipped: flipped)
                } onCancel: {
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
            .safeAreaInset(edge: .top) {
                if flow.hasKeptPhotos {
                    reviewBar
                }
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
                    if flow.hasBuiltModel {
                        Button("Keep Previous Model") {
                            flow.keepPreviousModel()
                        }
                    }
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

    /// Shown over a freshly built model while its photos are still kept, so
    /// a ghosted scan (usually a misaligned flip) can be rebuilt.
    private var reviewBar: some View {
        VStack(spacing: 8) {
            Text("Check the model from every side. If it looks doubled or ghosted, rebuild it before freeing up space.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Rebuild") { showingRebuildOptions = true }
                    .buttonStyle(.bordered)
                Button("Looks good — free up space") { flow.freeUpSpace() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
        .confirmationDialog("Rebuild the model?", isPresented: $showingRebuildOptions, titleVisibility: .visible) {
            if flow.canRebuildWithoutFlippedSide {
                Button("Rebuild without flipped side") { flow.rebuild(withoutFlippedSide: true) }
            }
            Button("Rebuild with all photos") { flow.rebuild(withoutFlippedSide: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(flow.canRebuildWithoutFlippedSide
                ? "Ghosting after a flip means the two sides didn't line up. Rebuilding without the flipped side uses only the photos from before the flip; the open bottom is filled in flat on export. Your current model is kept if the rebuild fails."
                : "Builds the model again from the same photos. Your current model is kept if the rebuild fails.")
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

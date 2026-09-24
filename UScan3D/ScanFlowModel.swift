import Foundation
import RealityKit
import SwiftUI

enum ScanMode: String, CaseIterable, Identifiable {
    case object = "Object"
    case face = "Face / Bust"

    var id: String { rawValue }

    var setupHint: String {
        switch self {
        case .object:
            return "Scan everyday objects for printing."
        case .face:
            return "Have your subject sit still and look forward. Orbit slowly around their head and shoulders."
        }
    }
}

/// Drives one scan end-to-end: guided capture with ObjectCaptureSession,
/// then on-device photogrammetry reconstruction into a USDZ model.
@MainActor
final class ScanFlowModel: ObservableObject {

    enum Phase {
        case setup
        case capturing
        case reconstructing(progress: Double)
        case finished(modelURL: URL)
        /// `canRetry` is true when reconstruction failed but the captured
        /// photos are still on disk, so it can be re-run without rescanning.
        case failed(message: String, canRetry: Bool = false)
    }

    @Published var phase: Phase = .setup
    @Published private(set) var session: ObjectCaptureSession?
    private(set) var mode: ScanMode = .object

    private var scanDirectory: URL?
    private var photoSession: PhotogrammetrySession?
    private var reconstructionTask: Task<Void, Never>?
    private var isObservingSession = false

    func startCapture(mode: ScanMode) {
        self.mode = mode
        do {
            let directory = try ScanStore.newScanDirectory()
            scanDirectory = directory

            let session = ObjectCaptureSession()
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = ScanStore.snapshotsDirectory(in: directory)
            session.start(
                imagesDirectory: ScanStore.imagesDirectory(in: directory),
                configuration: configuration)
            self.session = session
            phase = .capturing
        } catch {
            phase = .failed(message: "Could not start the scan: \(error.localizedDescription)")
        }
    }

    func observeSession() async {
        guard !isObservingSession, let stateUpdates = session?.stateUpdates else { return }
        isObservingSession = true
        defer { isObservingSession = false }

        // Don't hold a strong reference to the session here: iOS won't run a
        // PhotogrammetrySession until the ObjectCaptureSession is deallocated.
        var captureCompleted = false
        for await state in stateUpdates {
            if case .completed = state {
                captureCompleted = true
                break
            }
            if case .failed(let error) = state {
                session = nil
                phase = .failed(message: "Capture failed: \(error.localizedDescription)")
                return
            }
        }
        guard captureCompleted else { return }

        session = nil
        phase = .reconstructing(progress: 0)
        // Run reconstruction outside this view-bound task: clearing `session`
        // removes CaptureView, which cancels the .task that called us.
        reconstructionTask = Task { [weak self] in
            // Give the capture session a moment to fully tear down.
            try? await Task.sleep(for: .seconds(1))
            await self?.reconstruct()
        }
    }

    func cancelAndCleanUp() {
        session?.cancel()
        session = nil
        reconstructionTask?.cancel()
        reconstructionTask = nil
        photoSession?.cancel()
        photoSession = nil
        if let scanDirectory {
            try? FileManager.default.removeItem(at: scanDirectory)
        }
        scanDirectory = nil
    }

    func cancelReconstruction() {
        reconstructionTask?.cancel()
        if let photoSession {
            photoSession.cancel()
        } else {
            failReconstruction("Reconstruction was cancelled.")
        }
    }

    /// Re-runs reconstruction from the photos already on disk. Uses the same
    /// detached reconstructionTask pattern as the first attempt so it isn't
    /// tied to (or cancelled with) any view's .task.
    func retryReconstruction() {
        guard scanDirectory != nil, photoSession == nil else { return }
        reconstructionTask?.cancel()
        phase = .reconstructing(progress: 0)
        reconstructionTask = Task { [weak self] in
            await self?.reconstruct()
        }
    }

    private var hasCapturedImages: Bool {
        guard let scanDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                atPath: ScanStore.imagesDirectory(in: scanDirectory).path) else {
            return false
        }
        return !contents.isEmpty
    }

    private func failReconstruction(_ message: String) {
        phase = .failed(message: message, canRetry: hasCapturedImages)
    }

    private func reconstruct() async {
        guard let scanDirectory, !Task.isCancelled else { return }

        let modelURL = ScanStore.modelURL(in: scanDirectory)
        // A partial file from an earlier failed attempt must not pass the
        // "model exists" check below.
        try? FileManager.default.removeItem(at: modelURL)
        do {
            var configuration = PhotogrammetrySession.Configuration()
            // Reusing the capture checkpoints makes reconstruction much faster.
            configuration.checkpointDirectory = ScanStore.snapshotsDirectory(in: scanDirectory)
            let photoSession = try PhotogrammetrySession(
                input: ScanStore.imagesDirectory(in: scanDirectory),
                configuration: configuration)
            self.photoSession = photoSession

            // Only .reduced (and .preview) are available for on-device
            // reconstruction on iOS; .medium/.full/.raw are macOS-only.
            try photoSession.process(requests: [.modelFile(url: modelURL, detail: .reduced)])

            // PhotogrammetrySession still sends .processingComplete after a
            // .requestError, so remember the error rather than letting the
            // completion overwrite it with a success.
            var requestErrorMessage: String?
            for try await output in photoSession.outputs {
                switch output {
                case .requestProgress(_, let fractionComplete):
                    if requestErrorMessage == nil {
                        phase = .reconstructing(progress: fractionComplete)
                    }
                case .processingComplete:
                    if let requestErrorMessage {
                        failReconstruction("Reconstruction failed: \(requestErrorMessage)")
                    } else if FileManager.default.fileExists(atPath: modelURL.path) {
                        phase = .finished(modelURL: modelURL)
                    } else {
                        failReconstruction("Reconstruction finished but didn't produce a model file.")
                    }
                case .processingCancelled:
                    failReconstruction("Reconstruction was cancelled.")
                case .requestError(_, let error):
                    requestErrorMessage = error.localizedDescription
                    failReconstruction("Reconstruction failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
            if case .reconstructing = phase {
                failReconstruction("Reconstruction stopped before the model was finished.")
            }
        } catch {
            failReconstruction("Reconstruction failed: \(error.localizedDescription)")
        }
        photoSession = nil
    }
}

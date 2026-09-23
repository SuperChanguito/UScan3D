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

    /// Faces benefit from finer mesh detail than the default; .medium is the
    /// highest level PhotogrammetrySession reliably reconstructs on-device
    /// on iOS (.full and .raw target Mac-side reconstruction).
    var reconstructionDetail: PhotogrammetrySession.Request.Detail {
        self == .face ? .medium : .reduced
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
        case failed(message: String)
    }

    @Published var phase: Phase = .setup
    @Published private(set) var session: ObjectCaptureSession?
    private(set) var mode: ScanMode = .object

    private var scanDirectory: URL?
    private var photoSession: PhotogrammetrySession?
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
        guard !isObservingSession, let session else { return }
        isObservingSession = true
        for await state in session.stateUpdates {
            switch state {
            case .completed:
                self.session = nil
                await reconstruct()
            case .failed(let error):
                self.session = nil
                phase = .failed(message: "Capture failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        isObservingSession = false
    }

    func cancelAndCleanUp() {
        session?.cancel()
        session = nil
        photoSession?.cancel()
        photoSession = nil
        if let scanDirectory {
            try? FileManager.default.removeItem(at: scanDirectory)
        }
        scanDirectory = nil
    }

    func cancelReconstruction() {
        photoSession?.cancel()
    }

    private func reconstruct() async {
        guard let scanDirectory else { return }
        phase = .reconstructing(progress: 0)

        let modelURL = ScanStore.modelURL(in: scanDirectory)
        do {
            var configuration = PhotogrammetrySession.Configuration()
            // Reusing the capture checkpoints makes reconstruction much faster.
            configuration.checkpointDirectory = ScanStore.snapshotsDirectory(in: scanDirectory)
            let photoSession = try PhotogrammetrySession(
                input: ScanStore.imagesDirectory(in: scanDirectory),
                configuration: configuration)
            self.photoSession = photoSession

            try photoSession.process(requests: [.modelFile(url: modelURL, detail: mode.reconstructionDetail)])

            for try await output in photoSession.outputs {
                switch output {
                case .requestProgress(_, let fractionComplete):
                    phase = .reconstructing(progress: fractionComplete)
                case .processingComplete:
                    phase = .finished(modelURL: modelURL)
                case .processingCancelled:
                    phase = .failed(message: "Reconstruction was cancelled.")
                case .requestError(_, let error):
                    phase = .failed(message: "Reconstruction failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        } catch {
            phase = .failed(message: "Reconstruction failed: \(error.localizedDescription)")
        }
        photoSession = nil
    }
}

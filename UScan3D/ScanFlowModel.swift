import Foundation
import RealityKit
import SwiftUI

enum ScanMode: String, CaseIterable, Identifiable, Codable {
    case object = "Object"
    case face = "Face / Bust"
    case fullBody = "Full Body"

    var id: String { rawValue }

    var setupHint: String {
        switch self {
        case .object:
            return "Scan everyday objects for printing."
        case .face:
            return "Have your subject sit still and look forward. Orbit slowly around their head and shoulders."
        case .fullBody:
            return "You'll need a helper to hold the phone. Have your subject stand still with about 1 m of space all around them, arms slightly away from their body."
        }
    }

    /// Extra preparation advice shown on the setup screen.
    var setupTips: [String] {
        switch self {
        case .object, .face:
            return []
        case .fullBody:
            var tips = [
                "The subject holds still for the whole scan (2–4 minutes) while a helper walks around them.",
                "Arms slightly away from the body, feet shoulder-width apart, nothing touching them.",
                "Bright, even light — no window or lamp right behind them.",
                "Fitted, matte clothing with some pattern or texture scans best; plain dark or shiny clothes can lose tracking. Tie back long hair.",
            ]
            if !usesAreaMode {
                tips.append("On iOS 17 you'll need to stand 2–3 m back to fit them in the box. iOS 18 or later lets you scan from about 1 m.")
            }
            return tips
        }
    }

    /// Full Body skips the bounding box and uses Object Capture's area mode
    /// (iOS 18+): a box around a standing person only fits in frame from
    /// 2–3 m away, which is too far indoors.
    var usesAreaMode: Bool {
        if #available(iOS 18.0, *) {
            return self == .fullBody
        }
        return false
    }

    /// Shown before object detection (or area capture) starts.
    var readyInstruction: String {
        switch self {
        case .object:
            return "Point the camera at your object, then tap Continue."
        case .face:
            return "Have your subject sit still, then point the camera at their head and shoulders. Tap Continue."
        case .fullBody where usesAreaMode:
            return "Stand about 1 m from your subject. Tap Start Capture, then walk three slow loops around them: low (legs and feet), middle, then high (head and shoulders)."
        case .fullBody:
            return "Have your subject stand still, then point the camera at their whole body, head to feet. Tap Continue."
        }
    }

    var detectingInstruction: String {
        switch self {
        case .object, .face:
            return "Move closer or farther until the box hugs the object."
        case .fullBody:
            return "Step back until the box covers your subject from head to feet."
        }
    }

    func orbitInstruction(photos: Int) -> String {
        switch self {
        case .object:
            return "Orbit the object slowly — \(photos) photos so far."
        case .face:
            return "Orbit slowly around the head and shoulders — \(photos) photos so far."
        case .fullBody where usesAreaMode:
            return "Low loop, middle loop, then high loop, about 1 m away — \(photos) photos so far. Tap Finish after the third loop."
        case .fullBody:
            return "Walk slowly around your subject at chest height — \(photos) photos so far."
        }
    }

    var orbitCompleteInstruction: String {
        switch self {
        case .object:
            return "Orbit complete. Flip the object to capture its underside, keep scanning this side, or finish."
        case .face, .fullBody:
            return "Orbit complete. Keep scanning for more coverage, or finish."
        }
    }

    /// People can't be turned upside down.
    var allowsFlip: Bool { self == .object }
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

    /// Which photos a reconstruction uses.
    private enum ReconstructionInput {
        case allPhotos
        /// Only the photos taken before the first flip — recovers a scan
        /// ghosted by a misaligned flipped pass.
        case beforeFirstFlip
    }

    @Published var phase: Phase = .setup
    @Published private(set) var session: ObjectCaptureSession?
    /// True once a model has been built and its photos are still on disk,
    /// i.e. the user can still rebuild or approve it.
    @Published private(set) var hasKeptPhotos = false
    private(set) var mode: ScanMode = .object
    /// True once model.usdz exists for this scan, so a failed rebuild can
    /// fall back to it.
    private(set) var hasBuiltModel = false

    private var scanDirectory: URL?
    private var photoSession: PhotogrammetrySession?
    private var reconstructionTask: Task<Void, Never>?
    private var reconstructionInput: ReconstructionInput = .allPhotos
    private var passBoundaries = ScanStore.PassBoundaries()
    private var isObservingSession = false

    var canRebuildWithoutFlippedSide: Bool {
        (passBoundaries.shotsBeforeFirstFlip ?? 0) > 0
    }

    func startCapture(mode: ScanMode) {
        self.mode = mode
        do {
            let directory = try ScanStore.newScanDirectory()
            scanDirectory = directory
            ScanStore.saveInfo(.init(mode: mode, usedAreaMode: mode.usesAreaMode), in: directory)

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

    /// Call just before beginNewScanPass()/beginNewScanPassAfterFlip() so
    /// the photos can later be split by pass.
    func recordPassBoundary(flipped: Bool) {
        guard let scanDirectory, let session else { return }
        passBoundaries.boundaries.append(.init(shotCount: session.numberOfShotsTaken, flipped: flipped))
        ScanStore.savePassBoundaries(passBoundaries, in: scanDirectory)
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

    /// Re-runs the last reconstruction (same photos) from what's on disk.
    func retryReconstruction() {
        startReconstruction()
    }

    /// Rebuilds a finished model from its kept photos, replacing model.usdz
    /// only if the new build succeeds.
    func rebuild(withoutFlippedSide: Bool) {
        guard hasKeptPhotos else { return }
        reconstructionInput = withoutFlippedSide && canRebuildWithoutFlippedSide
            ? .beforeFirstFlip : .allPhotos
        startReconstruction()
    }

    /// After a failed or cancelled rebuild, go back to the model that was
    /// already built.
    func keepPreviousModel() {
        guard let scanDirectory, hasBuiltModel else { return }
        phase = .finished(modelURL: ScanStore.modelURL(in: scanDirectory))
    }

    /// The user approved the model: delete its photos and checkpoints.
    func freeUpSpace() {
        guard let scanDirectory, photoSession == nil else { return }
        hasKeptPhotos = false
        Task.detached(priority: .utility) {
            ScanStore.removeCaptureData(in: scanDirectory)
        }
    }

    /// Uses the same detached reconstructionTask pattern as the first
    /// attempt so it isn't tied to (or cancelled with) any view's .task.
    private func startReconstruction() {
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
        // Build into a separate file so a failed rebuild keeps the existing
        // model. A partial file from an earlier failed attempt must not pass
        // the "output exists" check below.
        let outputURL = ScanStore.pendingModelURL(in: scanDirectory)
        try? FileManager.default.removeItem(at: outputURL)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: ScanStore.firstPassImagesDirectory(in: scanDirectory))
        }
        do {
            var configuration = PhotogrammetrySession.Configuration()
            let input: URL
            if reconstructionInput == .beforeFirstFlip, let count = passBoundaries.shotsBeforeFirstFlip {
                input = try ScanStore.prepareFirstPassImages(in: scanDirectory, count: count)
                // The capture checkpoints were made from every pass, flipped
                // one included, so they can't be reused here.
            } else {
                input = ScanStore.imagesDirectory(in: scanDirectory)
                // Reusing the capture checkpoints makes reconstruction much faster.
                configuration.checkpointDirectory = ScanStore.snapshotsDirectory(in: scanDirectory)
            }
            let photoSession = try PhotogrammetrySession(input: input, configuration: configuration)
            self.photoSession = photoSession

            // Only .reduced (and .preview) are available for on-device
            // reconstruction on iOS; .medium/.full/.raw are macOS-only.
            try photoSession.process(requests: [.modelFile(url: outputURL, detail: .reduced)])

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
                    } else if FileManager.default.fileExists(atPath: outputURL.path) {
                        do {
                            try ScanStore.installPendingModel(in: scanDirectory)
                            hasBuiltModel = true
                            // Photos stay until the user approves the model
                            // (or they age out at launch after a week).
                            hasKeptPhotos = true
                            phase = .finished(modelURL: modelURL)
                        } catch {
                            failReconstruction("Couldn't save the model: \(error.localizedDescription)")
                        }
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

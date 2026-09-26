import Foundation

struct SavedScan: Identifiable {
    let id: String
    let directory: URL
    let modelURL: URL
    let createdAt: Date
    /// nil for scans made before scan.json existed.
    let info: ScanStore.ScanInfo?
}

/// Each scan lives in Documents/Scans/<UUID>/ with the captured photos,
/// reconstruction checkpoints, the scan's mode (scan.json), the pass
/// boundaries (passes.json), the finished model.usdz, and any exported STLs.
/// Photos and checkpoints are kept until the user approves the model, or
/// for at most a week.
enum ScanStore {

    /// What kind of scan this is, so a saved scan reopens with the right
    /// processing (e.g. cutting a Full Body scan out of its surroundings).
    struct ScanInfo: Codable {
        var mode: ScanMode
        /// Captured without a bounding box, so the model includes the floor
        /// and surroundings.
        var usedAreaMode: Bool
        /// Set on a Full Body scan whose head was replaced from this
        /// Face / Bust scan (its folder name). Such scans are already cut
        /// out and sealed, and are stored as model.obj.
        var faceDetailFrom: String? = nil
    }

    /// Where each extra capture pass began, so a rebuild can leave out the
    /// photos taken after the object was flipped.
    struct PassBoundaries: Codable {
        struct Boundary: Codable {
            /// session.numberOfShotsTaken when the pass began: photos
            /// 0..<shotCount came from earlier passes.
            let shotCount: Int
            let flipped: Bool
        }

        var boundaries: [Boundary] = []

        /// Number of photos taken before the first flip, if there was one.
        var shotsBeforeFirstFlip: Int? {
            boundaries.first(where: \.flipped)?.shotCount
        }
    }

    /// How long capture photos are kept for a scan the user never approved.
    static let captureDataLifetime: TimeInterval = 7 * 24 * 60 * 60

    private static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]

    static var scansRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
    }

    static func imagesDirectory(in scanDirectory: URL) -> URL {
        scanDirectory.appendingPathComponent("Images", isDirectory: true)
    }

    static func snapshotsDirectory(in scanDirectory: URL) -> URL {
        scanDirectory.appendingPathComponent("Snapshots", isDirectory: true)
    }

    static func modelURL(in scanDirectory: URL) -> URL {
        scanDirectory.appendingPathComponent("model.usdz")
    }

    /// Models the app builds itself (face detail) rather than reconstructs.
    static func objModelURL(in scanDirectory: URL) -> URL {
        scanDirectory.appendingPathComponent("model.obj")
    }

    /// The scan's model, whichever kind it has, or nil if it has none yet.
    static func existingModelURL(in scanDirectory: URL) -> URL? {
        [modelURL(in: scanDirectory), objModelURL(in: scanDirectory)]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Saves a mesh (Z-up, meters) as a new scan with its own folder.
    /// Written as OBJ, Y-up like the USDZ models, so the rest of the app
    /// loads it the same way.
    static func saveBuiltScan(_ triangles: [Triangle], info: ScanInfo) throws {
        let directory = scansRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mesh = MeshRepair.weld(triangles)
        var obj = "# U-Scan3D\n"
        obj.reserveCapacity(mesh.vertices.count * 40 + mesh.triangles.count * 30)
        for v in mesh.vertices {
            obj += "v \(v.x) \(v.z) \(-v.y)\n" // Z-up -> Y-up
        }
        for (a, b, c) in mesh.triangles {
            obj += "f \(a + 1) \(b + 1) \(c + 1)\n"
        }
        do {
            saveInfo(info, in: directory)
            try Data(obj.utf8).write(to: objModelURL(in: directory), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Reconstruction writes here first, so a failed or cancelled rebuild
    /// never destroys the existing model.usdz.
    static func pendingModelURL(in scanDirectory: URL) -> URL {
        scanDirectory.appendingPathComponent("model-building.usdz")
    }

    static func infoURL(in scanDirectory: URL) -> URL {
        scanDirectory.appendingPathComponent("scan.json")
    }

    static func saveInfo(_ info: ScanInfo, in scanDirectory: URL) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: infoURL(in: scanDirectory), options: .atomic)
    }

    static func loadInfo(in scanDirectory: URL) -> ScanInfo? {
        guard let data = try? Data(contentsOf: infoURL(in: scanDirectory)) else { return nil }
        return try? JSONDecoder().decode(ScanInfo.self, from: data)
    }

    static func passesURL(in scanDirectory: URL) -> URL {
        scanDirectory.appendingPathComponent("passes.json")
    }

    /// Temporary input folder for a rebuild without the flipped side.
    static func firstPassImagesDirectory(in scanDirectory: URL) -> URL {
        scanDirectory.appendingPathComponent("FirstPassImages", isDirectory: true)
    }

    static func newScanDirectory() throws -> URL {
        let directory = scansRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: imagesDirectory(in: directory), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: snapshotsDirectory(in: directory), withIntermediateDirectories: true)
        return directory
    }

    static func savedScans() -> [SavedScan] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: scansRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        return entries.compactMap { directory -> SavedScan? in
            guard let model = existingModelURL(in: directory) else { return nil }
            let created = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return SavedScan(
                id: directory.lastPathComponent,
                directory: directory,
                modelURL: model,
                createdAt: created,
                info: loadInfo(in: directory))
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ scan: SavedScan) {
        try? FileManager.default.removeItem(at: scan.directory)
    }

    static func savePassBoundaries(_ passes: PassBoundaries, in scanDirectory: URL) {
        guard let data = try? JSONEncoder().encode(passes) else { return }
        try? data.write(to: passesURL(in: scanDirectory), options: .atomic)
    }

    /// Moves a freshly reconstructed model into place as model.usdz,
    /// replacing any earlier build.
    static func installPendingModel(in scanDirectory: URL) throws {
        let fileManager = FileManager.default
        let model = modelURL(in: scanDirectory)
        let pending = pendingModelURL(in: scanDirectory)
        if fileManager.fileExists(atPath: model.path) {
            _ = try fileManager.replaceItemAt(model, withItemAt: pending)
        } else {
            try fileManager.moveItem(at: pending, to: model)
        }
    }

    /// Fills FirstPassImages with the first `count` captured photos (hard
    /// links, so no extra storage). ObjectCaptureSession numbers its photos
    /// sequentially, so name order is capture order.
    static func prepareFirstPassImages(in scanDirectory: URL, count: Int) throws -> URL {
        let fileManager = FileManager.default
        let destination = firstPassImagesDirectory(in: scanDirectory)
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let images = try fileManager.contentsOfDirectory(
            at: imagesDirectory(in: scanDirectory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for image in images.prefix(count) {
            let target = destination.appendingPathComponent(image.lastPathComponent)
            do {
                try fileManager.linkItem(at: image, to: target)
            } catch {
                try fileManager.copyItem(at: image, to: target)
            }
        }
        return destination
    }

    /// Deletes the captured photos, reconstruction checkpoints (often
    /// hundreds of MB) and the pass boundaries that describe them. Only call
    /// once the user has approved model.usdz (or it has aged out) — until
    /// then they're needed to retry or rebuild.
    static func removeCaptureData(in scanDirectory: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: imagesDirectory(in: scanDirectory))
        try? fileManager.removeItem(at: snapshotsDirectory(in: scanDirectory))
        try? fileManager.removeItem(at: firstPassImagesDirectory(in: scanDirectory))
        try? fileManager.removeItem(at: passesURL(in: scanDirectory))
    }

    /// Deletes capture data for built scans older than captureDataLifetime
    /// that the user never approved. Safe to run in the background: it only
    /// touches scans that already have a model.
    static func removeExpiredCaptureData() {
        let cutoff = Date().addingTimeInterval(-captureDataLifetime)
        for scan in savedScans() where scan.createdAt < cutoff {
            removeCaptureData(in: scan.directory)
        }
    }

    /// Deletes scan folders that never produced a model (the app was killed
    /// mid-scan, or a failed scan wasn't discarded). Call only at launch,
    /// never while a scan flow is open.
    static func purgeIncompleteScans() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: scansRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return
        }
        for directory in entries where existingModelURL(in: directory) == nil {
            try? fileManager.removeItem(at: directory)
        }
    }
}

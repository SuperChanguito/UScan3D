import Foundation

struct SavedScan: Identifiable {
    let id: String
    let directory: URL
    let modelURL: URL
    let createdAt: Date
}

/// Each scan lives in Documents/Scans/<UUID>/ with the captured photos,
/// reconstruction checkpoints, the finished model.usdz, and any exported STLs.
/// Photos and checkpoints are deleted once the model has been built.
enum ScanStore {

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
            let model = Self.modelURL(in: directory)
            guard fileManager.fileExists(atPath: model.path) else { return nil }
            let created = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return SavedScan(
                id: directory.lastPathComponent,
                directory: directory,
                modelURL: model,
                createdAt: created)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ scan: SavedScan) {
        try? FileManager.default.removeItem(at: scan.directory)
    }

    /// Deletes the captured photos and reconstruction checkpoints (often
    /// hundreds of MB). Only call once model.usdz has been verified — until
    /// then they're needed to retry reconstruction.
    static func removeCaptureData(in scanDirectory: URL) {
        try? FileManager.default.removeItem(at: imagesDirectory(in: scanDirectory))
        try? FileManager.default.removeItem(at: snapshotsDirectory(in: scanDirectory))
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
        for directory in entries where !fileManager.fileExists(atPath: modelURL(in: directory).path) {
            try? fileManager.removeItem(at: directory)
        }
    }
}

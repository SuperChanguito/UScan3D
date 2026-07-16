import Foundation

struct SavedScan: Identifiable {
    let id: String
    let directory: URL
    let modelURL: URL
    let createdAt: Date
}

/// Each scan lives in Documents/Scans/<UUID>/ with the captured photos,
/// reconstruction checkpoints, the finished model.usdz, and any exported STLs.
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
}

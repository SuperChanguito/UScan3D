import SceneKit
import SwiftUI
import simd

/// Interactive preview of the reconstructed model plus print-ready STL export.
/// The STL is written in millimeters, Z-up, centered on the plate origin.
enum ExportFormat: String, CaseIterable, Identifiable {
    case stl = "STL"
    case threeMF = "3MF"

    var id: String { rawValue }
    var fileExtension: String { self == .stl ? "stl" : "3mf" }
}

struct ModelPreviewView: View {
    let modelURL: URL
    /// nil for scans made before scan.json existed.
    var scanInfo: ScanStore.ScanInfo? = nil
    var onDone: (() -> Void)? = nil

    /// An area-mode Full Body scan: cut the person out of the floor and
    /// surroundings before anything else.
    private var isolatesPerson: Bool { scanInfo?.usedAreaMode ?? false }
    private var isFullBody: Bool { scanInfo?.mode == .fullBody }
    /// Figurine size: a person at real size would max out the 256 mm plate.
    private static let fullBodyPrintMM: Double = 150

    @State private var scene: SCNScene?
    /// The mesh that will be exported: repaired, and flat-base cut if on.
    @State private var triangles: [Triangle] = []
    /// The scan exactly as loaded from the file.
    @State private var loadedTriangles: [Triangle] = []
    /// The scan before any repair — the loaded mesh, or the person cut out
    /// of it. The flat-base cut is applied to this and then repaired once,
    /// so the hole count and validity always describe the export.
    @State private var rawTriangles: [Triangle] = []
    @State private var floorClearanceCM: Double = 2
    /// Half-width of the crop square in meters; the top of the range is off.
    @State private var cropHalfWidth: Double = ModelPreviewView.cropOff
    @State private var isIsolating = false
    @State private var isolationGeneration = 0
    @State private var personNotFound = false
    @State private var uncutRepair: MeshRepair.Result?
    @State private var nativeSize: SIMD3<Float>?
    /// Real-world size (mm) of `triangles` — after a flat-base cut the
    /// longest side (which print scaling uses) can change.
    @State private var exportMeshSize: SIMD3<Float>?
    @State private var holesFilled = 0
    @State private var meshIsValid = true
    @State private var isProcessingMesh = false
    /// Bumped on every flat-base change so a slow cut/repair finishing
    /// after the slider moved again is ignored.
    @State private var meshGeneration = 0
    @State private var showPrintPreview = false
    @State private var printPreviewScene: SCNScene?
    @State private var previewGeneration = 0
    @State private var flatBaseFraction: Double = 0
    @State private var targetLongestMM: Double = 100
    @State private var exportFormat: ExportFormat = .stl
    @State private var exportedFile: URL?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var printerSettings: PrinterSettings? = PrinterSettings.load()
    @State private var showingPrinterSettings = false
    @State private var isSendingToPrinter = false
    @State private var printerStatusMessage: String?
    /// Set when Send to Printer was tapped before the printer was set up;
    /// the upload continues once settings are saved.
    @State private var pendingUpload: URL?

    var body: some View {
        VStack(spacing: 0) {
            SceneView(scene: displayedScene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                .id(displayedScene.map { ObjectIdentifier($0) })
                .overlay {
                    if displayedScene == nil {
                        ProgressView(showPrintPreview ? "Building print preview…" : "Loading preview…")
                    }
                }
            exportPanel
        }
        .navigationTitle("Your Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingPrinterSettings = true
                } label: {
                    Image(systemName: "printer")
                }
            }
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingPrinterSettings, onDismiss: { pendingUpload = nil }) {
            PrinterSettingsView(current: printerSettings) { updated in
                printerSettings = updated
                if let pendingUpload {
                    self.pendingUpload = nil
                    sendToPrinter(pendingUpload, using: updated)
                }
            }
        }
        .alert(
            "Export Problem",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let nativeSize {
                Text(String(
                    format: "Scanned size: %.0f × %.0f × %.0f mm",
                    nativeSize.x, nativeSize.y, nativeSize.z))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isolatesPerson {
                isolationControls
            }

            if holesFilled > 0 {
                Label(
                    "Repaired \(holesFilled) hole\(holesFilled == 1 ? "" : "s") for a watertight print",
                    systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !meshIsValid {
                Label("The base may need repair in Bambu Studio", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Print size")
                Slider(value: $targetLongestMM, in: 10...256, step: 1) { editing in
                    exportedFile = nil
                    if !editing { refreshPrintPreview() }
                }
                Text("\(Int(targetLongestMM)) mm")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }

            Text("Longest side of the model. The Bambu X1 Carbon build plate is 256 mm.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if isFullBody && targetLongestMM < Self.fullBodyPrintMM {
                Label("Ankles, wrists and fingers may be too thin to print below \(Int(Self.fullBodyPrintMM)) mm — add supports in Bambu Studio or print larger.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Flat base")
                Slider(value: $flatBaseFraction, in: 0...0.15, step: 0.01) { editing in
                    if !editing { applyFlatBaseCut() }
                }
                Group {
                    if isProcessingMesh {
                        ProgressView()
                    } else {
                        Text(flatBaseFraction > 0 ? String(format: "%.1f mm", flatBaseCutMM) : "Off")
                    }
                }
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            }

            Text("Slices off the bottom of the scan so it sits flush on the plate (height at print size).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Print preview", isOn: $showPrintPreview)
                .onChange(of: showPrintPreview) { _, isOn in
                    if isOn { refreshPrintPreview() }
                }

            Picker("Format", selection: $exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: exportFormat) { _, _ in exportedFile = nil }

            if let exportedFile {
                ShareLink(item: exportedFile) {
                    Label("Share \(exportFormat.rawValue)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    exportModel()
                } label: {
                    if isExporting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Create \(exportFormat.rawValue) for printing", systemImage: "cube")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(triangles.isEmpty || isExporting || isProcessingMesh || isIsolating)
            }

            if let exportedFile {
                Button {
                    sendToPrinter(exportedFile)
                } label: {
                    if isSendingToPrinter {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Send to Printer (LAN)", systemImage: "wifi")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isSendingToPrinter)

                if let printerStatusMessage {
                    Text(printerStatusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private static let cropOff: Double = 1.5

    private var isolationSettings: PersonIsolator.Settings {
        PersonIsolator.Settings(
            floorClearance: Float(floorClearanceCM / 100),
            cropHalfWidth: cropHalfWidth >= Self.cropOff ? nil : Float(cropHalfWidth))
    }

    /// Full Body cut-out: how far above the floor to cut, and an optional
    /// square crop for anything touching the person.
    @ViewBuilder
    private var isolationControls: some View {
        if personNotFound {
            Label("Couldn't find a person to cut out — showing the whole scan", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack {
            Text("Floor cut")
            Slider(value: $floorClearanceCM, in: 0...10, step: 0.5) { editing in
                if !editing { applyIsolation() }
            }
            Group {
                if isIsolating {
                    ProgressView()
                } else {
                    Text(String(format: "%.1f cm", floorClearanceCM))
                }
            }
            .monospacedDigit()
            .frame(width: 64, alignment: .trailing)
        }

        HStack {
            Text("Crop")
            Slider(value: $cropHalfWidth, in: 0.2...Self.cropOff, step: 0.05) { editing in
                if !editing { applyIsolation() }
            }
            Text(cropHalfWidth >= Self.cropOff ? "Off" : "\(Int((cropHalfWidth * 200).rounded())) cm")
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }

        Text("The person is cut out of the floor and surroundings automatically. Raise Floor cut if bits of floor stay on the feet; narrow Crop (width of a square around them) if something touching them is kept.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    /// Re-runs the cut-out with the current settings, then re-applies the
    /// flat base on top of it.
    private func applyIsolation() {
        guard isolatesPerson, !loadedTriangles.isEmpty else { return }
        exportedFile = nil
        isolationGeneration += 1
        let generation = isolationGeneration
        isIsolating = true
        let loaded = loadedTriangles
        let settings = isolationSettings
        Task {
            let (isolated, repaired) = await Task.detached(priority: .userInitiated) {
                let isolated = PersonIsolator.isolate(loaded, settings: settings)
                return (isolated, MeshRepair.repair(isolated.triangles))
            }.value
            // A slider moved again while this ran; a newer result is coming.
            guard generation == isolationGeneration else { return }
            isIsolating = false
            personNotFound = !isolated.personFound
            rawTriangles = isolated.triangles
            uncutRepair = repaired
            nativeSize = STLExporter.sizeMM(of: repaired.triangles)
            applyFlatBaseCut()
        }
    }

    private var displayedScene: SCNScene? {
        showPrintPreview ? printPreviewScene : scene
    }

    /// How much the flat base removes, in millimeters on the print:
    /// fraction × scanned height × print scale. The scale comes from the
    /// exported (cut) mesh's longest side, which is what export uses.
    private var flatBaseCutMM: Double {
        guard let nativeSize, let exportMeshSize else { return 0 }
        let exportLongest = Double(max(exportMeshSize.x, max(exportMeshSize.y, exportMeshSize.z)))
        guard exportLongest > 0 else { return 0 }
        return flatBaseFraction * Double(nativeSize.z) * (targetLongestMM / exportLongest)
    }

    private func applyFlatBaseCut() {
        exportedFile = nil
        meshGeneration += 1
        let generation = meshGeneration
        guard flatBaseFraction > 0, !rawTriangles.isEmpty else {
            isProcessingMesh = false
            if let uncutRepair { show(uncutRepair) }
            return
        }

        isProcessingMesh = true
        let raw = rawTriangles
        let fraction = flatBaseFraction
        Task {
            let repaired = await Task.detached(priority: .userInitiated) {
                MeshRepair.repair(MeshCutter.cutFlatBase(raw, fraction: fraction))
            }.value
            // The slider moved again while this ran; a newer result is coming.
            guard generation == meshGeneration else { return }
            isProcessingMesh = false
            show(repaired)
        }
    }

    private func show(_ repair: MeshRepair.Result) {
        triangles = repair.triangles
        holesFilled = repair.holesFilled
        meshIsValid = repair.isValid
        exportMeshSize = STLExporter.sizeMM(of: repair.triangles)
        refreshPrintPreview()
    }

    /// Rebuilds the print preview from the export mesh at print scale.
    private func refreshPrintPreview() {
        guard showPrintPreview, !triangles.isEmpty else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let source = triangles
        let sizeMM = Float(targetLongestMM)
        printPreviewScene = nil
        Task {
            let buffers = await Task.detached(priority: .userInitiated) {
                PrintPreview.buffers(for: source, longestSideMM: sizeMM)
            }.value
            guard generation == previewGeneration, let buffers else { return }
            printPreviewScene = PrintPreview.scene(from: buffers)
        }
    }

    private func sendToPrinter(_ fileURL: URL, using savedSettings: PrinterSettings? = nil) {
        printerStatusMessage = nil
        guard let printerSettings = savedSettings ?? printerSettings else {
            pendingUpload = fileURL
            showingPrinterSettings = true
            return
        }
        isSendingToPrinter = true
        Task {
            do {
                try await BambuPrinterUploader.upload(fileURL: fileURL, to: printerSettings)
                await MainActor.run {
                    isSendingToPrinter = false
                    printerStatusMessage = "Sent. It's staged on the printer's storage — slice it in Bambu Studio to make it printable."
                }
            } catch {
                await MainActor.run {
                    isSendingToPrinter = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func load() async {
        let url = modelURL
        scene = try? SCNScene(url: url, options: nil)
        // The photo view shows the whole capture, floor and all; start on
        // the print view, which shows the cut-out person.
        if isolatesPerson { showPrintPreview = true }
        let isolation = isolatesPerson ? isolationSettings : nil
        if isolatesPerson { isIsolating = true }
        do {
            let (loaded, isolated, repaired) = try await Task.detached(priority: .userInitiated) {
                let loaded = try STLExporter.loadTriangles(from: url)
                let isolated = isolation.map { PersonIsolator.isolate(loaded, settings: $0) }
                return (loaded, isolated, MeshRepair.repair(isolated?.triangles ?? loaded))
            }.value
            isIsolating = false
            loadedTriangles = loaded
            personNotFound = isolated.map { !$0.personFound } ?? false
            rawTriangles = isolated?.triangles ?? loaded
            uncutRepair = repaired

            let size = STLExporter.sizeMM(of: repaired.triangles)
            nativeSize = size
            let longest = Double(max(size.x, max(size.y, size.z)))
            if isFullBody {
                targetLongestMM = Self.fullBodyPrintMM
            } else if longest.isFinite, longest > 0 {
                targetLongestMM = min(max(longest.rounded(), 10), 256)
            }
            // Box-mode Full Body scans stand on rough, uneven feet; a slight
            // flat base lets them stand. Area-mode scans already have one
            // from the floor cut.
            if isFullBody && !isolatesPerson {
                flatBaseFraction = 0.01
                applyFlatBaseCut()
            } else {
                show(repaired)
            }
        } catch {
            errorMessage = "Couldn't read the model for export: \(error.localizedDescription)"
        }
    }

    /// e.g. U-Scan3D-20260923-1430-100mm.stl, named from the scan's
    /// creation date, with -2, -3… appended rather than overwriting an
    /// earlier export (here or on the printer's storage).
    private func exportURL(sizeMM: Int, fileExtension: String) -> URL {
        let scanDirectory = modelURL.deletingLastPathComponent()
        let scanDate = (try? scanDirectory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let baseName = "U-Scan3D-\(formatter.string(from: scanDate))-\(sizeMM)mm"

        var candidate = scanDirectory.appendingPathComponent("\(baseName).\(fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = scanDirectory.appendingPathComponent("\(baseName)-\(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }

    private func exportModel() {
        isExporting = true
        let trianglesToExport = triangles
        let sizeMM = Float(targetLongestMM)
        let format = exportFormat
        let outputURL = exportURL(sizeMM: Int(targetLongestMM), fileExtension: format.fileExtension)

        Task.detached(priority: .userInitiated) {
            do {
                switch format {
                case .stl:
                    try STLExporter.writeBinarySTL(trianglesToExport, to: outputURL, longestSideMM: sizeMM)
                case .threeMF:
                    try ThreeMFExporter.write3MF(trianglesToExport, to: outputURL, longestSideMM: sizeMM)
                }
                await MainActor.run {
                    exportedFile = outputURL
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "\(format.rawValue) export failed: \(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }
}

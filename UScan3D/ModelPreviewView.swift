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
    var onDone: (() -> Void)? = nil

    @State private var scene: SCNScene?
    /// The mesh that will be exported: repaired, and flat-base cut if on.
    @State private var triangles: [Triangle] = []
    /// The scan exactly as loaded, before any repair. The flat-base cut is
    /// applied to this and then repaired once, so the hole count and
    /// validity always describe the export.
    @State private var rawTriangles: [Triangle] = []
    @State private var uncutRepair: MeshRepair.Result?
    @State private var nativeSize: SIMD3<Float>?
    @State private var holesFilled = 0
    @State private var meshIsValid = true
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

    var body: some View {
        VStack(spacing: 0) {
            SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                .overlay {
                    if scene == nil {
                        ProgressView("Loading preview…")
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
        .sheet(isPresented: $showingPrinterSettings) {
            PrinterSettingsView(current: printerSettings) { updated in
                printerSettings = updated
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
                Slider(value: $targetLongestMM, in: 10...256, step: 1) { _ in
                    exportedFile = nil
                }
                Text("\(Int(targetLongestMM)) mm")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }

            Text("Longest side of the model. The Bambu X1 Carbon build plate is 256 mm.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Text("Flat base")
                Slider(value: $flatBaseFraction, in: 0...0.15, step: 0.01) { editing in
                    if !editing { applyFlatBaseCut() }
                }
                Text(flatBaseFraction > 0 ? "\(Int(flatBaseCutMM.rounded())) mm" : "Off")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }

            Text("Slices off the bottom of the scan so it sits flush on the plate.")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
                .disabled(triangles.isEmpty || isExporting)
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

    private var flatBaseCutMM: Double {
        flatBaseFraction * Double(nativeSize?.z ?? 0)
    }

    private func applyFlatBaseCut() {
        exportedFile = nil
        guard flatBaseFraction > 0, !rawTriangles.isEmpty else {
            if let uncutRepair { show(uncutRepair) }
            return
        }
        let cut = MeshCutter.cutFlatBase(rawTriangles, fraction: flatBaseFraction)
        show(MeshRepair.repair(cut))
    }

    private func show(_ repair: MeshRepair.Result) {
        triangles = repair.triangles
        holesFilled = repair.holesFilled
        meshIsValid = repair.isValid
    }

    private func sendToPrinter(_ fileURL: URL) {
        printerStatusMessage = nil
        guard let printerSettings else {
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
        do {
            let (loaded, repaired) = try await Task.detached(priority: .userInitiated) {
                let loaded = try STLExporter.loadTriangles(from: url)
                return (loaded, MeshRepair.repair(loaded))
            }.value
            rawTriangles = loaded
            uncutRepair = repaired
            show(repaired)

            let size = STLExporter.sizeMM(of: repaired.triangles)
            nativeSize = size
            let longest = Double(max(size.x, max(size.y, size.z)))
            if longest.isFinite, longest > 0 {
                targetLongestMM = min(max(longest.rounded(), 10), 256)
            }
        } catch {
            errorMessage = "Couldn't read the model for export: \(error.localizedDescription)"
        }
    }

    private func exportModel() {
        isExporting = true
        let trianglesToExport = triangles
        let sizeMM = Float(targetLongestMM)
        let format = exportFormat
        let outputURL = modelURL.deletingLastPathComponent()
            .appendingPathComponent("U-Scan3D-\(Int(targetLongestMM))mm.\(format.fileExtension)")

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

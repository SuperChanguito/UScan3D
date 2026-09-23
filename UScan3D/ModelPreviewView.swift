import SceneKit
import SwiftUI
import simd

/// Interactive preview of the reconstructed model plus print-ready STL export.
/// The STL is written in millimeters, Z-up, centered on the plate origin.
struct ModelPreviewView: View {
    let modelURL: URL
    var onDone: (() -> Void)? = nil

    @State private var scene: SCNScene?
    @State private var triangles: [Triangle] = []
    @State private var nativeSize: SIMD3<Float>?
    @State private var holesFilled = 0
    @State private var targetLongestMM: Double = 100
    @State private var exportedSTL: URL?
    @State private var isExporting = false
    @State private var errorMessage: String?

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
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .task { await load() }
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

            HStack {
                Text("Print size")
                Slider(value: $targetLongestMM, in: 10...256, step: 1) { _ in
                    exportedSTL = nil
                }
                Text("\(Int(targetLongestMM)) mm")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }

            Text("Longest side of the model. The Bambu X1 Carbon build plate is 256 mm.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let exportedSTL {
                ShareLink(item: exportedSTL) {
                    Label("Share STL", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    exportSTL()
                } label: {
                    if isExporting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Create STL for printing", systemImage: "cube")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(triangles.isEmpty || isExporting)
            }
        }
        .padding()
        .background(.bar)
    }

    private func load() async {
        let url = modelURL
        scene = try? SCNScene(url: url, options: nil)
        do {
            let repaired = try await Task.detached(priority: .userInitiated) {
                let loaded = try STLExporter.loadTriangles(from: url)
                return MeshRepair.repair(loaded)
            }.value
            triangles = repaired.triangles
            holesFilled = repaired.holesFilled

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

    private func exportSTL() {
        isExporting = true
        let trianglesToExport = triangles
        let sizeMM = Float(targetLongestMM)
        let outputURL = modelURL.deletingLastPathComponent()
            .appendingPathComponent("U-Scan3D-\(Int(targetLongestMM))mm.stl")

        Task.detached(priority: .userInitiated) {
            do {
                try STLExporter.writeBinarySTL(trianglesToExport, to: outputURL, longestSideMM: sizeMM)
                await MainActor.run {
                    exportedSTL = outputURL
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "STL export failed: \(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }
}

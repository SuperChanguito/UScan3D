import SceneKit
import SwiftUI
import UIKit
import simd

/// Replaces a Full Body scan's head with the head from a Face / Bust scan
/// of the same person: choose the bust, tap the same three points on each,
/// check the fit, and save the result as a new scan.
struct FaceDetailView: View {
    /// The Full Body scan, already cut out (Z-up, meters).
    let bodyTriangles: [Triangle]
    let onSaved: () -> Void

    private enum Stage {
        case chooseBust
        case loadingBust
        case pickBody
        case pickBust
        case fitting
        case result(HeadSwap.Result)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .chooseBust
    @State private var busts: [SavedScan] = []
    @State private var bust: SavedScan?
    @State private var bustTriangles: [Triangle] = []
    /// The top of the body, shown for tapping its landmarks.
    @State private var bodyHead: [Triangle] = []
    @State private var bodyPoints: [SIMD3<Float>] = []
    @State private var bustPoints: [SIMD3<Float>] = []
    @State private var resultScene: SCNScene?
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add Face Detail")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .onAppear {
            busts = ScanStore.savedScans().filter { $0.info?.mode == .face }
            bodyHead = headAndShoulders(of: bodyTriangles)
        }
        .alert(
            "Face Detail Problem",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .chooseBust:
            chooseBustView

        case .loadingBust:
            ProgressView("Loading the face scan…")

        case .pickBody:
            PointPickingStep(
                title: "Full Body scan",
                triangles: bodyHead,
                points: $bodyPoints,
                nextTitle: "Next"
            ) {
                stage = .pickBust
            }

        case .pickBust:
            PointPickingStep(
                title: "Face / Bust scan",
                triangles: bustTriangles,
                points: $bustPoints,
                nextTitle: "Fit"
            ) {
                fit()
            }

        case .fitting:
            ProgressView("Fitting the face scan to the body…")

        case .result(let result):
            resultView(result)

        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Redo Points") { redoPoints() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var chooseBustView: some View {
        Group {
            if busts.isEmpty {
                ContentUnavailableView {
                    Label("No Face / Bust scans", systemImage: "face.smiling")
                } description: {
                    Text("Scan the same person in Face / Bust mode first — same hair, same clothes, head held the same way — then come back here.")
                }
            } else {
                List {
                    Section {
                        ForEach(busts) { scan in
                            Button {
                                load(scan)
                            } label: {
                                Text(scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    } header: {
                        Text("Choose a Face / Bust scan of the same person")
                    } footer: {
                        Text("Its head replaces this scan's head. The result is saved as a new scan; both originals are kept.")
                    }
                }
            }
        }
    }

    private func resultView(_ result: HeadSwap.Result) -> some View {
        VStack(spacing: 0) {
            SceneView(scene: resultScene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
            VStack(alignment: .leading, spacing: 12) {
                let gapMM = result.fitError * 1000
                Label(
                    String(format: "Average gap between the two heads: %.1f mm", gapMM),
                    systemImage: gapMM <= 4 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(gapMM <= 4 ? .green : .orange)
                Text(gapMM <= 4
                    ? "The face scan (orange) lines up with the body. Rotate to check the neck from every side."
                    : "The fit looks off. Check the orange head sits where the body's head was; if not, redo the points — make sure left and right ears aren't swapped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !result.body.isValid || !result.head.isValid {
                    Label("One piece may need repair in Bambu Studio", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    Button("Redo Points") { redoPoints() }
                        .buttonStyle(.bordered)
                    Button {
                        save(result)
                    } label: {
                        if isSaving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Save as New Scan").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
            }
            .padding()
            .background(.bar)
        }
    }

    /// Only the top of the body, so the head is big enough to tap on. The
    /// coordinates are unchanged, so the tapped points are body coordinates.
    private func headAndShoulders(of triangles: [Triangle]) -> [Triangle] {
        let top = triangles.reduce(-Float.greatestFiniteMagnitude) { max($0, $1.a.z, $1.b.z, $1.c.z) }
        let cutoff = top - 0.45
        return triangles.filter { max($0.a.z, $0.b.z, $0.c.z) > cutoff }
    }

    private func load(_ scan: SavedScan) {
        bust = scan
        stage = .loadingBust
        Task {
            do {
                let triangles = try await Task.detached(priority: .userInitiated) {
                    try STLExporter.loadTriangles(from: scan.modelURL)
                }.value
                bustTriangles = triangles
                stage = .pickBody
            } catch {
                stage = .chooseBust
                saveError = "Couldn't read that face scan: \(error.localizedDescription)"
            }
        }
    }

    private func redoPoints() {
        bodyPoints = []
        bustPoints = []
        resultScene = nil
        stage = .pickBody
    }

    private func fit() {
        guard bodyPoints.count == 3, bustPoints.count == 3 else { return }
        stage = .fitting
        let body = bodyTriangles
        let bust = bustTriangles
        let bodyLandmarks = HeadSwap.Landmarks(nose: bodyPoints[0], leftEar: bodyPoints[1], rightEar: bodyPoints[2])
        let bustLandmarks = HeadSwap.Landmarks(nose: bustPoints[0], leftEar: bustPoints[1], rightEar: bustPoints[2])
        Task {
            let output = await Task.detached(priority: .userInitiated) { () -> (HeadSwap.Result, PrintPreview.Buffers, PrintPreview.Buffers)? in
                guard let result = HeadSwap.combine(
                    body: body, bodyLandmarks: bodyLandmarks, bust: bust, bustLandmarks: bustLandmarks) else {
                    return nil
                }
                return (result,
                        PrintPreview.flatShaded(result.body.triangles),
                        PrintPreview.flatShaded(result.head.triangles))
            }.value
            guard let (result, bodyBuffers, headBuffers) = output else {
                stage = .failed("Couldn't fit the two scans. Check you tapped the nose and both ears on each, then try again.")
                return
            }
            let scene = SCNScene()
            scene.rootNode.addChildNode(PrintPreview.node(from: bodyBuffers))
            scene.rootNode.addChildNode(PrintPreview.node(from: headBuffers, color: .systemOrange))
            resultScene = scene
            stage = .result(result)
        }
    }

    private func save(_ result: HeadSwap.Result) {
        isSaving = true
        let info = ScanStore.ScanInfo(mode: .fullBody, usedAreaMode: false, faceDetailFrom: bust?.id)
        let triangles = result.triangles
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ScanStore.saveBuiltScan(triangles, info: info)
                }.value
                isSaving = false
                onSaved()
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

/// One scan to tap three landmarks on, with instructions and Undo.
private struct PointPickingStep: View {
    let title: String
    let triangles: [Triangle]
    @Binding var points: [SIMD3<Float>]
    let nextTitle: String
    let onNext: () -> Void

    private static let prompts = [
        "Tap the tip of the nose.",
        "Tap their LEFT ear (on your right when you face them).",
        "Tap their RIGHT ear.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            PointPickerView(triangles: triangles, points: $points)
            VStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                Text(points.count < 3
                    ? Self.prompts[points.count]
                    : "All three points placed. Tap \(nextTitle).")
                    .multilineTextAlignment(.center)
                Text("Pinch and drag to zoom in on the head. Red = nose, blue = left ear, green = right ear.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Undo") { points.removeLast() }
                        .buttonStyle(.bordered)
                        .disabled(points.isEmpty)
                    Button(nextTitle, action: onNext)
                        .buttonStyle(.borderedProminent)
                        .disabled(points.count < 3)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

/// A SceneKit view of a mesh where each tap drops a marker on the surface
/// (up to three), reporting points in the mesh's own coordinates.
struct PointPickerView: UIViewRepresentable {
    let triangles: [Triangle]
    @Binding var points: [SIMD3<Float>]

    static let markerColors: [UIColor] = [.systemRed, .systemBlue, .systemGreen]

    func makeCoordinator() -> Coordinator { Coordinator(points: $points) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let model = PrintPreview.node(from: PrintPreview.flatShaded(triangles))
        model.geometry?.firstMaterial?.isDoubleSided = true
        let scene = SCNScene()
        scene.rootNode.addChildNode(model)
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .secondarySystemBackground
        context.coordinator.model = model
        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.points = $points
        context.coordinator.syncMarkers(points)
    }

    final class Coordinator: NSObject {
        var points: Binding<[SIMD3<Float>]>
        weak var model: SCNNode?
        private var markers: [SCNNode] = []

        init(points: Binding<[SIMD3<Float>]>) {
            self.points = points
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard points.wrappedValue.count < 3,
                  let view = gesture.view as? SCNView,
                  let model else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [
                // All hits, nearest first: a marker in front mustn't swallow the tap.
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .backFaceCulling: false,
            ])
            guard let hit = hits.first(where: { $0.node === model }) else { return }
            let local = hit.localCoordinates
            points.wrappedValue.append(SIMD3<Float>(local.x, local.y, local.z))
        }

        func syncMarkers(_ points: [SIMD3<Float>]) {
            guard let model else { return }
            markers.forEach { $0.removeFromParentNode() }
            markers = points.enumerated().map { index, point in
                let sphere = SCNSphere(radius: 0.008)
                sphere.firstMaterial?.diffuse.contents = PointPickerView.markerColors[index % 3]
                sphere.firstMaterial?.readsFromDepthBuffer = false
                let node = SCNNode(geometry: sphere)
                node.position = SCNVector3(point.x, point.y, point.z)
                node.renderingOrder = 1
                model.addChildNode(node)
                return node
            }
        }
    }
}

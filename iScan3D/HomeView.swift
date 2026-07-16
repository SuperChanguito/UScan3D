import RealityKit
import SwiftUI

struct HomeView: View {
    @State private var scans: [SavedScan] = []
    @State private var showingScanFlow = false

    var body: some View {
        NavigationStack {
            Group {
                if scans.isEmpty {
                    ContentUnavailableView {
                        Label("No scans yet", systemImage: "cube.transparent")
                    } description: {
                        Text(ObjectCaptureSession.isSupported
                            ? "Tap + to scan your first object."
                            : "This device doesn't support Object Capture. iScan3D needs an iPhone Pro with LiDAR.")
                    }
                } else {
                    List {
                        ForEach(scans) { scan in
                            NavigationLink {
                                ModelPreviewView(modelURL: scan.modelURL)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    Text("Preview & export")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("iScan3D")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingScanFlow = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!ObjectCaptureSession.isSupported)
                }
            }
            .fullScreenCover(isPresented: $showingScanFlow) {
                ScanFlowView()
            }
            .onAppear { refresh() }
            .onChange(of: showingScanFlow) { _, isShowing in
                if !isShowing { refresh() }
            }
        }
    }

    private func refresh() {
        scans = ScanStore.savedScans()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            ScanStore.delete(scans[index])
        }
        refresh()
    }
}

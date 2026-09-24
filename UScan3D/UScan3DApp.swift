import SwiftUI

@main
struct UScan3DApp: App {
    init() {
        // No scan flow can be open yet, so any folder without a model is
        // leftover from an interrupted or abandoned scan.
        ScanStore.purgeIncompleteScans()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

import SwiftUI

@main
struct LiftPodApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CaptureModel()

    var body: some Scene {
        WindowGroup {
            WorkoutView(capture: model)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            Task { await model.applicationDidBecomeInactive() }
        }
    }
}

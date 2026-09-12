import SwiftUI

@main
struct LiftPodApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CaptureModel()
    @State private var lifecycleTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            WorkoutView(capture: model)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Scene callbacks may arrive while the previous transition awaits
            // journal I/O. Preserve their order so a late stop cannot undo resume.
            let preceding = lifecycleTask
            lifecycleTask = Task {
                await preceding?.value
                if newPhase == .active { await model.applicationDidBecomeActive() }
                else { await model.applicationDidBecomeInactive() }
            }
        }
    }
}

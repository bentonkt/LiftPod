import Combine
import Foundation

@MainActor
final class AutoWorkoutModel: ObservableObject {
    @Published private(set) var snapshot = AutoWorkoutSnapshot()
    @Published private(set) var exportURLs: [URL] = []
    @Published private(set) var error: String?

    func apply(snapshot: AutoWorkoutSnapshot) {
        self.snapshot = snapshot
        error = nil
    }

    func setExports(_ urls: [URL]) {
        exportURLs = urls
    }

    func report(error: String) {
        self.error = error
    }
}

import Combine
import Foundation

@MainActor
final class ExperimentalV1Model: ObservableObject {
    enum State: String { case idle = "Select a recording", ready = "Ready", running = "Running", complete = "Complete", failed = "Failed" }

    @Published private(set) var state: State = .idle
    @Published private(set) var sourceFilename: String?
    @Published private(set) var result: ExperimentalAnalysisResult?
    @Published private(set) var exportURLs: ExperimentalExportURLs?
    @Published private(set) var latestError: String?
    @Published var selectedExercise: ExperimentalExercise = .bicepsCurl { didSet { resetAnalysis() } }
    @Published var expectedSensorSide: ExperimentalSensorSide = .right { didSet { resetAnalysis() } }

    private var samples: [RawMotionSample] = []
    private let decoder = RawMotionCSVDecoder()
    private let service: ExperimentalV1ProcessingService

    init(service: ExperimentalV1ProcessingService = ExperimentalV1ProcessingService()) {
        self.service = service
    }

    func importRawCSV(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        do {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            samples = try decoder.decode(data: data)
            sourceFilename = url.lastPathComponent
            latestError = nil
            result = nil
            exportURLs = nil
            state = .ready
        } catch {
            samples = []
            sourceFilename = nil
            fail("Could not import V1 recording: \(error.localizedDescription)")
        }
    }

    func handleImportFailure(_ error: Error) { fail("Could not select V1 recording: \(error.localizedDescription)") }

    func run() async {
        guard !samples.isEmpty, let sourceFilename else {
            fail("Select a valid raw CSV before running Experimental V1 detection.")
            return
        }
        state = .running; latestError = nil; result = nil; exportURLs = nil
        let firstTimestamp = samples[0].sourceTimestamp
        let selection = StableExerciseSelection(epoch: 0, selectedProfile: selectedExercise,
                                                supportStartTimestamp: firstTimestamp,
                                                effectiveFromTimestamp: firstTimestamp,
                                                decisionTimestamp: firstTimestamp,
                                                confidence: nil, reason: .manualSelection)
        let input = ExperimentalProcessorInput(samples: samples, sourceFilename: sourceFilename,
                                               selection: selection, expectedSensorSide: expectedSensorSide,
                                               configuration: ExperimentalV1Configuration())
        do {
            let (output, urls) = try await service.run(input)
            result = output.summary
            exportURLs = urls
            state = .complete
        } catch {
            fail("Experimental V1 analysis failed: \(error.localizedDescription)")
        }
    }

    private func resetAnalysis() {
        result = nil; exportURLs = nil; latestError = nil
        state = samples.isEmpty ? .idle : .ready
    }

    private func fail(_ message: String) {
        result = nil; exportURLs = nil; latestError = message; state = .failed
    }
}

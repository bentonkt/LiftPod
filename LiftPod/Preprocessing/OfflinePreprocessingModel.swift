import Combine
import Foundation

@MainActor
final class OfflinePreprocessingModel: ObservableObject {
    enum State: String, Sendable {
        case idle = "Ready"
        case importing = "Importing raw CSV"
        case processing = "Processing"
        case succeeded = "Processing complete"
        case failed = "Processing failed"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var importedSampleCount = 0
    @Published private(set) var result: PreprocessingResult?
    @Published private(set) var processedCSVURL: URL?
    @Published private(set) var latestError: String?

    private let configuration: PreprocessingConfiguration
    private let decoder: RawMotionCSVDecoder
    private let engine: MotionPreprocessingEngine
    private let exporter: ProcessedMotionCSVExporter

    init(
        configuration: PreprocessingConfiguration = PreprocessingConfiguration(),
        decoder: RawMotionCSVDecoder = RawMotionCSVDecoder(),
        engine: MotionPreprocessingEngine = MotionPreprocessingEngine(),
        exporter: ProcessedMotionCSVExporter = ProcessedMotionCSVExporter()
    ) {
        self.configuration = configuration
        self.decoder = decoder
        self.engine = engine
        self.exporter = exporter
    }

    func processImportedFile(_ url: URL) async {
        state = .importing
        importedSampleCount = 0
        result = nil
        processedCSVURL = nil
        latestError = nil

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        let data: Data
        do {
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            fail("Could not read the imported CSV: \(error.localizedDescription)")
            return
        }

        let samples: [RawMotionSample]
        do {
            samples = try decoder.decode(data: data)
        } catch {
            fail(error.localizedDescription)
            return
        }
        importedSampleCount = samples.count
        state = .processing

        let processed: PreprocessingResult
        do {
            processed = try engine.process(samples: samples, configuration: configuration)
        } catch {
            fail(error.localizedDescription)
            return
        }

        do {
            processedCSVURL = try await exporter.export(processed)
            result = processed
            state = .succeeded
        } catch {
            fail("Could not write the processed CSV: \(error.localizedDescription)")
        }
    }

    func handleImportFailure(_ error: Error) {
        fail("Could not import the raw CSV: \(error.localizedDescription)")
    }

    private func fail(_ message: String) {
        result = nil
        processedCSVURL = nil
        latestError = message
        state = .failed
    }
}

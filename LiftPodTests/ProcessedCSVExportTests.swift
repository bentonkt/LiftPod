import Foundation
import XCTest
@testable import LiftPod

final class ProcessedCSVExportTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testProcessedCSVHeaderRowCountAndRoundTripPrecision() throws {
        let result = try MotionPreprocessingEngine().process(samples: makeStationarySamples())
        let data = ProcessedMotionCSVEncoder().encode(result)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let records = try StrictCSVParser().parse(text)

        XCTAssertEqual(records[0].fields.joined(separator: ","), ProcessedMotionCSVEncoder.header)
        XCTAssertEqual(records.count - 1, result.frames.count)
        XCTAssertEqual(records[1].fields.count, 10)

        let firstFrame = result.frames[0]
        XCTAssertEqual(Double(records[1].fields[1]), firstFrame.sourceTimestamp)
        XCTAssertEqual(Double(records[1].fields[4]), firstFrame.gravityMagnitudeG)
        XCTAssertEqual(Double(records[1].fields[6]), firstFrame.verticalAccelerationRawMetersPerSecondSquared)
        XCTAssertEqual(Double(records[1].fields[7]), firstFrame.verticalAccelerationCorrectedMetersPerSecondSquared)
        XCTAssertEqual(Double(records[1].fields[8]), firstFrame.verticalAccelerationFilteredMetersPerSecondSquared)
        XCTAssertEqual(records[1].fields[9], "true")
    }

    func testSuccessfulExportPublishesOnlyFinalCSV() async throws {
        let result = try MotionPreprocessingEngine().process(samples: makeStationarySamples())
        let exporter = ProcessedMotionCSVExporter(directory: temporaryDirectory)
        let url = try await exporter.export(result)
        let files = try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)

        XCTAssertEqual(url.pathExtension, "csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(files.filter { $0.pathExtension == "csv" }.count, 1)
        XCTAssertTrue(files.filter { $0.pathExtension == "partial" }.isEmpty)
    }
}

final class OfflinePreprocessingIntegrationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    @MainActor
    func testImportProcessesWithoutChangingRawFileAndProducesShareableCSV() async throws {
        let rawURL = temporaryDirectory.appendingPathComponent("raw.csv")
        let rawData = rawCSVData(samples: makeStationarySamples())
        try rawData.write(to: rawURL)
        let outputDirectory = temporaryDirectory.appendingPathComponent("processed", isDirectory: true)
        let model = OfflinePreprocessingModel(
            exporter: ProcessedMotionCSVExporter(directory: outputDirectory)
        )

        await model.processImportedFile(rawURL)

        XCTAssertEqual(model.state, .succeeded)
        XCTAssertEqual(model.importedSampleCount, 61)
        XCTAssertEqual(try Data(contentsOf: rawURL), rawData)
        let outputURL = try XCTUnwrap(model.processedCSVURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(model.result?.frames.count, 61)
    }

    @MainActor
    func testOutputWriteFailureIsActionableAndNotShareable() async throws {
        let rawURL = temporaryDirectory.appendingPathComponent("raw.csv")
        try rawCSVData(samples: makeStationarySamples()).write(to: rawURL)
        let invalidOutputDirectory = temporaryDirectory.appendingPathComponent("ordinary-file")
        XCTAssertTrue(FileManager.default.createFile(atPath: invalidOutputDirectory.path, contents: Data()))
        let model = OfflinePreprocessingModel(
            exporter: ProcessedMotionCSVExporter(directory: invalidOutputDirectory)
        )

        await model.processImportedFile(rawURL)

        XCTAssertEqual(model.state, .failed)
        XCTAssertNil(model.processedCSVURL)
        XCTAssertTrue(model.latestError?.contains("Could not write the processed CSV") == true)
    }

    private func rawCSVData(samples: [RawMotionSample]) -> Data {
        var text = CSVRecorder.header + "\n"
        for sample in samples {
            text += CSVRecorder.row(for: sample) + "\n"
        }
        return Data(text.utf8)
    }
}

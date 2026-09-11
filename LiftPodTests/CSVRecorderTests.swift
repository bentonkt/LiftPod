import Foundation
import XCTest
@testable import LiftPod

final class CSVRecorderTests: XCTestCase {
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

    func testHeaderMatchesSchemaExactlyAndRowsHaveTwentyFields() async throws {
        XCTAssertEqual(CSVRecorder.header, "index,source_timestamp,receipt_uptime,sensor_location,user_acceleration_x,user_acceleration_y,user_acceleration_z,gravity_x,gravity_y,gravity_z,rotation_rate_x,rotation_rate_y,rotation_rate_z,quaternion_w,quaternion_x,quaternion_y,quaternion_z,roll,pitch,yaw")
        XCTAssertEqual(CSVRecorder.row(for: makeSample()).split(separator: ",", omittingEmptySubsequences: false).count, 20)
    }

    func testFloatingPointPrecisionUsesPOSIXDecimalSeparator() {
        let row = CSVRecorder.row(for: makeSample())
        XCTAssertTrue(row.contains("1.2345678901234567"))
        XCTAssertFalse(row.contains("1,2345678901234567"))
    }

    func testCSVEscaping() {
        XCTAssertEqual(CSVRecorder.escape("plain"), "plain")
        XCTAssertEqual(CSVRecorder.escape("left,right"), "\"left,right\"")
        XCTAssertEqual(CSVRecorder.escape("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(CSVRecorder.escape("a\nb"), "\"a\nb\"")
        XCTAssertEqual(CSVRecorder.escape("a\rb"), "\"a\rb\"")
    }

    func testOneSampleProducesOneRowAndStopFlushesPendingData() async throws {
        let recorder = CSVRecorder(directory: temporaryDirectory)
        try await recorder.start()
        let count = try await recorder.append(makeSample())
        XCTAssertEqual(count, 1)
        let stopResult = try await recorder.stop()
        let completed = try XCTUnwrap(stopResult)
        let lines = try String(contentsOf: completed.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(completed.sampleCount, 1)
    }

    func testMultipleSamplesPreserveOrder() async throws {
        let recorder = CSVRecorder(directory: temporaryDirectory, batchSize: 2)
        try await recorder.start()
        for index in 1...3 {
            _ = try await recorder.append(makeSample(index: UInt64(index)))
        }
        let stopResult = try await recorder.stop()
        let completed = try XCTUnwrap(stopResult)
        let lines = try String(contentsOf: completed.url, encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(lines[1].hasPrefix("1,"))
        XCTAssertTrue(lines[2].hasPrefix("2,"))
        XCTAssertTrue(lines[3].hasPrefix("3,"))
    }

    func testBatchOfAtLeast256RowsIsComplete() async throws {
        let recorder = CSVRecorder(directory: temporaryDirectory)
        try await recorder.start()
        for index in 1...300 {
            _ = try await recorder.append(makeSample(index: UInt64(index)))
        }
        let stopResult = try await recorder.stop()
        let completed = try XCTUnwrap(stopResult)
        let lines = try String(contentsOf: completed.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 301)
        XCTAssertEqual(completed.sampleCount, 300)
    }

    func testRepeatedStartAndStopAreHarmlessAndOpenFileIsNotCSV() async throws {
        let recorder = CSVRecorder(directory: temporaryDirectory)
        try await recorder.start()
        try await recorder.start()
        let openFiles = try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(openFiles.filter { $0.pathExtension == "partial" }.count, 1)
        XCTAssertTrue(openFiles.filter { $0.pathExtension == "csv" }.isEmpty)

        let stopResult = try await recorder.stop()
        let completed = try XCTUnwrap(stopResult)
        XCTAssertEqual(completed.url.pathExtension, "csv")
        let secondStopResult = try await recorder.stop()
        XCTAssertNil(secondStopResult)
    }

    func testCreationErrorIsSurfacedAndNoCSVIsExportable() async {
        let invalidDirectory = temporaryDirectory.appendingPathComponent("ordinary-file")
        XCTAssertTrue(FileManager.default.createFile(atPath: invalidDirectory.path, contents: Data()))
        let recorder = CSVRecorder(directory: invalidDirectory)
        do {
            try await recorder.start()
            XCTFail("Expected file creation to fail")
        } catch {
            XCTAssertTrue(true)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(contents.filter { $0.pathExtension == "csv" }.isEmpty)
    }
}

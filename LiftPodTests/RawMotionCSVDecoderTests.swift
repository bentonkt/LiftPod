import Foundation
import XCTest
@testable import LiftPod

final class RawMotionCSVDecoderTests: XCTestCase {
    private let decoder = RawMotionCSVDecoder()

    func testExistingHeaderAndEncoderOutputParseExactly() throws {
        let sample = makeSample(index: 42)
        let csv = CSVRecorder.header + "\n" + CSVRecorder.row(for: sample) + "\n"
        XCTAssertEqual(try decoder.decode(text: csv), [sample])
    }

    func testDifferentColumnOrderAndExtraQuotedColumnAreAccepted() throws {
        let sample = makeSample(index: 8)
        let standardValues = CSVRecorder.row(for: sample).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let pairs = Array(zip(RawMotionCSVDecoder.requiredColumns, standardValues)).reversed()
        let header = pairs.map(\.0) + ["note"]
        let row = pairs.map(\.1) + ["\"contains a \"\"quoted\"\" value\""]
        let csv = header.joined(separator: ",") + "\n" + row.joined(separator: ",") + "\n"

        XCTAssertEqual(try decoder.decode(text: csv), [sample])
    }

    func testLFCRLFAndQuotedSensorLocationAreAccepted() throws {
        let row = CSVRecorder.row(for: makeSample()).replacingOccurrences(
            of: "Left headphone",
            with: "\"Left headphone\""
        )
        let lf = CSVRecorder.header + "\n" + row + "\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try decoder.decode(text: lf).count, 1)
        XCTAssertEqual(try decoder.decode(text: crlf).count, 1)
    }

    func testEmptyAndHeaderOnlyFilesFailExplicitly() {
        XCTAssertThrowsError(try decoder.decode(text: "")) { error in
            XCTAssertEqual(error as? RawMotionCSVError, .emptyFile)
        }
        XCTAssertThrowsError(try decoder.decode(text: CSVRecorder.header + "\n")) { error in
            XCTAssertEqual(error as? RawMotionCSVError, .emptyDataset)
        }
    }

    func testMissingRequiredColumnFails() {
        let header = RawMotionCSVDecoder.requiredColumns.dropLast().joined(separator: ",")
        XCTAssertThrowsError(try decoder.decode(text: header + "\n")) { error in
            guard case let .missingColumns(columns) = error as? RawMotionCSVError else {
                return XCTFail("Expected missing-columns error")
            }
            XCTAssertEqual(columns, ["yaw"])
        }
    }

    func testMissingRowFieldReportsLineNumber() {
        let fields = CSVRecorder.row(for: makeSample()).split(separator: ",").dropLast().joined(separator: ",")
        XCTAssertThrowsError(try decoder.decode(text: CSVRecorder.header + "\n" + fields + "\n")) { error in
            guard case let .invalidRow(line, _) = error as? RawMotionCSVError else {
                return XCTFail("Expected invalid-row error")
            }
            XCTAssertEqual(line, 2)
        }
    }

    func testInvalidIndexAndInvalidNumbersFail() {
        XCTAssertThrowsError(try decoder.decode(text: csv(replacing: "index", with: "-1")))
        XCTAssertThrowsError(try decoder.decode(text: csv(replacing: "gravity_x", with: "not-a-number")))
    }

    func testNaNAndInfinityAreRejected() {
        for value in ["nan", "inf", "-inf"] {
            XCTAssertThrowsError(try decoder.decode(text: csv(replacing: "gravity_y", with: value)))
        }
    }

    func testMalformedQuotingAndErrorLineNumbers() {
        let malformed = CSVRecorder.header + "\n" + CSVRecorder.row(for: makeSample()) + "\n\"unterminated"
        XCTAssertThrowsError(try decoder.decode(text: malformed)) { error in
            guard case let .malformedCSV(line, _) = error as? RawMotionCSVError else {
                return XCTFail("Expected malformed-CSV error")
            }
            XCTAssertEqual(line, 3)
        }

        let invalidSecondRow = CSVRecorder.header + "\n" + CSVRecorder.row(for: makeSample()) + "\n" + csvRow(replacing: "pitch", with: "bad") + "\n"
        XCTAssertThrowsError(try decoder.decode(text: invalidSecondRow)) { error in
            guard case let .invalidRow(line, _) = error as? RawMotionCSVError else {
                return XCTFail("Expected invalid-row error")
            }
            XCTAssertEqual(line, 3)
        }
    }

    private func csv(replacing column: String, with value: String) -> String {
        CSVRecorder.header + "\n" + csvRow(replacing: column, with: value) + "\n"
    }

    private func csvRow(replacing column: String, with value: String) -> String {
        var fields = CSVRecorder.row(for: makeSample()).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let index = RawMotionCSVDecoder.requiredColumns.firstIndex(of: column)!
        fields[index] = value
        return fields.joined(separator: ",")
    }
}

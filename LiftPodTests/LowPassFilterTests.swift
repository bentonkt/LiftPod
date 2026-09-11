import XCTest
@testable import LiftPod

final class LowPassFilterTests: XCTestCase {
    func testConstantInputRemainsConstantAndFirstOutputIsUnchanged() throws {
        let output = try MotionPreprocessingEngine.lowPassFilter(
            values: [2, 2, 2],
            timestamps: [0, 0.01, 0.03],
            cutoffFrequency: 5,
            maximumGap: 0.2
        )
        XCTAssertEqual(output[0], 2, accuracy: 0)
        XCTAssertEqual(output, [2, 2, 2])
    }

    func testStepResponseUsesStatedRecurrence() throws {
        let output = try MotionPreprocessingEngine.lowPassFilter(
            values: [0, 1],
            timestamps: [10, 10.1],
            cutoffFrequency: 5,
            maximumGap: 0.2
        )
        let alpha = 1 - exp(-2 * Double.pi * 5 * 0.1)
        XCTAssertEqual(output[1], alpha, accuracy: 1e-15)
    }

    func testIrregularIntervalsUseTheirOwnAlpha() throws {
        let values = [0.0, 1.0, 1.0]
        let timestamps = [0.0, 0.01, 0.11]
        let output = try MotionPreprocessingEngine.lowPassFilter(
            values: values,
            timestamps: timestamps,
            cutoffFrequency: 2,
            maximumGap: 0.2
        )
        let firstAlpha = 1 - exp(-2 * Double.pi * 2 * 0.01)
        let secondAlpha = 1 - exp(-2 * Double.pi * 2 * 0.1)
        let expectedSecond = firstAlpha
        let expectedThird = expectedSecond + secondAlpha * (1 - expectedSecond)
        XCTAssertEqual(output[1], expectedSecond, accuracy: 1e-15)
        XCTAssertEqual(output[2], expectedThird, accuracy: 1e-15)
    }

    func testAlternatingInputIsAttenuated() throws {
        let values = (0..<100).map { $0.isMultiple(of: 2) ? 1.0 : -1.0 }
        let timestamps = (0..<100).map { Double($0) * 0.01 }
        let output = try MotionPreprocessingEngine.lowPassFilter(
            values: values,
            timestamps: timestamps,
            cutoffFrequency: 1,
            maximumGap: 0.2
        )
        let meanAbsoluteOutput = output.dropFirst(20).map(abs).reduce(0, +) / 80
        XCTAssertLessThan(meanAbsoluteOutput, 0.2)
    }

    func testNonPositiveAndExcessiveIntervalsFail() {
        XCTAssertThrowsError(try MotionPreprocessingEngine.lowPassFilter(
            values: [0, 1], timestamps: [1, 1], cutoffFrequency: 5, maximumGap: 0.2
        )) { error in
            guard case .invalidTimestamp = error as? PreprocessingError else {
                return XCTFail("Expected timestamp error")
            }
        }
        XCTAssertThrowsError(try MotionPreprocessingEngine.lowPassFilter(
            values: [0, 1], timestamps: [0, 0.21], cutoffFrequency: 5, maximumGap: 0.2
        )) { error in
            guard case .excessiveSourceGap = error as? PreprocessingError else {
                return XCTFail("Expected excessive-gap error")
            }
        }
    }

    func testEnginePreservesCountIdentityAndIsDeterministic() throws {
        var samples = makeStationarySamples()
        samples.append(syntheticSample(index: 62, timestamp: 3.05, userAcceleration: (0, 0, 0.5)))
        let engine = MotionPreprocessingEngine()
        let first = try engine.process(samples: samples)
        let second = try engine.process(samples: samples)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.frames.count, samples.count)
        XCTAssertEqual(first.frames.map(\.index), samples.map(\.index))
        XCTAssertEqual(first.frames.map(\.sourceTimestamp), samples.map(\.sourceTimestamp))
        XCTAssertEqual(first.frames[0].deltaTime, 0)
        XCTAssertEqual(
            first.frames[0].verticalAccelerationFilteredMetersPerSecondSquared,
            first.frames[0].verticalAccelerationCorrectedMetersPerSecondSquared
        )
    }
}

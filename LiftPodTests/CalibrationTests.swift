import XCTest
@testable import LiftPod

final class CalibrationTests: XCTestCase {
    private let engine = MotionPreprocessingEngine()

    func testThreeSecondsAndSixtySamplesPass() throws {
        let result = try engine.process(samples: makeStationarySamples())
        XCTAssertTrue(result.calibration.passed)
        XCTAssertEqual(result.calibration.duration, 3.0, accuracy: 1e-12)
        XCTAssertEqual(result.calibration.sampleCount, 61)
        XCTAssertEqual(result.calibration.meanGravityMagnitude, 1, accuracy: 1e-15)
    }

    func testInsufficientDurationFails() {
        let samples = (0..<60).map {
            syntheticSample(index: UInt64($0 + 1), timestamp: Double($0) * 0.04)
        }
        assertCalibrationFailure(samples: samples) { reasons in
            XCTAssertTrue(reasons.contains { if case .insufficientDuration = $0 { true } else { false } })
        }
    }

    func testInsufficientSampleCountFails() {
        let samples = (0..<31).map {
            syntheticSample(index: UInt64($0 + 1), timestamp: Double($0) * 0.1)
        }
        assertCalibrationFailure(samples: samples) { reasons in
            XCTAssertTrue(reasons.contains { if case .insufficientSamples = $0 { true } else { false } })
        }
    }

    func testExcessAccelerationVariationFails() {
        let samples = (0...60).map { offset in
            syntheticSample(
                index: UInt64(offset + 1),
                timestamp: Double(offset) * 0.05,
                userAcceleration: (0, 0, offset.isMultiple(of: 2) ? 0.1 : -0.1)
            )
        }
        assertCalibrationFailure(samples: samples) { reasons in
            XCTAssertTrue(reasons.contains { if case .accelerationVariation = $0 { true } else { false } })
        }
    }

    func testExcessGyroscopeMotionFails() {
        let samples = makeStationarySamples(rotationRate: (0.2, 0, 0))
        assertCalibrationFailure(samples: samples) { reasons in
            XCTAssertTrue(reasons.contains { if case .gyroscopeMotion = $0 { true } else { false } })
        }
    }

    func testConstantBiasIsEstimatedAndRemoved() throws {
        let biasG = 0.02
        let samples = (0...60).map { offset in
            syntheticSample(
                index: UInt64(offset + 1),
                timestamp: Double(offset) * 0.05,
                userAcceleration: (0, 0, biasG)
            )
        }
        let result = try engine.process(samples: samples)
        XCTAssertEqual(result.calibration.verticalBias, biasG * 9.80665, accuracy: 1e-14)
        XCTAssertTrue(result.frames.allSatisfy {
            abs($0.verticalAccelerationCorrectedMetersPerSecondSquared) < 1e-14
        })
    }

    func testMultipleCalibrationFailureReasonsArePreserved() {
        let samples = (0..<10).map { offset in
            syntheticSample(
                index: UInt64(offset + 1),
                timestamp: Double(offset) * 0.05,
                userAcceleration: (0, 0, offset.isMultiple(of: 2) ? 0.1 : -0.1),
                rotationRate: (0.2, 0, 0)
            )
        }
        assertCalibrationFailure(samples: samples) { reasons in
            XCTAssertEqual(reasons.count, 4)
        }
    }

    private func assertCalibrationFailure(
        samples: [RawMotionSample],
        assertions: ([CalibrationFailureReason]) -> Void
    ) {
        XCTAssertThrowsError(try engine.process(samples: samples)) { error in
            guard case let .calibrationFailed(result) = error as? PreprocessingError else {
                return XCTFail("Expected calibration failure")
            }
            XCTAssertFalse(result.passed)
            assertions(result.failureReasons)
        }
    }
}

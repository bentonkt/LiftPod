import XCTest
@testable import LiftPod

final class PreprocessingValidationTests: XCTestCase {
    private let engine = MotionPreprocessingEngine()

    func testEmptyAndOneSampleAreRejected() {
        XCTAssertThrowsError(try engine.validate(samples: [])) { error in
            XCTAssertEqual(error as? PreprocessingError, .emptySamples)
        }
        XCTAssertThrowsError(try engine.validate(samples: [syntheticSample(index: 1, timestamp: 0)])) { error in
            XCTAssertEqual(error as? PreprocessingError, .insufficientSamples(actual: 1))
        }
    }

    func testIncreasingIndicesAndTimestampsAreValid() throws {
        let samples = [
            syntheticSample(index: 4, timestamp: 10),
            syntheticSample(index: 7, timestamp: 10.1)
        ]
        XCTAssertEqual(try engine.validate(samples: samples), 0.1, accuracy: 1e-12)
    }

    func testDuplicateAndReversedIndicesAreRejected() {
        for currentIndex: UInt64 in [2, 1] {
            let samples = [
                syntheticSample(index: 2, timestamp: 0),
                syntheticSample(index: currentIndex, timestamp: 0.1)
            ]
            XCTAssertThrowsError(try engine.validate(samples: samples)) { error in
                guard case .nonIncreasingIndex = error as? PreprocessingError else {
                    return XCTFail("Expected non-increasing-index error")
                }
            }
        }
    }

    func testDuplicateAndReversedTimestampsAreRejected() {
        for currentTimestamp in [1.0, 0.9] {
            let samples = [
                syntheticSample(index: 1, timestamp: 1),
                syntheticSample(index: 2, timestamp: currentTimestamp)
            ]
            XCTAssertThrowsError(try engine.validate(samples: samples)) { error in
                guard case .invalidTimestamp = error as? PreprocessingError else {
                    return XCTFail("Expected invalid-timestamp error")
                }
            }
        }
    }

    func testGapAtMaximumPassesAndGapAboveMaximumFails() throws {
        var configuration = PreprocessingConfiguration()
        configuration.maximumSourceGap = 0.2
        let exact = [syntheticSample(index: 1, timestamp: 0), syntheticSample(index: 2, timestamp: 0.2)]
        XCTAssertEqual(try engine.validate(samples: exact, configuration: configuration), 0.2, accuracy: 1e-15)

        let excessive = [syntheticSample(index: 1, timestamp: 0), syntheticSample(index: 2, timestamp: 0.200_001)]
        XCTAssertThrowsError(try engine.validate(samples: excessive, configuration: configuration)) { error in
            guard case .excessiveSourceGap = error as? PreprocessingError else {
                return XCTFail("Expected excessive-gap error")
            }
        }
    }

    func testGravityOutsidePlausibleRangeIsRejected() {
        for gravityZ in [-0.74, -1.26] {
            let samples = [
                syntheticSample(index: 1, timestamp: 0, gravity: (0, 0, gravityZ)),
                syntheticSample(index: 2, timestamp: 0.1)
            ]
            XCTAssertThrowsError(try engine.validate(samples: samples)) { error in
                guard case .invalidGravity = error as? PreprocessingError else {
                    return XCTFail("Expected invalid-gravity error")
                }
            }
        }
    }

    func testNonFiniteVectorComponentsAreRejected() {
        let invalidSamples = [
            syntheticSample(index: 1, timestamp: 0, gravity: (.nan, 0, -1)),
            syntheticSample(index: 1, timestamp: 0, userAcceleration: (.infinity, 0, 0)),
            syntheticSample(index: 1, timestamp: 0, rotationRate: (0, -.infinity, 0))
        ]
        for invalid in invalidSamples {
            XCTAssertThrowsError(try engine.validate(samples: [invalid, syntheticSample(index: 2, timestamp: 0.1)]))
        }
    }

    func testInvalidConfigurationsAreRejected() {
        var zeroCutoff = PreprocessingConfiguration()
        zeroCutoff.lowPassCutoffFrequency = 0
        XCTAssertThrowsError(try zeroCutoff.validated())

        var nonFinite = PreprocessingConfiguration()
        nonFinite.maximumSourceGap = .infinity
        XCTAssertThrowsError(try nonFinite.validated())

        var inconsistent = PreprocessingConfiguration()
        inconsistent.minimumGravityMagnitude = 1.3
        inconsistent.maximumGravityMagnitude = 1.2
        XCTAssertThrowsError(try inconsistent.validated())

        var invalidCount = PreprocessingConfiguration()
        invalidCount.minimumCalibrationSampleCount = 0
        XCTAssertThrowsError(try invalidCount.validated())
    }
}

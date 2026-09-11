import XCTest
@testable import LiftPod

final class VerticalProjectionTests: XCTestCase {
    func testStationaryUpwardAndDownwardProjectionSigns() throws {
        let stationary = syntheticSample(index: 1, timestamp: 0)
        let upward = syntheticSample(index: 1, timestamp: 0, userAcceleration: (0, 0, 0.5))
        let downward = syntheticSample(index: 1, timestamp: 0, userAcceleration: (0, 0, -0.5))

        XCTAssertEqual(try MotionPreprocessingEngine.verticalAcceleration(for: stationary), 0, accuracy: 1e-15)
        XCTAssertEqual(try MotionPreprocessingEngine.verticalAcceleration(for: upward), 0.5 * 9.80665, accuracy: 1e-15)
        XCTAssertEqual(try MotionPreprocessingEngine.verticalAcceleration(for: downward), -0.5 * 9.80665, accuracy: 1e-15)
    }

    func testEquivalentMotionIsIndependentOfSensorAxisOrientation() throws {
        let zOriented = syntheticSample(
            index: 1,
            timestamp: 0,
            gravity: (0, 0, -1),
            userAcceleration: (0, 0, 0.25)
        )
        let yOriented = syntheticSample(
            index: 1,
            timestamp: 0,
            gravity: (0, -1, 0),
            userAcceleration: (0, 0.25, 0)
        )
        XCTAssertEqual(
            try MotionPreprocessingEngine.verticalAcceleration(for: zOriented),
            try MotionPreprocessingEngine.verticalAcceleration(for: yOriented),
            accuracy: 1e-15
        )
    }

    func testNonUnitGravityIsNormalized() throws {
        let sample = syntheticSample(
            index: 1,
            timestamp: 0,
            gravity: (0, 0, -1.2),
            userAcceleration: (0, 0, 0.1)
        )
        XCTAssertEqual(
            try MotionPreprocessingEngine.verticalAcceleration(for: sample),
            0.1 * 9.80665,
            accuracy: 1e-15
        )
    }

    func testStandardGravityConversionUsesExactConfiguredConstant() throws {
        var configuration = PreprocessingConfiguration()
        configuration.standardGravity = 9.80665
        let oneGUp = syntheticSample(index: 1, timestamp: 0, userAcceleration: (0, 0, 1))
        XCTAssertEqual(
            try MotionPreprocessingEngine.verticalAcceleration(for: oneGUp, configuration: configuration),
            9.80665,
            accuracy: 0
        )
    }
}

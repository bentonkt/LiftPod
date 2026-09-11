import XCTest
@testable import LiftPod

final class ExperimentalResamplerTests: XCTestCase {
    func testFiftyHertzSpacingAndLinearVectorInterpolation() throws {
        let input = [
            experimentalRawSample(index: 1, time: 10, acceleration: .init(x: 0, y: 0, z: 0)),
            experimentalRawSample(index: 2, time: 10.06, acceleration: .init(x: 6, y: 12, z: 18))
        ]
        let output = try MotionResampler().resample(input).samples
        XCTAssertEqual(output.count, 4)
        for index in output.indices {
            XCTAssertEqual(output[index].sourceTimestamp, 10 + Double(index) * 0.02, accuracy: 1e-12)
        }
        XCTAssertEqual(output[1].userAcceleration.x, 2, accuracy: 1e-12)
        XCTAssertEqual(output[2].userAcceleration.y, 8, accuracy: 1e-12)
        XCTAssertEqual(output[1].interpolationStatus, .interpolated)
        XCTAssertEqual(output[3].interpolationStatus, .delivered)
    }

    func testSixtyMillisecondsInterpolatesButSixtyOneDoesNot() throws {
        let sixty = try MotionResampler().resample([
            experimentalRawSample(index: 1, time: 0), experimentalRawSample(index: 2, time: 0.060)
        ])
        XCTAssertEqual(sixty.samples.count, 4)
        let sixtyOne = try MotionResampler().resample([
            experimentalRawSample(index: 1, time: 0), experimentalRawSample(index: 2, time: 0.061)
        ])
        XCTAssertEqual(sixtyOne.samples.count, 2)
        XCTAssertNotEqual(sixtyOne.samples[0].epoch, sixtyOne.samples[1].epoch)
    }

    func testQuaternionShortestArcEquivalenceAndNormalization() throws {
        let q = ExperimentalQuaternion(w: 0.7071067811865476, x: 0, y: 0, z: 0.7071067811865476)
        let same = try MotionResampler().resample([
            experimentalRawSample(index: 1, time: 0, attitude: q),
            experimentalRawSample(index: 2, time: 0.04, attitude: q.negated())
        ]).samples
        XCTAssertEqual(abs(same[1].attitude.dot(q)), 1, accuracy: 1e-12)
        XCTAssertEqual(same[1].attitude.norm, 1, accuracy: 1e-12)

        let start = ExperimentalQuaternion(w: 1, x: 0, y: 0, z: 0)
        let end = ExperimentalQuaternion(w: cos(0.1), x: 0, y: 0, z: sin(0.1))
        let middle = MotionResampler.slerp(start, end, fraction: 0.5)
        XCTAssertEqual(middle.w, cos(0.05), accuracy: 1e-12)
    }

    func testDuplicateIgnoredBackwardBreaksAndInvalidInputIsReported() throws {
        let result = try MotionResampler().resample([
            experimentalRawSample(index: 1, time: 1),
            experimentalRawSample(index: 2, time: 1),
            experimentalRawSample(index: 3, time: 0.5),
            experimentalRawSample(index: 4, time: 0.52, acceleration: .init(x: .nan, y: 0, z: 0))
        ])
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertEqual(result.samples.map(\.epoch), [0, 1])
        XCTAssertTrue(result.qualityTransitions.contains { $0.state == .invalidInput })
    }

    func testExcessiveAttitudeRateCreatesDiscontinuity() throws {
        let result = try MotionResampler().resample([
            experimentalRawSample(index: 1, time: 0),
            experimentalRawSample(index: 2, time: 0.06,
                                  attitude: .init(w: 0, x: 1, y: 0, z: 0))
        ])
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertNotEqual(result.samples[0].epoch, result.samples[1].epoch)
    }

    func testNonFiniteEulerComponentIsInvalidEvenThoughDetectionUsesQuaternion() throws {
        let result = try MotionResampler().resample([
            experimentalRawSample(index: 1, time: 0, roll: .nan),
            experimentalRawSample(index: 2, time: 0.02)
        ])
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.qualityTransitions.first?.state, .invalidInput)
    }

    func testNestedConfigurationInvariantsAreValidated() {
        var configuration = ExperimentalV1Configuration()
        configuration.biphasic.minimumLobeDuration = configuration.biphasic.maximumLobeDuration
        XCTAssertThrowsError(try configuration.validated())

        configuration = ExperimentalV1Configuration()
        configuration.filter = .init(b0: .nan, b1: 0, b2: 0, a1: 0, a2: 0)
        XCTAssertThrowsError(try configuration.validated())
    }
}

final class ScalarBiquadFilterTests: XCTestCase {
    func testDCInitializationAndConstantStability() {
        var filter = ScalarBiquadFilter()
        let first = filter.process(3)
        let gain = (BiquadConfiguration.v1.b0 + BiquadConfiguration.v1.b1 + BiquadConfiguration.v1.b2) /
            (1 + BiquadConfiguration.v1.a1 + BiquadConfiguration.v1.a2)
        XCTAssertEqual(first, 3 * gain, accuracy: 1e-15)
        for _ in 0..<100 { XCTAssertEqual(filter.process(3), 3 * gain, accuracy: 1e-12) }
    }

    func testResetRestoresSteadyStateInitialization() {
        var filter = ScalarBiquadFilter()
        _ = filter.process(1); _ = filter.process(0); filter.reset()
        XCTAssertEqual(filter.process(2), 2, accuracy: 1e-12)
    }

    func testCheckedImpulsePrefix() {
        var filter = ScalarBiquadFilter()
        XCTAssertEqual(filter.process(0), 0, accuracy: 0)
        let actual = [filter.process(1), filter.process(0), filter.process(0)]
        let c = BiquadConfiguration.v1
        let y0 = c.b0
        let d1 = c.b1 - c.a1 * y0
        let d2 = c.b2 - c.a2 * y0
        let y1 = d1
        let y2 = -c.a1 * y1 + d2
        XCTAssertEqual(actual[0], y0, accuracy: 1e-15)
        XCTAssertEqual(actual[1], y1, accuracy: 1e-15)
        XCTAssertEqual(actual[2], y2, accuracy: 1e-15)
    }
}

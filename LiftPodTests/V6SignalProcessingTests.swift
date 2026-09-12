import XCTest
@testable import LiftPod

final class V6SignalProcessingTests: XCTestCase {
    func testAngularProfilesValidateAndHaveDistinctStableHashes() throws {
        let fixed = try V2DSPProfile.fixedAxisAngularCurl.validated()
        let adaptive = try V2DSPProfile.adaptiveCurlV6.validated()
        XCTAssertEqual(fixed.identity.algorithm, .fixedAxisAngular)
        XCTAssertEqual(adaptive.identity.algorithm, .adaptiveAxis)
        XCTAssertEqual(fixed.identity.sampleRate, 50)
        XCTAssertNotEqual(fixed.contentHash, adaptive.contentHash)
        XCTAssertEqual(fixed.contentHash, V2DSPProfile.fixedAxisAngularCurl.contentHash)
    }

    func testProjectedGravityAngleUsesRightHandRule() throws {
        let angle = try XCTUnwrap(V6VectorMath.gravityPlaneAngle(
            from: .init(x: 1, y: 0, z: 0), to: .init(x: 0, y: 1, z: 0),
            axis: .init(x: 0, y: 0, z: 1)
        ))
        XCTAssertEqual(angle, .pi / 2, accuracy: 1e-12)
        XCTAssertNil(V6VectorMath.gravityPlaneAngle(from: .init(x: 0, y: 0, z: 1),
                                                    to: .init(x: 1, y: 0, z: 0),
                                                    axis: .init(x: 0, y: 0, z: 1)))
    }

    func testAngleUnwrapCrossesPiWithoutJump() throws {
        var angle = V6ContinuousAngle()
        XCTAssertEqual(try XCTUnwrap(angle.observe(3.10, maximumDelta: 0.6)), 3.10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(angle.observe(-3.10, maximumDelta: 0.6)), 3.183185307179586, accuracy: 1e-12)
        XCTAssertNil(angle.observe(-1.0, maximumDelta: 0.6))
    }

    func testAxisEstimatorRecoversGravityOrthogonalRotationAxis() throws {
        let frames = (0..<20).map { index in
            sample(time: Double(index) / 50, gravity: .init(x: 0, y: 0, z: 1),
                   gyro: .init(x: 1.2, y: 0.02, z: 0.5))
        }
        let estimate = try XCTUnwrap(V6AxisEstimator.estimate(frames, sampleRate: 50))
        XCTAssertGreaterThan(estimate.axis.x, 0.99)
        XCTAssertEqual(estimate.axis.z, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(estimate.energyFraction, 0.99)
        XCTAssertGreaterThan(estimate.coherence, 0.99)
    }

    func testAdaptiveReferenceRequiresStableUnitGravity() throws {
        var acquirer = V6ReferenceAcquirer()
        let profile = V2DSPProfile.adaptiveCurlV6
        var result: V2ReferenceMeasurements?
        for index in 0..<40 {
            result = acquirer.observe(sample(time: Double(index) / 50,
                                             gravity: .init(x: 0, y: 0, z: 1),
                                             gyro: .init(x: 0, y: 0, z: 0)), profile: profile)
        }
        let reference = try XCTUnwrap(result)
        XCTAssertEqual(reference.referenceGravity.z, 1, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(reference.sampleCount, 20)
    }

    func testQualifiedCycleCommitsOnlyAfterCredibleReturnAndSettling() {
        let profile = V2DSPProfile.fixedAxisAngularCurl
        var segmenter = V6QualifiedCycleSegmenter(profile: profile)
        var emitted: V6CycleResult?
        var time = 0.0
        func feed(_ values: [Double], rate: Double, gyro: Double = 0.5) {
            for value in values {
                let update = segmenter.observe(signal: value, timestamp: time, gyroMagnitude: gyro,
                                               interpolated: false, departureAllowed: true,
                                               signedRotationRate: rate)
                emitted = update.cycle ?? emitted
                time += 0.1
            }
        }
        feed([0, 0, 0], rate: 0, gyro: 0.1)
        feed([0.5, 0.8, 1.2, 1.6, 2.0, 2.1], rate: 0.8)
        feed([1.9, 1.7, 1.4, 1.0, 0.6, 0.25, 0.08, 0.04], rate: -0.8)
        feed([0.03, 0.03, 0.03], rate: 0, gyro: 0.1)
        XCTAssertNotNil(emitted)
        XCTAssertGreaterThanOrEqual(emitted?.top ?? 0, 2.0)
        XCTAssertLessThanOrEqual(emitted?.returned ?? 1, 0.25)
        XCTAssertGreaterThan(emitted?.detectionTime ?? 0, emitted?.completionTime ?? 1)
    }

    private func sample(time: Double, gravity: ExperimentalVector3,
                        gyro: ExperimentalVector3) -> ResampledMotionSample {
        .init(sourceTimestamp: time, sessionTime: time, sensorSide: .right,
              userAcceleration: .init(x: 0, y: 0, z: 0), rotationRate: gyro,
              gravity: gravity, attitude: .init(w: 1, x: 0, y: 0, z: 0),
              interpolationStatus: .delivered, epoch: 0)
    }
}

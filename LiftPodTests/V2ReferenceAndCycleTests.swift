import XCTest
@testable import LiftPod

final class V2ReferenceAcquisitionTests: XCTestCase {
    func testStableHeldWeightBecomesReadyWithDeterministicStatistics() {
        var first = V2ReferenceAcquirer(); var second = V2ReferenceAcquirer()
        var a: V2ReferenceMeasurements?, b: V2ReferenceMeasurements?
        for index in 0...30 {
            a = first.observe(v2Uniform(index), profile: .bundledCurl) ?? a
            b = second.observe(v2Uniform(index), profile: .bundledCurl) ?? b
        }
        XCTAssertEqual(a, b); XCTAssertEqual(a?.neutralSignal, -0.5)
        XCTAssertEqual(a?.observedSampleRate ?? 0, 50, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(a?.sampleCount ?? 0, 20)
    }

    func testBriefTremorDoesNotPreventReadiness() {
        var acquirer = V2ReferenceAcquirer(); var result: V2ReferenceMeasurements?
        for index in 0...35 {
            let acceleration = index == 12 ? ExperimentalVector3(x: 0.12, y: 0, z: 0) : .init(x: 0, y: 0, z: 0)
            result = acquirer.observe(v2Uniform(index, acceleration: acceleration), profile: .bundledCurl) ?? result
        }
        XCTAssertNotNil(result)
    }

    func testSustainedMovementAndOrientationDriftPreventReadiness() {
        var moving = V2ReferenceAcquirer(), drifting = V2ReferenceAcquirer()
        var movingResult: V2ReferenceMeasurements?, driftResult: V2ReferenceMeasurements?
        for index in 0...35 {
            movingResult = moving.observe(v2Uniform(index, acceleration: .init(x: 0.2, y: 0, z: 0)), profile: .bundledCurl)
            let signal = -0.4 - Double(index) * 0.008
            driftResult = drifting.observe(v2Uniform(index, signal: signal), profile: .bundledCurl)
        }
        XCTAssertNil(movingResult); XCTAssertNil(driftResult)
    }

    func testQuaternionMedoidTreatsOppositeSignsAsSameOrientation() {
        let q = ExperimentalQuaternion(w: 0.9, x: 0.1, y: 0, z: 0).normalized()!
        let center = V2ReferenceAcquirer.quaternionMedoid([q, q.negated(), q])
        XCTAssertEqual(abs(center.dot(q)), 1, accuracy: 1e-12)
    }
}

final class V2LocalCycleTests: XCTestCase {
    func testCompleteCurlCountsOnceAndCompletionPrecedesDetection() {
        let detector = v2RunSegmenter(v2CurlSignals())
        let accepted = detector.events.filter { $0.rejectionReason == nil }
        XCTAssertEqual(accepted.count, 1)
        XCTAssertLessThan(accepted[0].completionTimestamp, accepted[0].detectionTimestamp)
        XCTAssertTrue(accepted[0].id.contains(V2DSPProfile.bundledCurl.contentHash))
    }

    func testDeeperBottomCountsAndTooDeepReturnRejects() {
        XCTAssertEqual(v2RunSegmenter(v2CurlSignals(bottom: -0.1, top: 1.0, returned: -0.1))
            .events.filter { $0.rejectionReason == nil }.count, 1)
        XCTAssertEqual(v2RunSegmenter(v2CurlSignals(returned: -0.7)).events.last?.rejectionReason, .returnTooDeep)
    }

    func testHighAndPartialReturnsDoNotCount() {
        let high = v2RunSegmenter(v2CurlSignals(top: 1.9, returned: 0.25))
        XCTAssertEqual(high.events.last?.rejectionReason, .returnTooHigh)
        let partial = v2RunSegmenter(v2CurlSignals(returned: 0.5))
        XCTAssertEqual(partial.events.filter { $0.rejectionReason == nil }.count, 0)
    }

    func testPartialAndUnrelatedMovementDoNotSwallowFollowingCompleteCurl() {
        let partialThenComplete = v2CurlSignals(returned: 0.5) + v2CurlSignals()
        XCTAssertEqual(v2RunSegmenter(partialThenComplete).events.filter { $0.rejectionReason == nil }.count, 1)

        let unrelated = [0, 0, 0, 0.3, 0.32, 0.34, 0.1, 0, 0, 0]
        XCTAssertEqual(v2RunSegmenter(unrelated + v2CurlSignals()).events.filter { $0.rejectionReason == nil }.count, 1)
    }

    func testPreparationCannotBeginDepartureAndResetChangesEpoch() {
        var detector = v2RunSegmenter(v2CurlSignals(), departureAllowed: false)
        XCTAssertTrue(detector.events.isEmpty); XCTAssertNotEqual(detector.phase, .outbound)
        detector.reset(discontinuity: true)
        XCTAssertEqual(detector.detectorEpoch, 1); XCTAssertEqual(detector.phase, .waitingForBottom)
    }

    func testRefractoryPreventsImmediateSecondDeparture() {
        var detector = V2LocalCycleSegmenter(profile: .bundledCurl, setDescriptor: v2Descriptor())
        let first = v2CurlSignals()
        for (index, value) in (first + v2CurlSignals()).enumerated() {
            _ = detector.observe(signal: value, gyroscopeMagnitude: 0, timestamp: Double(index) * 0.02,
                                 departureAllowed: true)
        }
        XCTAssertEqual(detector.events.filter { $0.rejectionReason == nil }.count, 1)
    }
}

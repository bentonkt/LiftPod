import XCTest
@testable import LiftPod

final class EndpointProgressDetectorTests: XCTestCase {
    private func detector(configuration: ExperimentalV1Configuration = .init()) -> EndpointProgressDetector {
        EndpointProgressDetector(profile: .profile(for: .bicepsCurl, sensorSide: .right), configuration: configuration)
    }

    private func fullCurl(final: Double = 0) -> [Double] {
        (0...100).map { index in
            let time = Double(index) * 0.02
            if time < 0.35 { return 0 }
            if time < 0.95 { return 1 }
            if time < 1.25 { return 0.6 }
            return final
        }
    }

    func testCompleteCurlCountsExactlyOnceAndHonorsRefractory() {
        let result = detector().run(samples: resampledSignals(fullCurl() + Array(repeating: 0, count: 30), exercise: .bicepsCurl))
        XCTAssertEqual(result.candidates.filter { $0.disposition == .provisional }.count, 1)
    }

    func testPartialMotionDoesNotCountAndInsufficientExcursionRejects() {
        let partial = Array(repeating: 0.0, count: 20) + Array(repeating: 0.5, count: 20) + Array(repeating: 0.0, count: 20)
        let result = detector().run(samples: resampledSignals(partial, exercise: .bicepsCurl))
        XCTAssertTrue(result.candidates.contains { $0.rejectionReason == .insufficientExcursion })
        XCTAssertFalse(result.candidates.contains { $0.disposition == .provisional })
    }

    func testInvalidOrderingRejects() {
        let values = Array(repeating: 0.0, count: 14) + Array(repeating: 1.0, count: 10)
        let result = detector().run(samples: resampledSignals(values, exercise: .bicepsCurl))
        XCTAssertTrue(result.candidates.contains { $0.rejectionReason == .invalidOrdering } ||
                      result.finalPhase == .outbound)
    }

    func testMinimumDurationAndMaximumPauseAreEnforced() {
        var fast = ExperimentalV1Configuration(); fast.minimumPhaseDuration = 0.5
        let fastResult = detector(configuration: fast).run(samples: resampledSignals(fullCurl(), exercise: .bicepsCurl))
        XCTAssertTrue(fastResult.candidates.filter { $0.disposition == .provisional }.count <= 1)

        var shortPause = ExperimentalV1Configuration(); shortPause.maximumTurnaroundPause = 0.1
        let paused = detector(configuration: shortPause).run(samples: resampledSignals(fullCurl(), exercise: .bicepsCurl))
        XCTAssertTrue(paused.candidates.contains { $0.rejectionReason == .excessivePause })
    }

    func testNeutralAcquisitionAndAdaptationRemainBounded() {
        let result = detector().run(samples: resampledSignals(fullCurl(final: 0.15), exercise: .bicepsCurl))
        let reference = result.neutralReference
        XCTAssertNotNil(reference)
        XCTAssertLessThanOrEqual(abs((reference?.adaptedScalar ?? 0) - (reference?.initialScalar ?? 0)), 0.06 + 1e-12)
    }
}

final class BiphasicCycleDetectorTests: XCTestCase {
    private func detector(configuration: ExperimentalV1Configuration = .init()) -> BiphasicCycleDetector {
        BiphasicCycleDetector(profile: .profile(for: .lateralRaise, sensorSide: .right), configuration: configuration)
    }

    func testRequiredSyntheticFixtureProducesOneCandidate() {
        let result = detector().run(samples: resampledSignals(biphasicFixture(), exercise: .lateralRaise))
        XCTAssertEqual(result.candidates.filter { $0.disposition == .provisional }.count, 1)
    }

    func testNegativeFirstIsRejected() {
        let values = Array(repeating: 0.0, count: 10) + Array(repeating: -0.3, count: 20)
        let result = detector().run(samples: resampledSignals(values, exercise: .lateralRaise))
        XCTAssertTrue(result.candidates.contains { $0.rejectionReason == .invalidOrdering })
    }

    func testSameSignAndPartialReturnDoNotCount() {
        let sameSign = Array(repeating: 0.0, count: 10) + Array(repeating: 0.3, count: 170)
        let sameResult = detector().run(samples: resampledSignals(sameSign, exercise: .lateralRaise))
        XCTAssertTrue(sameResult.candidates.contains { $0.rejectionReason == .sameSignOnly })
        let partial = Array(repeating: 0.0, count: 10) + Array(repeating: 0.3, count: 20) + Array(repeating: -0.3, count: 5)
        XCTAssertFalse(detector().run(samples: resampledSignals(partial, exercise: .lateralRaise))
            .candidates.contains { $0.disposition == .provisional })
    }

    func testInsufficientAreaAndLobeDurationReject() {
        var configuration = ExperimentalV1Configuration()
        configuration.biphasic.minimumLobeArea = 0.20
        let result = detector(configuration: configuration)
            .run(samples: resampledSignals(biphasicFixture(), exercise: .lateralRaise))
        XCTAssertTrue(result.candidates.contains { $0.rejectionReason == .insufficientArea })

        configuration = ExperimentalV1Configuration()
        configuration.biphasic.minimumLobeDuration = 0.8
        let durationResult = detector(configuration: configuration)
            .run(samples: resampledSignals(biphasicFixture(), exercise: .lateralRaise))
        XCTAssertFalse(durationResult.candidates.contains { $0.disposition == .provisional })
    }
}

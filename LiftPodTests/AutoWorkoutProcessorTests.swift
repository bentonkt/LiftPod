import XCTest
@testable import LiftPod

final class AutoWorkoutProcessorTests: XCTestCase {
    func testResumeNormalizesRestartedNativeClockAndStartsNewEvidenceEpoch() throws {
        var configuration = AutoWorkoutConfiguration()
        configuration.metricsEnabled = false
        var processor = try AutoWorkoutProcessor(configuration: configuration)

        for step in 0...50 {
            try processor.apply(.init(kind: .sample,
                raw: RawMotionEvent(quietRaw(index: step, time: 100 + Double(step) / 50))))
        }
        let beforePauseTime = try XCTUnwrap(processor.snapshot.timestamp)
        let beforePauseEpoch = try XCTUnwrap(processor.latestEvidence?.sourceEpoch)
        XCTAssertGreaterThanOrEqual(beforePauseTime, 100)

        try processor.apply(.init(kind: .pause, timestamp: 101))
        try processor.apply(.init(kind: .resume, timestamp: 101))
        XCTAssertEqual(processor.snapshot.state, .running)

        var lastNormalizedTime = beforePauseTime
        for step in 0...50 {
            try processor.apply(.init(kind: .sample,
                raw: RawMotionEvent(quietRaw(index: 51 + step, time: Double(step) / 50))))
            if let time = processor.snapshot.timestamp {
                XCTAssertGreaterThanOrEqual(time, lastNormalizedTime)
                lastNormalizedTime = time
            }
        }

        let afterResumeTime = try XCTUnwrap(processor.snapshot.timestamp)
        let afterResumeEpoch = try XCTUnwrap(processor.latestEvidence?.sourceEpoch)
        XCTAssertEqual(processor.snapshot.state, .running)
        XCTAssertGreaterThanOrEqual(afterResumeTime, beforePauseTime)
        XCTAssertGreaterThan(afterResumeEpoch, beforePauseEpoch)
        XCTAssertEqual(processor.latestFrame?.sample.epoch, afterResumeEpoch)
        XCTAssertTrue(processor.snapshot.cycles.isEmpty)
        XCTAssertTrue(processor.snapshot.sets.isEmpty)
        XCTAssertEqual(processor.snapshot.candidateCount, 0)
    }

    func testTwoSyntheticSetsBackfillSealRecoveryAndReacquire() throws {
        var configuration = AutoWorkoutConfiguration()
        configuration.workoutID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        configuration.metricsEnabled = false
        var processor = try AutoWorkoutProcessor(configuration: configuration)

        var firstAuthorizedBatch: AutoEvidenceBatch?
        for index in 0...600 {
            try processor.apply(.init(kind: .sample, raw: RawMotionEvent(movingRaw(index, phaseOrigin: 0))))
            if firstAuthorizedBatch == nil, let evidence = processor.latestEvidence, !evidence.cycles.isEmpty {
                firstAuthorizedBatch = evidence
            }
        }

        let learned = try XCTUnwrap(firstAuthorizedBatch)
        XCTAssertGreaterThanOrEqual(learned.cycles.count, configuration.minimumCycles,
            "The first supported count must be a chronological backfill, not a fabricated one-rep qualification")
        XCTAssertTrue(learned.cycles.allSatisfy {
            $0.authorized == learned.timestamp && $0.completion < $0.authorized
        })
        XCTAssertEqual(learned.templates.count, 1)
        XCTAssertEqual(processor.snapshot.sets.count, 1)
        XCTAssertGreaterThanOrEqual(processor.snapshot.sets[0].count, configuration.minimumCycles)

        for index in 601...1200 {
            try processor.apply(.init(kind: .sample, raw: RawMotionEvent(quietRaw(index))))
        }
        let afterRecovery = processor.snapshot
        XCTAssertEqual(afterRecovery.sets.count, 1)
        XCTAssertEqual(afterRecovery.sets[0].status, .sealed)
        let recovery = try XCTUnwrap(afterRecovery.intervals.last(where: { $0.kind == .recovery }))
        XCTAssertGreaterThanOrEqual(recovery.end - recovery.start, configuration.groupingGrace)

        let secondStart = Double(1201) / 50
        for index in 1201...1801 {
            try processor.apply(.init(kind: .sample,
                raw: RawMotionEvent(movingRaw(index, phaseOrigin: secondStart))))
        }
        try processor.apply(.init(kind: .finish, timestamp: Double(1801) / 50))

        let finished = processor.snapshot
        XCTAssertEqual(finished.state, .finished)
        XCTAssertEqual(finished.sets.count, 2)
        XCTAssertTrue(finished.sets.allSatisfy {
            $0.status == .sealed && $0.count >= configuration.minimumCycles
        })
        XCTAssertGreaterThanOrEqual(finished.sets[1].start, secondStart - 0.05)
        XCTAssertTrue(Set(finished.sets[0].cycleIDs).isDisjoint(with: Set(finished.sets[1].cycleIDs)))
        XCTAssertFalse(finished.cycles.contains {
            $0.start < secondStart && $0.completion > secondStart
        })
    }

    private func movingRaw(_ index: Int, phaseOrigin: Double) -> RawMotionSample {
        let time = Double(index) / 50
        let phase = Double.pi * (time - phaseOrigin)
        return experimentalRawSample(index: UInt64(index), time: time, side: .rightHeadphone,
            acceleration: .init(x: 0.35 * cos(phase), y: 0.105 * sin(phase), z: 0),
            gravity: .init(x: 0, y: 0, z: -1))
    }

    private func quietRaw(_ index: Int) -> RawMotionSample {
        quietRaw(index: index, time: Double(index) / 50)
    }

    private func quietRaw(index: Int, time: Double) -> RawMotionSample {
        experimentalRawSample(index: UInt64(index), time: time, side: .rightHeadphone,
            acceleration: .init(x: 0, y: 0, z: 0), gravity: .init(x: 0, y: 0, z: -1))
    }
}

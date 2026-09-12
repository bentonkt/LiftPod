import XCTest
@testable import LiftPod

final class AutoSetCoordinatorTests: XCTestCase {
    private let workoutID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testStartsConnectingAndFirstUsableEvidenceBecomesReady() {
        var coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.snapshot.state, .connecting)
        XCTAssertEqual(coordinator.snapshot.status, "Connecting")

        coordinator.consume(batch(at: 1, resolvedThrough: 1))

        XCTAssertEqual(coordinator.snapshot.state, .running)
        XCTAssertEqual(coordinator.snapshot.status, "Ready — begin when ready")
    }

    func testThreeCyclesQualifyTogetherAndRecoveryIsBackdatedBeforeSealing() {
        var coordinator = makeCoordinator()
        coordinator.consume(batch(at: 24, cycles: cycles([(19, 20), (21, 22), (23, 24)]),
                                  activity: .moving, candidateStart: 19, resolvedThrough: 18))

        XCTAssertEqual(coordinator.snapshot.sets.count, 1)
        XCTAssertEqual(coordinator.snapshot.sets[0].count, 3)
        XCTAssertEqual(coordinator.snapshot.sets[0].start, 19)
        XCTAssertEqual(coordinator.snapshot.sets[0].end, 24)
        XCTAssertEqual(coordinator.snapshot.sets[0].id,
                       "11111111-2222-3333-4444-555555555555-set-1")

        coordinator.consume(batch(at: 25.5, resolvedThrough: 24))
        XCTAssertEqual(coordinator.snapshot.restStartedAt, 24)
        XCTAssertEqual(coordinator.snapshot.elapsedRest, 1.5)
        XCTAssertEqual(coordinator.snapshot.status, "Rest · estimated")
        XCTAssertEqual(coordinator.snapshot.intervals.last?.kind, .recovery)
        XCTAssertEqual(coordinator.snapshot.intervals.last?.start, 24)

        coordinator.consume(batch(at: 34, resolvedThrough: 34))
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .sealed)
        XCTAssertEqual(coordinator.snapshot.elapsedRest, 10)
        XCTAssertEqual(coordinator.snapshot.intervals.last?.end, 34)
    }

    func testDelayedContinuationStartingInsideGraceRemainsInSameSet() {
        var coordinator = qualifiedCoordinator()
        coordinator.consume(batch(at: 35, progress: progress(id: "late", start: 33, at: 35),
                                  activity: .moving, candidateStart: 33, resolvedThrough: 30))
        coordinator.consume(batch(at: 42, cycles: cycles([(33, 34), (37, 38), (41, 42)], offset: 3),
                                  activity: .moving, candidateStart: 33, resolvedThrough: 42))

        XCTAssertEqual(coordinator.snapshot.sets.count, 1)
        XCTAssertEqual(coordinator.snapshot.sets[0].count, 6)
        XCTAssertEqual(Set(coordinator.snapshot.sets[0].cycleIDs).count, 6)
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .open)
        let pause = coordinator.snapshot.intervals.first(where: { $0.kind == .intraSetPause })
        XCTAssertEqual(pause?.start, 24)
        XCTAssertEqual(pause?.end, 33)
    }

    func testDelayedBoutStartingAfterGraceCreatesNewSetAtRecoveredStart() {
        var coordinator = qualifiedCoordinator()
        coordinator.consume(batch(at: 35, progress: progress(id: "next", start: 35, at: 35),
                                  activity: .moving, candidateStart: 35, resolvedThrough: 30))
        coordinator.consume(batch(at: 44, cycles: cycles([(35, 36), (39, 40), (43, 44)], offset: 3),
                                  activity: .moving, candidateStart: 35, resolvedThrough: 44))

        XCTAssertEqual(coordinator.snapshot.sets.count, 2)
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .sealed)
        XCTAssertEqual(coordinator.snapshot.sets[1].start, 35)
        XCTAssertEqual(coordinator.snapshot.sets[1].count, 3)
        XCTAssertEqual(coordinator.snapshot.sets[1].id,
                       "11111111-2222-3333-4444-555555555555-set-2")
    }

    func testQualifiedIncompatibleTemplateCreatesImmediateTransitionWithinGrace() {
        var coordinator = qualifiedCoordinator()
        coordinator.consume(batch(at: 31,
                                  cycles: cycles([(25, 26), (27, 28), (30, 31)], offset: 3,
                                                 templateHash: "other-template"),
                                  activity: .moving, candidateStart: 25, resolvedThrough: 31))

        XCTAssertEqual(coordinator.snapshot.sets.count, 2)
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .sealed)
        XCTAssertEqual(coordinator.snapshot.sets[1].start, 25)
        XCTAssertEqual(coordinator.snapshot.sets[1].count, 3)
        XCTAssertEqual(coordinator.snapshot.sets[1].status, .open)
    }

    func testTwoCycleBoutAbstainsAndExpiresAsUnclassifiedActivity() {
        var coordinator = makeCoordinator()
        coordinator.consume(batch(at: 3, cycles: cycles([(0, 1), (2, 3)]), activity: .moving,
                                  candidateStart: 0, resolvedThrough: -1))
        XCTAssertTrue(coordinator.snapshot.sets.isEmpty)
        XCTAssertEqual(coordinator.snapshot.candidateCount, 2)
        XCTAssertEqual(coordinator.snapshot.status, "Confirming movement")

        coordinator.consume(batch(at: 32, resolvedThrough: 32))
        XCTAssertTrue(coordinator.snapshot.sets.isEmpty)
        XCTAssertEqual(coordinator.snapshot.candidateCount, 0)
        let interval = coordinator.snapshot.intervals.last(where: { $0.kind == .unclassified })
        XCTAssertEqual(interval?.start, 0)
        XCTAssertEqual(interval?.end, 3)
        XCTAssertEqual(interval?.provisional, false)
        XCTAssertNil(coordinator.snapshot.restStartedAt)
    }

    func testUnmatchedMovementInterruptsRatherThanFabricatesContinuousRest() {
        var coordinator = qualifiedCoordinator()
        for sample in 0...100 {
            let time = 31 + Double(sample) * 0.02
            coordinator.consume(batch(at: time, activity: .moving, candidateStart: 19,
                                      resolvedThrough: min(27, time - 6)))
        }
        coordinator.consume(batch(at: 34.5, resolvedThrough: 28))

        let recovery = coordinator.snapshot.intervals.filter { $0.kind == .recovery }
        let unclear = coordinator.snapshot.intervals.first { $0.kind == .unclassified }
        XCTAssertEqual(recovery.first?.end, 31)
        XCTAssertEqual(unclear?.start, 31)
        XCTAssertEqual(unclear?.end, 33)
        XCTAssertEqual(coordinator.snapshot.restStartedAt, 33)
    }

    func testDuplicateAndOverlappingExplanationsNeverCountTwice() {
        var coordinator = makeCoordinator()
        let initial = cycles([(0, 1), (2, 3), (4, 5)])
        coordinator.consume(batch(at: 5, cycles: initial, activity: .moving,
                                  candidateStart: 0, resolvedThrough: 0))
        coordinator.consume(batch(at: 6,
                                  cycles: [initial[2], cycle("overlap", 4.5, 5.5)],
                                  activity: .moving, candidateStart: 4.5, resolvedThrough: 0))

        XCTAssertEqual(coordinator.snapshot.cycles.count, 3)
        XCTAssertEqual(coordinator.snapshot.sets[0].count, 3)
    }

    func testDiscontinuitySealsCountAndMarksUnknownCoverage() {
        var coordinator = qualifiedCoordinator()
        coordinator.consume(batch(at: 30, activity: .unavailable, resolvedThrough: 24,
                                  discontinuity: true))

        XCTAssertEqual(coordinator.snapshot.state, .suspended)
        XCTAssertEqual(coordinator.snapshot.sets[0].count, 3)
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .sealed)
        XCTAssertEqual(coordinator.snapshot.intervals.last?.kind, .unavailable)
        XCTAssertNil(coordinator.snapshot.restStartedAt)
    }

    func testUsableNewEpochBatchSealsOldOwnershipAndReacquiresAutomatically() {
        var coordinator = qualifiedCoordinator()
        coordinator.consume(batch(at: 30, activity: .quiet, resolvedThrough: 30,
                                  discontinuity: true))

        XCTAssertEqual(coordinator.snapshot.state, .running)
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .sealed)
        XCTAssertEqual(coordinator.snapshot.sets[0].count, 3)
        XCTAssertEqual(coordinator.snapshot.intervals.last(where: { $0.kind == .unavailable })?.end, 30)
        XCTAssertEqual(coordinator.snapshot.status, "Ready — begin when ready")
    }

    func testFiftyHertzUnclassifiedSamplesCoalesceIntoOneBoundedInterval() {
        var coordinator = makeCoordinator()
        for sample in 0..<200 {
            let time = Double(sample) * 0.02
            coordinator.consume(batch(at: time, activity: .moving, resolvedThrough: -1))
        }

        let unclear = coordinator.snapshot.intervals.filter { $0.kind == .unclassified }
        XCTAssertEqual(unclear.count, 1)
        XCTAssertEqual(unclear[0].start, 0)
        XCTAssertEqual(unclear[0].end, 3.98, accuracy: 0.0001)
    }

    func testPauseAndFinishAreHardCutoffsAndDoNotInventCycles() throws {
        var coordinator = makeCoordinator()
        coordinator.consume(batch(at: 3, cycles: cycles([(0, 1), (2, 3)]), activity: .moving,
                                  candidateStart: 0, resolvedThrough: 0))
        try coordinator.command(.init(kind: .pause, timestamp: 4))
        XCTAssertEqual(coordinator.snapshot.state, .paused)
        XCTAssertTrue(coordinator.snapshot.sets.isEmpty)
        XCTAssertEqual(coordinator.snapshot.cycles.count, 2)

        try coordinator.command(.init(kind: .resume, timestamp: 5))
        try coordinator.command(.init(kind: .finish, timestamp: 6))
        XCTAssertEqual(coordinator.snapshot.state, .finished)
        XCTAssertEqual(coordinator.snapshot.cycles.count, 2)
    }

    func testCountDiscardSplitAndMergeCorrectionsPreserveCycleIdentity() throws {
        var coordinator = makeCoordinator()
        coordinator.consume(batch(at: 5, cycles: cycles([(0, 1), (2, 3), (4, 5)]),
                                  activity: .moving, candidateStart: 0, resolvedThrough: 0))
        let firstID = coordinator.snapshot.sets[0].id
        try coordinator.command(.init(kind: .correction,
                                      correction: .init(kind: .count, setID: firstID, count: 4)))
        XCTAssertEqual(coordinator.snapshot.sets[0].count, 4)

        try coordinator.command(.init(kind: .correction,
                                      correction: .init(kind: .split, setID: firstID,
                                                        afterCycleID: "cycle-1")))
        XCTAssertEqual(coordinator.snapshot.sets.map(\.cycleIDs), [["cycle-0", "cycle-1"], ["cycle-2"]])
        let secondID = coordinator.snapshot.sets[1].id
        try coordinator.command(.init(kind: .correction,
                                      correction: .init(kind: .merge, setID: firstID,
                                                        otherSetID: secondID)))
        XCTAssertEqual(coordinator.snapshot.sets.count, 1)
        XCTAssertEqual(coordinator.snapshot.sets[0].cycleIDs, ["cycle-0", "cycle-1", "cycle-2"])

        try coordinator.command(.init(kind: .correction,
                                      correction: .init(kind: .discard, setID: firstID)))
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .discarded)
    }

    func testDiscardingActiveSetReleasesOwnershipForFutureQualification() throws {
        var coordinator = qualifiedCoordinator()
        let discardedID = coordinator.snapshot.sets[0].id
        try coordinator.command(.init(kind: .correction, timestamp: 26,
                                      correction: .init(kind: .discard, setID: discardedID)))
        coordinator.consume(batch(at: 33, cycles: cycles([(27, 28), (29, 30), (32, 33)], offset: 3),
                                  activity: .moving, candidateStart: 27, resolvedThrough: 33))

        XCTAssertEqual(coordinator.snapshot.sets.count, 2)
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .discarded)
        XCTAssertEqual(coordinator.snapshot.sets[1].count, 3)
        XCTAssertEqual(coordinator.snapshot.sets[1].status, .open)
    }

    func testSplittingActiveSetKeepsTrailingFragmentActive() throws {
        var coordinator = makeCoordinator()
        coordinator.consume(batch(at: 5, cycles: cycles([(0, 1), (2, 3), (4, 5)]),
                                  activity: .moving, candidateStart: 0, resolvedThrough: 0))
        let setID = coordinator.snapshot.sets[0].id
        try coordinator.command(.init(kind: .correction, timestamp: 5.5,
                                      correction: .init(kind: .split, setID: setID,
                                                        afterCycleID: "cycle-1")))
        coordinator.consume(batch(at: 7, cycles: [cycle("cycle-3", 6, 7)],
                                  activity: .moving, candidateStart: 0, resolvedThrough: 2))

        XCTAssertEqual(coordinator.snapshot.sets[0].cycleIDs, ["cycle-0", "cycle-1"])
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .sealed)
        XCTAssertEqual(coordinator.snapshot.sets[1].cycleIDs, ["cycle-2", "cycle-3"])
        XCTAssertEqual(coordinator.snapshot.sets[1].status, .open)
    }

    func testMergingActiveSetPreservesItsBoutOwnership() throws {
        var coordinator = qualifiedCoordinator()
        coordinator.consume(batch(at: 31,
                                  cycles: cycles([(25, 26), (27, 28), (30, 31)], offset: 3,
                                                 templateHash: "other-template"),
                                  activity: .moving, candidateStart: 25, resolvedThrough: 31))
        let firstID = coordinator.snapshot.sets[0].id
        let activeID = coordinator.snapshot.sets[1].id
        try coordinator.command(.init(kind: .correction, timestamp: 31.5,
                                      correction: .init(kind: .merge, setID: firstID,
                                                        otherSetID: activeID)))
        coordinator.consume(batch(at: 33,
                                  cycles: [cycle("cycle-6", 32, 33, templateHash: "other-template")],
                                  activity: .moving, candidateStart: 25, resolvedThrough: 32))

        XCTAssertEqual(coordinator.snapshot.sets.count, 1)
        XCTAssertEqual(coordinator.snapshot.sets[0].count, 7)
        XCTAssertEqual(coordinator.snapshot.sets[0].cycleIDs.last, "cycle-6")
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .open)
    }

    func testSealedFrontierRejectsLateBackfillFromEarlierRest() {
        var coordinator = qualifiedCoordinator()
        coordinator.consume(batch(at: 34, resolvedThrough: 34))
        coordinator.consume(batch(at: 90, cycles: cycles([(30, 31), (32, 33), (33, 33.9)], offset: 20),
                                  activity: .moving, candidateStart: 30, resolvedThrough: 90))

        XCTAssertEqual(coordinator.snapshot.sets.count, 1)
        XCTAssertEqual(coordinator.snapshot.cycles.count, 3)
    }

    func testReplacementProgressDoesNotRefreshCandidateLifetime() {
        var coordinator = makeCoordinator()
        coordinator.consume(batch(at: 1, progress: progress(id: "a", start: 0, at: 1),
                                  activity: .moving, candidateStart: 0, resolvedThrough: -1))
        var replacement = progress(id: "b", start: 20, at: 20)
        replacement.replacement = true
        coordinator.consume(batch(at: 20, progress: replacement, activity: .moving,
                                  candidateStart: 20, resolvedThrough: 10))
        coordinator.consume(batch(at: 32, activity: .quiet, resolvedThrough: 32))

        XCTAssertEqual(coordinator.snapshot.status, "Ready — begin when ready")
        let expired = coordinator.snapshot.intervals.first {
            $0.kind == .unclassified && !$0.provisional && $0.start == 0
        }
        XCTAssertEqual(expired?.end, 32)
    }

    func testResolvedFrontierReleasesPendingBoundaryWhileRecoveryDisplaysEarly() {
        var coordinator = qualifiedCoordinator()
        coordinator.consume(batch(at: 35, progress: progress(id: "incomplete", start: 33, at: 35),
                                  activity: .moving, candidateStart: 19, resolvedThrough: 30))
        coordinator.consume(batch(at: 36.5, activity: .quiet, candidateStart: 19,
                                  resolvedThrough: 33))

        XCTAssertEqual(coordinator.snapshot.restStartedAt, 35)
        XCTAssertEqual(coordinator.snapshot.status, "Rest · estimated")
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .provisional)

        coordinator.consume(batch(at: 37, activity: .quiet, candidateStart: 19,
                                  resolvedThrough: 34))
        XCTAssertEqual(coordinator.snapshot.sets[0].status, .sealed)
        XCTAssertEqual(coordinator.snapshot.restStartedAt, 35)
    }

    func testDiscardedFrontierPreventsStaleEngineOwnershipFromBackdatingIntervals() throws {
        var coordinator = qualifiedCoordinator()
        let setID = coordinator.snapshot.sets[0].id
        try coordinator.command(.init(kind: .correction, timestamp: 26,
                                      correction: .init(kind: .discard, setID: setID)))
        coordinator.consume(batch(at: 27, progress: progress(id: "stale", start: 19, at: 27),
                                  activity: .moving, candidateStart: 19, resolvedThrough: 24))

        let unclear = coordinator.snapshot.intervals.last { $0.kind == .unclassified }
        XCTAssertEqual(unclear?.start, 27)
        XCTAssertEqual(unclear?.end, 27)
        XCTAssertFalse(coordinator.snapshot.intervals.contains {
            $0.kind == .unclassified && $0.start < 26
        })
    }

    private func makeCoordinator() -> AutoSetCoordinator {
        var configuration = AutoWorkoutConfiguration()
        configuration.workoutID = workoutID
        return AutoSetCoordinator(configuration: configuration)
    }

    private func qualifiedCoordinator() -> AutoSetCoordinator {
        var coordinator = makeCoordinator()
        coordinator.consume(batch(at: 24, cycles: cycles([(19, 20), (21, 22), (23, 24)]),
                                  activity: .moving, candidateStart: 19, resolvedThrough: 18))
        coordinator.consume(batch(at: 25.5, resolvedThrough: 24))
        return coordinator
    }

    private func cycles(_ bounds: [(Double, Double)], offset: Int = 0,
                        templateHash: String = "template") -> [AutoCycleEvidence] {
        bounds.enumerated().map { index, bound in
            cycle("cycle-\(index + offset)", bound.0, bound.1, templateHash: templateHash)
        }
    }

    private func cycle(_ id: String, _ start: Double, _ completion: Double,
                       templateHash: String = "template") -> AutoCycleEvidence {
        .init(id: id, sourceEpoch: 0, learningEpoch: 0, templateHash: templateHash,
              start: start, completion: completion, detected: completion,
              authorized: completion, matchCost: 0.1)
    }

    private func progress(id: String, start: Double, at observedAt: Double) -> AutoProgressEvidence {
        .init(traversalID: id, start: start, observedAt: observedAt, meaningfulSections: 1)
    }

    private func batch(at timestamp: Double, cycles: [AutoCycleEvidence] = [],
                       progress: AutoProgressEvidence? = nil, activity: AutoActivity = .quiet,
                       candidateStart: Double? = nil, resolvedThrough: Double,
                       discontinuity: Bool = false) -> AutoEvidenceBatch {
        .init(timestamp: timestamp, cycles: cycles, progress: progress, activity: activity,
              candidateStart: candidateStart, resolvedThrough: resolvedThrough,
              discontinuity: discontinuity)
    }
}

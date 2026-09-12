import XCTest
@testable import LiftPod

@MainActor
final class AutoWorkoutFlowTests: XCTestCase {
    func testMergedCoachWaitsForSealedSetAndRetainsAdviceAcrossSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var requests: [AISetRequest] = []
        let model = WorkoutModel(sessionDirectory: directory, historyFileURL: directory.appendingPathComponent("history.json"),
            analyzeAI: { input, _, _ in
                requests.append(input)
                return .init(estimatedRIR: nil, notes: "Sealed set only", weakPoints: [], nextSet: nil)
            })
        model.automaticSets = true
        let reps = cycles("merged", count: 3, start: 1)
        var set = AutoSetRecord(id: "merged-set", cycleIDs: reps.map(\.id), start: reps[0].start, end: reps[2].completion)
        model.synchronizeAutomatic(snapshot: snapshot(sets: [set], cycles: reps, timestamp: 10, rest: 8, status: "Recovery"))
        XCTAssertFalse(model.canAnalyzeLatestSet)
        await model.analyzeLatestSet(model: "stub", apiKey: "")
        XCTAssertTrue(requests.isEmpty)
        set.status = .sealed; set.sealedAt = 20
        let sealed = snapshot(sets: [set], cycles: reps, timestamp: 20, rest: 8, status: "Recovery")
        model.synchronizeAutomatic(snapshot: sealed)
        XCTAssertTrue(model.canAnalyzeLatestSet)
        await model.analyzeLatestSet(model: "stub", apiKey: "")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.reps.count, 3)
        model.synchronizeAutomatic(snapshot: sealed)
        XCTAssertEqual(model.latestSetResult?.aiAdvice?.notes, "Sealed set only")
    }
    func testReadyLiveRestContinuationAndNewSetProjection() throws {
        let model = makeModel()
        model.automaticSets = true

        model.synchronizeAutomatic(snapshot: snapshot(state: .running, status: "Ready"))
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.betweenSets)

        let first = cycles("a", count: 3, start: 1)
        var setOne = AutoSetRecord(id: "auto-set-1", cycleIDs: first.map(\.id),
                                   start: first[0].start, end: first[2].completion)
        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne], cycles: first,
                                                       timestamp: 8, status: "Set 1 · 3 reps"))
        XCTAssertEqual(model.reps, 3)
        XCTAssertEqual(model.session?.current?.id, setOne.id)

        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne], cycles: first,
                                                       timestamp: 10, rest: 8,
                                                       status: "Rest · estimated"))
        XCTAssertTrue(model.betweenSets)
        XCTAssertTrue(model.automaticRecoveryProvisional)
        let provisionalID = try XCTUnwrap(model.latestSetResult?.id)
        let provisionalFinishedAt = try XCTUnwrap(model.latestSetResult?.finishedAt)
        XCTAssertTrue(model.pendingSetReviews.isEmpty)

        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne], cycles: first,
                                                       timestamp: 10.5,
                                                       status: "Movement unclear"))
        XCTAssertTrue(model.betweenSets)
        XCTAssertNil(model.session?.current)
        XCTAssertEqual(model.latestSetResult?.id, provisionalID)

        let continuedCycles = first + cycles("a", count: 1, start: 9, offset: 3)
        setOne.cycleIDs = continuedCycles.map(\.id)
        setOne.end = continuedCycles.last!.completion
        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne], cycles: continuedCycles,
                                                       timestamp: 12, status: "Set 1 · 4 reps"))
        XCTAssertEqual(model.session?.current?.id, setOne.id)
        XCTAssertFalse(model.betweenSets)
        XCTAssertTrue(model.completedSetResults.isEmpty)

        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne], cycles: continuedCycles,
                                                       timestamp: 14, rest: 12,
                                                       status: "Rest · estimated"),
                                   now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(model.latestSetResult?.id, provisionalID)
        XCTAssertEqual(model.latestSetResult?.reps, 4)
        XCTAssertNotEqual(model.latestSetResult?.finishedAt, provisionalFinishedAt)

        setOne.status = .sealed
        setOne.sealedAt = 20
        let second = cycles("b", count: 3, start: 21)
        let setTwo = AutoSetRecord(id: "auto-set-2", cycleIDs: second.map(\.id),
                                   start: second[0].start, end: second[2].completion)
        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne, setTwo],
                                                       cycles: continuedCycles + second,
                                                       timestamp: 28, status: "Set 2 · 3 reps"))
        XCTAssertEqual(model.completedSetResults.map(\.id), [provisionalID])
        XCTAssertEqual(model.session?.current?.id, setTwo.id)
        XCTAssertEqual(model.pendingSetReviews.map(\.id), [setOne.id])
    }

    func testCandidateDuringRestDoesNotBringOldSetLive() {
        let model = makeModel()
        model.automaticSets = true
        let reps = cycles("a", count: 3, start: 1)
        let set = AutoSetRecord(id: "auto-set-1", cycleIDs: reps.map(\.id),
                                start: reps[0].start, end: reps[2].completion)
        var value = snapshot(sets: [set], cycles: reps, timestamp: 10,
                             rest: 8, status: "Rest · estimated")
        model.synchronizeAutomatic(snapshot: value)
        value.restStartedAt = nil
        value.candidateCount = 1
        value.status = "Finding your next set"
        model.synchronizeAutomatic(snapshot: value)
        XCTAssertTrue(model.betweenSets)
        XCTAssertNil(model.session?.current)
        XCTAssertEqual(model.automaticStatus, "Finding your next set")
    }

    func testPrescriptionIsFrozenByStableAutomaticSetIdentity() throws {
        let model = makeModel(load: 20)
        model.automaticSets = true
        let first = cycles("a", count: 3, start: 1)
        var setOne = AutoSetRecord(id: "auto-set-1", cycleIDs: first.map(\.id),
                                   start: first[0].start, end: first[2].completion)
        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne], cycles: first,
                                                       timestamp: 9, rest: 8))
        model.prescription.loadLB = 30

        let continued = first + cycles("a", count: 1, start: 10, offset: 3)
        setOne.cycleIDs = continued.map(\.id)
        setOne.end = continued.last!.completion
        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne], cycles: continued,
                                                       timestamp: 13))
        XCTAssertEqual(model.session?.current?.prescription.loadLB, 20)

        setOne.status = .sealed
        let second = cycles("b", count: 3, start: 20)
        let setTwo = AutoSetRecord(id: "auto-set-2", cycleIDs: second.map(\.id),
                                   start: second[0].start, end: second[2].completion)
        model.synchronizeAutomatic(snapshot: snapshot(sets: [setOne, setTwo],
                                                       cycles: continued + second,
                                                       timestamp: 27))
        XCTAssertEqual(model.completedSets.first?.prescription.loadLB, 20)
        XCTAssertEqual(model.session?.current?.prescription.loadLB, 30)
    }

    func testSealedPauseSuspendAndFinishNeverDuplicateReviews() {
        for lifecycle in [AutoWorkoutState.paused, .suspended, .finished] {
            let model = makeModel()
            model.automaticSets = true
            let reps = cycles("a", count: 3, start: 1)
            var set = AutoSetRecord(id: "auto-set-1", cycleIDs: reps.map(\.id),
                                    start: reps[0].start, end: reps[2].completion,
                                    status: .sealed, sealedAt: 9)
            let value = snapshot(state: lifecycle, sets: [set], cycles: reps,
                                 timestamp: 9, status: lifecycle.rawValue)
            model.synchronizeAutomatic(snapshot: value)
            model.synchronizeAutomatic(snapshot: value)
            XCTAssertEqual(model.pendingSetReviews.count, 1)
            XCTAssertEqual(model.completedSetResults.count, 1)
            XCTAssertFalse(model.automaticRecoveryProvisional)
            if lifecycle == .finished { XCTAssertNotNil(model.result) }
            set.correctedCount = 4
        }
    }

    func testManualReducerIgnoresAutomaticProjection() {
        var reducer = WorkoutSessionReducer(prescription: WorkoutPrescription())
        reducer.apply(.rep(.init(id: "manual", start: 1, end: 3)))
        let before = reducer.current
        reducer.projectAutomatic(snapshot(sets: [], cycles: [], timestamp: 4),
                                 prescriptions: [:], liveSetID: nil)
        XCTAssertEqual(reducer.current, before)
        XCTAssertEqual(reducer.policy.version, "manual-sets-v1")
    }

    func testBindingDoesNotReplayFinishedCaptureIntoResetWorkout() {
        let model = makeModel()
        model.automaticSets = true
        let reps = cycles("old", count: 3, start: 1)
        let oldSet = AutoSetRecord(id: "old-set", cycleIDs: reps.map(\.id),
                                   start: reps[0].start, end: reps[2].completion,
                                   status: .sealed, sealedAt: 8)
        let finished = snapshot(state: .finished, sets: [oldSet], cycles: reps,
                                timestamp: 8, status: "Workout finished")
        model.synchronizeAutomatic(snapshot: finished)
        XCTAssertEqual(model.pendingSetReviews.count, 1)
        model.reset()

        let capture = CaptureModel()
        capture.autoWorkout.apply(snapshot: finished)
        model.bindAutoWorkout(capture)

        XCTAssertEqual(model.automaticState, .idle)
        XCTAssertNil(model.session)
        XCTAssertEqual(model.pendingSetReviews.count, 1)
    }

    private func makeModel(load: Double? = 25) -> WorkoutModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = WorkoutModel(sessionDirectory: root,
                                 historyFileURL: root.appendingPathComponent("history.json"))
        model.prescription.loadLB = load
        return model
    }

    private func snapshot(
        state: AutoWorkoutState = .running,
        sets: [AutoSetRecord] = [],
        cycles: [AutoCycleEvidence] = [],
        timestamp: Double = 0,
        rest: Double? = nil,
        status: String = "Set"
    ) -> AutoWorkoutSnapshot {
        var value = AutoWorkoutSnapshot()
        value.state = state
        value.sets = sets
        value.cycles = cycles
        value.timestamp = timestamp
        value.restStartedAt = rest
        value.status = status
        return value
    }

    private func cycles(_ prefix: String, count: Int, start: Double, offset: Int = 0)
        -> [AutoCycleEvidence] {
        (0..<count).map { local in
            let index = local + offset
            let begin = start + Double(local) * 2
            return AutoCycleEvidence(id: "\(prefix)-\(index)", sourceEpoch: 0,
                learningEpoch: 0, templateHash: prefix, start: begin, completion: begin + 1,
                detected: begin + 1.1, authorized: begin + 1.2, matchCost: 0.1)
        }
    }
}

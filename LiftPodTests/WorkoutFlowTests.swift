import XCTest
@testable import LiftPod

final class WorkoutSummaryTests: XCTestCase {
    func testRestRecommendationUsesRepsAndProximityToFailure() throws {
        XCTAssertEqual(try XCTUnwrap(RestRecommendation(reps: 8, repsInReserve: 3)).seconds, 90)
        XCTAssertEqual(try XCTUnwrap(RestRecommendation(reps: 8, repsInReserve: 2)).seconds, 120)
        XCTAssertEqual(try XCTUnwrap(RestRecommendation(reps: 8, repsInReserve: 1)).seconds, 150)
        XCTAssertEqual(try XCTUnwrap(RestRecommendation(reps: 8, repsInReserve: 0)).seconds, 180)
        XCTAssertEqual(try XCTUnwrap(RestRecommendation(reps: 12, repsInReserve: 2)).seconds, 150)
        XCTAssertNil(RestRecommendation(reps: 12, repsInReserve: 5))
    }

    func testLedgerKeepsMoreThanTwelveRepsAndIgnoresDuplicatesAndRejectedCycles() {
        var ledger = WorkoutRepLedger()
        let events = (0..<20).map { event($0) }
        ledger.observe(Array(events.prefix(12)))
        ledger.observe(Array(events.suffix(12)))
        var rejected = event(21); rejected.committed = false
        ledger.observe([rejected])
        XCTAssertEqual(ledger.events.count, 20)
        XCTAssertEqual(ledger.averageDuration, 2)
        XCTAssertEqual(ledger.movementDuration, 59)
    }

    func testInvalidPrescriptionAndInterruptedTarget() {
        var prescription = WorkoutPrescription()
        prescription.loadLB = .nan
        XCTAssertFalse(prescription.isValid)
        prescription.loadLB = 25
        prescription.minimumReps = 15
        XCTAssertFalse(prescription.isValid)
        prescription.minimumReps = 8
        let result = WorkoutSetResult(id: UUID(), prescription: prescription, reps: 10,
                                      averageRepDuration: 2, movementDuration: 20,
                                      interrupted: true, finishedAt: Date())
        XCTAssertEqual(result.targetDescription, "Interrupted — target not assessed")
    }

    private func event(_ index: Int) -> V2CycleEvidence {
        .init(id: "rep-\(index)", setID: v2Descriptor().setID, exercise: .bicepsCurl,
              authorizationSource: .manual, profileID: "test", dspContentHash: "test", detectorEpoch: 0,
              cycleSequence: index, startTimestamp: Double(index * 3), topTimestamp: Double(index * 3 + 1),
              completionTimestamp: Double(index * 3 + 2), detectionTimestamp: Double(index * 3 + 2),
              bottom: 0, top: 1, returned: 0, outboundArea: 1, returnArea: 1, committed: true)
    }
}

@MainActor
final class WorkoutCaptureRoutingTests: XCTestCase {
    func testCompletedWorkoutFreezesInputsAndSavesSummary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = MockMotionProvider()
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        let model = WorkoutModel(makeRecorder: { V2SessionRecorder(directory: directory) },
                                 historyFileURL: directory.appendingPathComponent("history.json"))
        capture.startMotion()
        provider.emit(.sample(experimentalRawSample(index: 0, time: 0,
            receiptTime: ProcessInfo.processInfo.systemUptime)))
        for _ in 0..<1000 { if capture.latestSample != nil { break }; await Task.yield() }
        model.mountConfirmed = true
        await model.start(capture)
        XCTAssertEqual(model.state, .preparing)
        model.prescription.loadLB = 40
        // A physical rotation with unit gravity and matching angular velocity
        // exercises the default adaptive V6 path, not the legacy scalar detector.
        var samples: [(Double, Double)] = Array(repeating: (0, 0), count: 180)
        for _ in 0..<3 {
            samples += (1...100).map { (Double($0) * 0.024, 1.2) }
            samples += (1...100).map { (2.4 - Double($0) * 0.024, -1.2) }
            samples += Array(repeating: (0, 0), count: 30)
        }
        func raw(_ index: Int, angle: Double = 0, rate: Double = 0) -> RawMotionSample {
            experimentalRawSample(index: UInt64(index), time: Double(index) * 0.02,
                gravity: .init(x: 0, y: sin(angle), z: cos(angle)),
                rotation: .init(x: rate, y: 0, z: 0))
        }
        for (index, sample) in samples.enumerated() {
            await model.ingest(raw(index, angle: sample.0, rate: sample.1))
        }
        XCTAssertEqual(model.state, .active)
        XCTAssertGreaterThan(model.reps, 0)
        XCTAssertNotNil(model.currentPace)
        XCTAssertGreaterThan(model.activeTime, 0)
        XCTAssertLessThan(model.activeTime, model.elapsedTime)
        await model.end()
        XCTAssertEqual(model.state, .finalizing)
        for index in samples.count..<(samples.count + 25) { await model.ingest(raw(index)) }
        XCTAssertEqual(model.state, .complete)
        let result = try XCTUnwrap(model.result)
        XCTAssertEqual(result.prescription.loadLB, 25)
        XCTAssertFalse(result.interrupted)
        let saved = try JSONDecoder().decode(WorkoutSetResult.self, from: Data(contentsOf: XCTUnwrap(model.summaryURL)))
        XCTAssertEqual(saved.reps, result.reps)
        XCTAssertEqual(saved.prescription, result.prescription)
        let profileURL = try XCTUnwrap(model.summaryURL).deletingLastPathComponent()
            .appendingPathComponent("experimental-v6-profile.json")
        let recordedProfile = try JSONDecoder().decode(V2DSPProfile.self, from: Data(contentsOf: profileURL))
        XCTAssertEqual(recordedProfile.profileID, V2DSPProfile.adaptiveCurlV6.profileID)
        XCTAssertEqual(recordedProfile.identity.algorithm, .adaptiveAxis)
        XCTAssertEqual(model.pendingSetReviews.count, model.completedSets.count)
        let draft = try XCTUnwrap(model.pendingSetReviews.first)
        XCTAssertTrue(model.confirmSet(draft, loadLB: 30, reps: 12, repsInReserve: 2))
        XCTAssertEqual(model.history.sets.first?.loadLB, 30)
        XCTAssertEqual(model.history.sets.first?.reps, 12)
        XCTAssertEqual(model.history.sets.first?.repsInReserve, 2)
        await capture.stopMotion()
    }

    func testDeveloperLabDefaultsToAdaptiveV6() {
        let model = ExperimentalV2Model()
        XCTAssertEqual(model.selectedAlgorithm, .adaptiveAxis)
        XCTAssertEqual(model.profile?.profileID, V2DSPProfile.adaptiveCurlV6.profileID)
        model.selectedExercise = .bicepsCurl
        XCTAssertEqual(model.profile?.identity.algorithm, .adaptiveAxis)
    }

    func testSilentStreamInterruptionEndsPreparation() async {
        let provider = MockMotionProvider()
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        let model = WorkoutModel(makeRecorder: { V2TestRecorder() })
        capture.startMotion()
        provider.emit(.sample(experimentalRawSample(index: 0, time: 0,
            receiptTime: ProcessInfo.processInfo.systemUptime)))
        for _ in 0..<1000 { if capture.latestSample != nil { break }; await Task.yield() }
        model.mountConfirmed = true
        await model.start(capture)
        XCTAssertEqual(model.state, .preparing)
        await model.checkStaleness(now: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(model.state, .interrupted)
        XCTAssertTrue(model.result?.interrupted == true)
        await capture.stopMotion()
    }

    func testEveryCallbackReachesConsumerInOrderAndStopNotifiesIt() async {
        let provider = MockMotionProvider()
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        let consumer = TestWorkoutConsumer()
        capture.workoutConsumer = consumer
        capture.startMotion()
        for index in 0..<100 { provider.emit(.sample(makeSample(index: UInt64(index)))) }
        for _ in 0..<1000 {
            if consumer.indices.count == 100 { break }
            await Task.yield()
        }
        XCTAssertEqual(consumer.indices, (0..<100).map(UInt64.init))
        await capture.stopMotion()
        XCTAssertEqual(consumer.interruptions, 1)
    }

    func testLiveMotionDistinguishesSideAndExpiresWithoutCallbacks() async {
        let provider = MockMotionProvider()
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        let model = WorkoutModel()
        capture.startMotion()
        let receipt = ProcessInfo.processInfo.systemUptime
        provider.emit(.sample(experimentalRawSample(index: 0, time: 0, receiptTime: receipt)))
        for _ in 0..<1000 { if capture.latestSample != nil { break }; await Task.yield() }
        XCTAssertEqual(capture.liveSensor(now: receipt + 0.3), .rightHeadphone)
        XCTAssertTrue(model.signalReady(capture, now: receipt + 0.3))
        XCTAssertNil(capture.liveSensor(now: receipt + 0.5))
        XCTAssertNil(capture.liveSensor(now: receipt - 0.1))
        provider.emit(.sample(makeSample(index: 1, receiptUptime: receipt + 0.1)))
        for _ in 0..<1000 { if capture.latestSample?.index == 1 { break }; await Task.yield() }
        XCTAssertEqual(capture.liveSensor(now: receipt + 0.2), .leftHeadphone)
        XCTAssertFalse(model.signalReady(capture, now: receipt + 0.2))
        await capture.stopMotion()
        XCTAssertNil(capture.liveSensor(now: receipt + 0.2))
    }

    func testStartRequiresLiveRightSideAndConfirmedMount() async {
        let provider = MockMotionProvider()
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        let model = WorkoutModel()
        capture.startMotion()
        provider.emit(.sample(makeSample(receiptUptime: ProcessInfo.processInfo.systemUptime)))
        for _ in 0..<100 { if capture.latestSample != nil { break }; await Task.yield() }
        model.mountConfirmed = true
        XCTAssertFalse(model.canStart(capture), "A live left AirPod must not authorize a right-side profile")
        XCTAssertFalse(model.signalReady(capture, now: ProcessInfo.processInfo.systemUptime + 1))
        await capture.stopMotion()
    }
}

@MainActor
final class WorkoutHistoryTests: XCTestCase {
    func testConfirmedSetsPersistByDayAndDuplicateSourceIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workouts.json")
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: .init(),
                             reps: [.init(id: "rep-1", start: 0, end: 2)])
        let draft = SetReviewDraft(sessionID: UUID(), set: set,
                                   endedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(store.confirm(draft, loadLB: 30, reps: 12, repsInReserve: 2))
        XCTAssertTrue(store.confirm(draft, loadLB: 35, reps: 8, repsInReserve: 1))
        XCTAssertEqual(store.sets.count, 1)
        XCTAssertEqual(store.days.count, 1)
        XCTAssertEqual(store.days[0].totalVolumeLB, 360)

        let restored = WorkoutHistoryStore(fileURL: file)
        XCTAssertEqual(restored.sets, store.sets)
    }

    func testPredictionUsesConfirmedRepsAndRIRAndRoundsToEquipmentIncrement() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: .init(),
                             reps: [.init(id: "rep-1", start: 0, end: 2)])
        let draft = SetReviewDraft(sessionID: UUID(), set: set)
        XCTAssertTrue(store.confirm(draft, loadLB: 30, reps: 12, repsInReserve: 2))
        let prediction = store.prediction(for: .bicepsCurl, targetReps: 8, targetRIR: 2)
        XCTAssertEqual(prediction?.estimatedCapacityLB ?? 0, 58.2185, accuracy: 0.001)
        XCTAssertEqual(prediction?.loadLB, 35)
        XCTAssertEqual(prediction?.sourceCount, 1)
        XCTAssertEqual(prediction?.confidence, .low)
    }

    func testPredictionRequiresRIRRatherThanInventingEffort() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: .init(),
                             reps: [.init(id: "rep-1", start: 0, end: 2)])
        XCTAssertTrue(store.confirm(SetReviewDraft(sessionID: UUID(), set: set),
                                    loadLB: 30, reps: 12, repsInReserve: nil))
        XCTAssertNil(store.prediction(for: .bicepsCurl, targetReps: 8, targetRIR: 2))
    }

    func testPredictionCombinesConsistentConfirmedSets() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        for index in 0..<3 {
            let set = SessionSet(id: "set-\(index)", prescription: .init(),
                                 reps: [.init(id: "rep-\(index)", start: 0, end: 2)])
            XCTAssertTrue(store.confirm(SetReviewDraft(sessionID: UUID(), set: set,
                endedAt: Date().addingTimeInterval(Double(index))),
                loadLB: 30, reps: 12, repsInReserve: 2))
        }
        let prediction = store.prediction(for: .bicepsCurl, targetReps: 8, targetRIR: 2)
        XCTAssertEqual(prediction?.loadLB, 35)
        XCTAssertEqual(prediction?.sourceCount, 3)
        XCTAssertEqual(prediction?.confidence, .medium)
    }
}

@MainActor
private final class TestWorkoutConsumer: WorkoutMotionConsumer {
    var indices: [UInt64] = []
    var interruptions = 0
    func ingest(_ sample: RawMotionSample) async { indices.append(sample.index) }
    func motionUnavailable() async { interruptions += 1 }
}

final class AutomaticSetBoundaryTests: XCTestCase {
    func testSuggestedRestNeverBlocksTheNextSet() {
        var session = WorkoutSessionReducer(prescription: .init())
        session.apply(.rep(.init(id: "first", start: 0, end: 2)))
        session.apply(.clock(14))
        XCTAssertNil(session.current)

        // Only 18 seconds have elapsed since the prior rep. The next rep still
        // starts a set because suggested rest is display-only.
        session.apply(.rep(.init(id: "next", start: 20, end: 22)))
        XCTAssertEqual(session.current?.reps.map(\.id), ["next"])
        XCTAssertEqual(session.sets.count, 1)
    }

    func testSetEndsAtTwelveSecondsNotBeforeAndNoEmptySetsAppear() {
        var session = WorkoutSessionReducer(prescription: .init())
        session.apply(.clock(50))
        XCTAssertTrue(session.sets.isEmpty)
        session.apply(.rep(.init(id: "one", start: 50, end: 52)))
        session.apply(.clock(63.999))
        XCTAssertEqual(session.current?.reps.count, 1)
        session.apply(.clock(64))
        XCTAssertNil(session.current)
        XCTAssertEqual(session.sets.count, 1)
        XCTAssertEqual(session.sets[0].end, 52)
        session.apply(.clock(100))
        XCTAssertEqual(session.sets.count, 1)
    }

    func testCompletedRepResetsTimerAndNextSetStartsWithoutButton() {
        var session = WorkoutSessionReducer(prescription: .init())
        session.apply(.rep(.init(id: "one", start: 0, end: 2)))
        session.apply(.clock(10))
        session.apply(.rep(.init(id: "two", start: 10, end: 12)))
        session.apply(.clock(23.99))
        XCTAssertEqual(session.current?.reps.count, 2)
        session.apply(.clock(24))
        // A movement already underway at timeout belongs to the next set on completion.
        session.apply(.rep(.init(id: "three", start: 23, end: 25)))
        XCTAssertEqual(session.current?.reps.count, 1)
        XCTAssertEqual(session.sets[0].reps.count, 2)
    }

    func testDuplicatesInvalidRepsAndManualBoundaryDoNotResetOrInflateCount() {
        var session = WorkoutSessionReducer(prescription: .init())
        let first = SessionRep(id: "one", start: 0, end: 2)
        session.apply(.rep(first))
        session.apply(.rep(first))
        session.apply(.rep(.init(id: "bad", start: 10, end: 10.1)))
        session.apply(.clock(14))
        XCTAssertEqual(session.sets[0].reps.count, 1)
        session.apply(.rep(.init(id: "two", start: 15, end: 17)))
        session.apply(.closeSet(18))
        session.apply(.rep(.init(id: "crossing", start: 17.5, end: 20)))
        XCTAssertNil(session.current)
    }

    func testInterruptionAndReplayPreserveSetsAndFrozenInputs() throws {
        let original = WorkoutPrescription()
        var session = WorkoutSessionReducer(prescription: original)
        session.apply(.rep(.init(id: "one", start: 0, end: 2)))
        var changed = original; changed.loadLB = 40
        session.apply(.selection(changed))
        session.apply(.clock(14))
        session.apply(.rep(.init(id: "two", start: 15, end: 17)))
        session.apply(.end(18, interrupted: true))
        XCTAssertEqual(session.sets.map { $0.prescription.loadLB }, [25, 40])
        XCTAssertTrue(session.sets[1].interrupted)
        let archive = WorkoutSessionArchive(schemaVersion: 1, sessionID: UUID(), initialPrescription: original,
            policy: session.policy, inputs: session.inputs, sets: session.sets, interrupted: true, recordingDirectory: nil)
        let saved = try JSONDecoder().decode(WorkoutSessionArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(saved.replay().sets, session.sets)
    }
}

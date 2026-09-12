import XCTest
@testable import LiftPod

final class WorkoutSummaryTests: XCTestCase {
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
        let model = WorkoutModel(makeRecorder: { V2SessionRecorder(directory: directory) })
        capture.startMotion()
        provider.emit(.sample(experimentalRawSample(index: 0, time: 0,
            receiptTime: ProcessInfo.processInfo.systemUptime)))
        for _ in 0..<1000 { if capture.latestSample != nil { break }; await Task.yield() }
        model.mountConfirmed = true
        await model.start(capture)
        XCTAssertEqual(model.state, .preparing)
        model.prescription.loadLB = 40
        var samples = Array(repeating: -0.5, count: 180)
        for _ in 0..<3 {
            samples += v2CurlSignals(bottom: -0.5, top: 0.6, returned: -0.5)
            samples += Array(repeating: -0.5, count: 30)
        }
        for (index, signal) in samples.enumerated() { await model.ingest(v2Raw(index, signal: signal)) }
        XCTAssertEqual(model.state, .active)
        XCTAssertGreaterThan(model.reps, 0)
        await model.end()
        XCTAssertEqual(model.state, .finalizing)
        for index in samples.count..<(samples.count + 25) { await model.ingest(v2Raw(index)) }
        XCTAssertEqual(model.state, .complete)
        let result = try XCTUnwrap(model.result)
        XCTAssertEqual(result.prescription.loadLB, 25)
        XCTAssertFalse(result.interrupted)
        let saved = try JSONDecoder().decode(WorkoutSetResult.self, from: Data(contentsOf: XCTUnwrap(model.summaryURL)))
        XCTAssertEqual(saved.reps, result.reps)
        XCTAssertEqual(saved.prescription, result.prescription)
        await capture.stopMotion()
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
private final class TestWorkoutConsumer: WorkoutMotionConsumer {
    var indices: [UInt64] = []
    var interruptions = 0
    func ingest(_ sample: RawMotionSample) async { indices.append(sample.index) }
    func motionUnavailable() async { interruptions += 1 }
}

final class AutomaticSetBoundaryTests: XCTestCase {
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

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

    func testVelocityLossRaisesButDoesNotStackWithRIRRecommendation() throws {
        let moderate = try XCTUnwrap(RestRecommendation(
            reps: 8, repsInReserve: 2, velocityLossPercent: 30
        ))
        XCTAssertEqual(moderate.seconds, 240)
        XCTAssertEqual(moderate.basis, .velocityLoss(percent: 30))

        let high = try XCTUnwrap(RestRecommendation(
            reps: 12, repsInReserve: 0, velocityLossPercent: 40
        ))
        XCTAssertEqual(high.seconds, 300)
        XCTAssertEqual(high.basis, .velocityLoss(percent: 40))
    }

    func testPerformanceDropScalesObservedRestAndNeverShortensIt() throws {
        let dropped = try XCTUnwrap(RestRecommendation(
            reps: 8, repsInReserve: 0, precedingRestSeconds: 180,
            previousReps: 10, previousRepsInReserve: 0
        ))
        XCTAssertEqual(dropped.seconds, 220)
        XCTAssertEqual(dropped.basis, .performanceDrop(percent: 20))

        let stable = try XCTUnwrap(RestRecommendation(
            reps: 9, repsInReserve: 0, precedingRestSeconds: 180,
            previousReps: 10, previousRepsInReserve: 0
        ))
        XCTAssertEqual(stable.seconds, 180)
        XCTAssertEqual(stable.basis, .rir)
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

    func testPrescriptionTargetDefaultsAndLegacyDecode() throws {
        let legacy = Data(#"{"exercise":"Biceps Curl","goal":"Build muscle","loadLB":25,"minimumReps":8,"maximumReps":12}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkoutPrescription.self, from: legacy)
        XCTAssertEqual(decoded.targetRIR, 2)
        XCTAssertEqual(decoded.equipmentIncrementLB, 5)
        XCTAssertTrue(decoded.isValid)
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
        let model = WorkoutModel(sessionDirectory: directory,
                                 historyFileURL: directory.appendingPathComponent("history.json"))
        capture.startMotion()
        provider.emit(.sample(experimentalRawSample(index: 0, time: 0,
            receiptTime: ProcessInfo.processInfo.systemUptime)))
        for _ in 0..<1000 { if capture.latestSample != nil { break }; await Task.yield() }
        model.mountConfirmed = true
        await model.start(capture)
        XCTAssertEqual(model.state, .active)
        model.prescription.loadLB = 40
        // Repeated physical cycles teach and exercise the default generic detector.
        func raw(_ index: Int) -> RawMotionSample {
            let time = Double(index) / 50
            let phase = 2 * Double.pi * time / 2
            return experimentalRawSample(index: UInt64(index), time: time,
                acceleration: .init(x: 0.35 * cos(phase), y: 0.105 * sin(phase), z: 0),
                gravity: .init(x: 0, y: 0, z: -1))
        }
        for index in 0...510 { await model.ingest(raw(index)) }
        XCTAssertEqual(model.state, .active)
        XCTAssertGreaterThan(model.reps, 0)
        XCTAssertNotNil(model.currentPace)
        XCTAssertGreaterThan(model.activeTime, 0)
        XCTAssertLessThan(model.activeTime, model.elapsedTime)
        await model.end()
        XCTAssertEqual(model.state, .finalizing)
        for index in 511...545 { await model.ingest(raw(index)) }
        XCTAssertEqual(model.state, .complete)
        let result = try XCTUnwrap(model.result)
        XCTAssertEqual(result.prescription.loadLB, 25)
        XCTAssertFalse(result.interrupted)
        let saved = try JSONDecoder().decode(WorkoutSetResult.self, from: Data(contentsOf: XCTUnwrap(model.summaryURL)))
        XCTAssertEqual(saved.reps, result.reps)
        XCTAssertEqual(saved.prescription, result.prescription)
        let recordingDirectory = try XCTUnwrap(model.summaryURL).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recordingDirectory.appendingPathComponent("generic-configuration.json").path))
        XCTAssertEqual(model.pendingSetReviews.count, model.completedSets.count)
        let draft = try XCTUnwrap(model.pendingSetReviews.first)
        XCTAssertTrue(model.confirmSet(draft, loadLB: 30, reps: 12, repsInReserve: 2))
        XCTAssertEqual(model.history.sets.first?.loadLB, 30)
        XCTAssertEqual(model.history.sets.first?.reps, 12)
        XCTAssertEqual(model.history.sets.first?.repsInReserve, 2)
        await capture.stopMotion()
    }

    func testDeveloperLabDefaultsToGenericMovement() {
        let model = ExperimentalV2Model()
        XCTAssertEqual(model.countingMode, .generic)
        XCTAssertEqual(model.selectedAlgorithm, .adaptiveAxis)
        XCTAssertEqual(model.profile?.profileID, V2DSPProfile.adaptiveCurlV6.profileID)
        model.selectedExercise = .bicepsCurl
        XCTAssertEqual(model.profile?.identity.algorithm, .adaptiveAxis)
    }

    func testPrimaryWorkoutSupportsEveryExerciseWithGenericCounting() {
        let model = WorkoutModel()
        for exercise in V2Exercise.allCases {
            model.prescription.exercise = exercise
            XCTAssertTrue(model.supportedExercise)
        }
        model.countingMode = .exercise
        model.prescription.exercise = .bicepsCurl
        XCTAssertEqual(model.selectedProfile?.identity.algorithm, .adaptiveAxis)
        XCTAssertTrue(model.supportedExercise)
        model.prescription.exercise = .lateralRaise
        XCTAssertEqual(model.selectedProfile?.identity.algorithm, .gravityTilt)
        XCTAssertTrue(model.supportedExercise)
        model.prescription.exercise = .overheadPress
        XCTAssertNil(model.selectedProfile)
        XCTAssertFalse(model.supportedExercise)
    }

    func testSilentStreamInterruptionEndsPreparation() async {
        let provider = MockMotionProvider()
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        let model = WorkoutModel()
        capture.startMotion()
        provider.emit(.sample(experimentalRawSample(index: 0, time: 0,
            receiptTime: ProcessInfo.processInfo.systemUptime)))
        for _ in 0..<1000 { if capture.latestSample != nil { break }; await Task.yield() }
        model.mountConfirmed = true
        await model.start(capture)
        XCTAssertEqual(model.state, .active)
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
    func testAdaptiveRestUsesOnlyComparablePrecedingSet() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let sessionID = UUID()
        let first = SessionSet(id: "set-1", prescription: .init(), reps: (0..<10).map {
            .init(id: "a-\($0)", start: Double($0 * 3), end: Double($0 * 3 + 2))
        })
        let second = SessionSet(id: "set-2", prescription: .init(), reps: (0..<8).map {
            .init(id: "b-\($0)", start: Double(200 + $0 * 3), end: Double(202 + $0 * 3))
        })
        XCTAssertTrue(store.confirm(SetReviewDraft(sessionID: sessionID, set: first),
                                    loadLB: 30, reps: 10, repsInReserve: 0))
        let draft = SetReviewDraft(sessionID: sessionID, set: second,
                                   precedingSetID: first.id, precedingRestSeconds: 180)
        XCTAssertTrue(store.confirm(draft, loadLB: 30, reps: 8, repsInReserve: 0))
        let current = try XCTUnwrap(store.sets.first { $0.sourceSetID == second.id })
        XCTAssertEqual(store.restRecommendation(after: current)?.seconds, 220)

        let changedLoad = SetReviewDraft(sessionID: sessionID,
                                         set: SessionSet(id: "set-3", prescription: .init(),
                                             reps: second.reps),
                                         precedingSetID: second.id, precedingRestSeconds: 180)
        XCTAssertTrue(store.confirm(changedLoad, loadLB: 35, reps: 6, repsInReserve: 0))
        let third = try XCTUnwrap(store.sets.first { $0.sourceSetID == "set-3" })
        XCTAssertEqual(store.restRecommendation(after: third)?.seconds, 180)
    }

    func testLegacyWorkoutHistoryDecodesWithoutAdaptiveRestFields() throws {
        let data = Data(#"[{"id":"00000000-0000-0000-0000-000000000001","sessionID":"00000000-0000-0000-0000-000000000002","sourceSetID":"set-1","exercise":"Biceps Curl","loadLB":30,"reps":10,"repsInReserve":2,"performedAt":"2026-01-01T12:00:00Z"}]"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([LoggedWorkoutSet].self, from: data)
        XCTAssertNil(decoded[0].precedingSetID)
        XCTAssertNil(decoded[0].precedingRestSeconds)
    }

    func testColdStartRIRUsesPublishedVelocityLossCurveAndCapsFourPlus() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let profile = SetVelocityProfile(meanLiftingSpeeds: [1.0, 0.96, 0.91, 0.84, 0.76, 0.67, 0.58, 0.50])
        let estimate = store.automaticRIR(for: .bicepsCurl, completedReps: 8,
                                          velocityProfile: profile)
        XCTAssertEqual(estimate?.repsInReserve, 3)
        XCTAssertEqual(estimate?.velocityLossPercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(estimate?.method, .populationHeuristic)
        XCTAssertEqual(estimate?.confidence, .low)
        XCTAssertFalse(estimate?.cappedAtFourPlus ?? true)
    }

    func testIndividualModelLearnsFromCorrectedVelocitySets() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let profiles = [
            SetVelocityProfile(meanLiftingSpeeds: [1.0, 0.9, 0.8, 0.7, 0.6, 0.5]),
            SetVelocityProfile(meanLiftingSpeeds: [0.8, 0.72, 0.64, 0.56, 0.48, 0.4])
        ]
        for (setIndex, profile) in profiles.enumerated() {
            let reps = (0..<6).map {
                SessionRep(id: "set-\(setIndex)-rep-\($0)", start: Double($0 * 3), end: Double($0 * 3 + 2))
            }
            let set = SessionSet(id: "set-\(setIndex)", prescription: .init(), reps: reps)
            let draft = SetReviewDraft(sessionID: UUID(), set: set, velocityProfile: profile)
            XCTAssertTrue(store.confirm(draft, loadLB: 30, reps: 6, repsInReserve: 0))
        }
        let current = SetVelocityProfile(meanLiftingSpeeds: [0.9, 0.81, 0.72, 0.63])
        let estimate = try XCTUnwrap(store.automaticRIR(for: .bicepsCurl, completedReps: 4,
                                                        velocityProfile: current))
        XCTAssertEqual(estimate.repsInReserve, 2)
        XCTAssertEqual(estimate.method, .individualized)
        XCTAssertEqual(estimate.confidence, .medium)
        XCTAssertEqual(estimate.calibrationSetCount, 2)
    }

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

    func testNextSetOptimizerRaisesOneStepWhenSetIsTooEasyAndCandidateFitsRange() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: .init(),
                             reps: [.init(id: "rep-1", start: 0, end: 2)])
        let draft = SetReviewDraft(sessionID: UUID(), set: set)
        XCTAssertTrue(store.confirm(draft, loadLB: 30, reps: 10, repsInReserve: 4))
        let prediction = store.nextSetRecommendation(for: .bicepsCurl,
                                                     repRange: 8...12, targetRIR: 2)
        XCTAssertEqual(prediction?.estimatedCapacityLB ?? 0, 58.2185, accuracy: 0.001)
        XCTAssertEqual(prediction?.loadLB, 35)
        XCTAssertEqual(prediction?.targetReps, 8)
        XCTAssertEqual(prediction?.action, .increase)
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
        XCTAssertNil(store.nextSetRecommendation(for: .bicepsCurl,
                                                 repRange: 8...12, targetRIR: 2))
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
                loadLB: 30, reps: 10, repsInReserve: 4))
        }
        let prediction = store.nextSetRecommendation(for: .bicepsCurl,
                                                     repRange: 8...12, targetRIR: 2)
        XCTAssertEqual(prediction?.loadLB, 35)
        XCTAssertEqual(prediction?.targetReps, 8)
        XCTAssertEqual(prediction?.sourceCount, 3)
        XCTAssertEqual(prediction?.confidence, .medium)
    }

    func testNextSetOptimizerKeepsLoadWhenRepAndRIRTargetsAreMet() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: .init(),
                             reps: [.init(id: "rep-1", start: 0, end: 2)])
        XCTAssertTrue(store.confirm(SetReviewDraft(sessionID: UUID(), set: set),
                                    loadLB: 30, reps: 10, repsInReserve: 2))
        let prediction = store.nextSetRecommendation(for: .bicepsCurl,
                                                     repRange: 8...12, targetRIR: 2)
        XCTAssertEqual(prediction?.loadLB, 30)
        XCTAssertEqual(prediction?.targetReps, 10)
        XCTAssertEqual(prediction?.action, .keep)
    }

    func testNextSetOptimizerLowersOneStepWhenSetIsTooHard() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: .init(),
                             reps: [.init(id: "rep-1", start: 0, end: 2)])
        XCTAssertTrue(store.confirm(SetReviewDraft(sessionID: UUID(), set: set),
                                    loadLB: 30, reps: 8, repsInReserve: 0))
        let prediction = store.nextSetRecommendation(for: .bicepsCurl,
                                                     repRange: 8...12, targetRIR: 2)
        XCTAssertEqual(prediction?.loadLB, 25)
        XCTAssertEqual(prediction?.targetReps, 10)
        XCTAssertEqual(prediction?.action, .decrease)
    }

    func testNextSetOptimizerKeepsLoadWhenRepAndRIREvidenceConflict() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: .init(),
                             reps: [.init(id: "rep-1", start: 0, end: 2)])
        XCTAssertTrue(store.confirm(SetReviewDraft(sessionID: UUID(), set: set),
                                    loadLB: 30, reps: 6, repsInReserve: 4))
        let prediction = store.nextSetRecommendation(for: .bicepsCurl,
                                                     repRange: 8...12, targetRIR: 2)
        XCTAssertEqual(prediction?.loadLB, 30)
        XCTAssertEqual(prediction?.action, .keep)
        XCTAssertTrue(prediction?.explanation.contains("conflicting load signals") == true)
        XCTAssertTrue(prediction?.explanation.contains("6 reps at 4 RIR") == true)
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

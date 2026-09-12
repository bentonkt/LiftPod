import XCTest
@testable import LiftPod

final class WorkoutSummaryTests: XCTestCase {
    func testTwentyRepsWithoutSpeedRecommendOneHeavierStepAndRest() throws {
        let result = WorkoutSetResult(id: UUID(), prescription: weightedPrescription(), reps: 20,
            averageRepDuration: nil, movementDuration: nil, interrupted: false, finishedAt: Date())
        let plan = WorkoutCoach.nextSetPlan(for: result)
        XCTAssertEqual(plan.action, .considerHeavierLoad)
        XCTAssertEqual(plan.title, "30 lb × 8")
        XCTAssertFalse(plan.explanation.localizedCaseInsensitiveContains("confidence"))
        XCTAssertFalse(plan.explanation.localizedCaseInsensitiveContains("heuristic"))
        let rest = try XCTUnwrap(RestRecommendation(reps: 20, repsInReserve: nil))
        XCTAssertEqual(rest.seconds, 150)
        XCTAssertEqual(rest.basis, .repHeuristic)
        XCTAssertNil(rest.repsInReserve)
    }

    func testRepHeuristicHandlesMissedTargetsAndEquipmentBounds() {
        let lower = WorkoutCoach.repBasedAdjustment(loadLB: 25, reps: 6,
            repRange: 8...12, incrementLB: 2.5)
        XCTAssertEqual(lower.load, 22.5)
        XCTAssertEqual(lower.reps, 8)
        XCTAssertEqual(WorkoutCoach.repBasedAdjustment(loadLB: 0, reps: 2,
            repRange: 8...12, incrementLB: 5).load, 0)
        XCTAssertEqual(WorkoutCoach.repBasedAdjustment(loadLB: 1000, reps: 20,
            repRange: 8...12, incrementLB: 5).load, 1000)
    }

    @MainActor
    func testLatestHighRepSetOverridesOlderModeledHistory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        for index in 0..<2 {
            let set = SessionSet(id: "set-\(index)", prescription: weightedPrescription(),
                reps: [.init(id: "rep-\(index)", start: 0, end: 2)])
            let draft = SetReviewDraft(sessionID: UUID(), set: set,
                endedAt: Date(timeIntervalSince1970: Double(index)))
            XCTAssertTrue(store.confirm(draft, loadLB: 25, reps: index == 0 ? 8 : 20,
                repsInReserve: index == 0 ? 2 : nil))
        }
        let prediction = try XCTUnwrap(store.nextSetRecommendation(for: .bicepsCurl,
            repRange: 8...12, targetRIR: 2))
        XCTAssertEqual(prediction.source.reps, 20)
        XCTAssertEqual(prediction.loadLB, 30)
        XCTAssertEqual(prediction.confidence, .low)
        XCTAssertEqual(store.restRecommendation(after: prediction.source)?.seconds, 150)
        let olderSource = try XCTUnwrap(store.sets.last)
        let provisional = LoggedWorkoutSet(id: UUID(), sessionID: UUID(), sourceSetID: "draft",
            exercise: .bicepsCurl, loadLB: 30, reps: 20, repsInReserve: 2,
            averageRepDuration: nil, performedAt: Date(), velocityProfile: nil,
            rirValueSource: .automaticVelocity, precedingSetID: nil, precedingRestSeconds: nil)
        let immediate = try XCTUnwrap(store.nextSetRecommendation(for: .bicepsCurl,
            repRange: 8...12, targetRIR: 2, latestSource: provisional))
        XCTAssertEqual(immediate.loadLB, 35)
        XCTAssertEqual(immediate.source.sourceSetID, "draft")
        XCTAssertEqual(store.sets.count, 2, "Provisional advice must not confirm a set")
        XCTAssertEqual(olderSource.reps, 8)

    }

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

final class ManualWorkoutFlowTests: XCTestCase {
    func testManualPolicyIgnoresTimeAndStartsNextSetOnlyAfterExplicitBoundary() {
        var session = WorkoutSessionReducer(prescription: weightedPrescription())
        session.apply(.rep(.init(id: "one", start: 0, end: 2)))
        session.apply(.clock(100))
        session.apply(.rep(.init(id: "two", start: 100, end: 102)))
        XCTAssertEqual(session.current?.reps.map(\.id), ["one", "two"])
        XCTAssertTrue(session.sets.isEmpty)

        session.apply(.closeSet(103))
        session.apply(.rep(.init(id: "three", start: 104, end: 106)))
        XCTAssertEqual(session.sets.first?.reps.map(\.id), ["one", "two"])
        XCTAssertEqual(session.current?.reps.map(\.id), ["three"])
    }

    func testSlowdownAloneDoesNotClaimRIRTargetReached() {
        let setID = UUID()
        let speeds = [1.0, 1.0, 1.0, 0.8, 0.8]
        let reps = speeds.enumerated().map { index, speed -> RepMotionMetrics in
            var metric = RepMotionMetrics(id: "rep-\(index)", setID: setID, updatedAt: Double(index))
            metric.status = .available
            metric.reason = nil
            metric.meanLiftingSpeed = speed
            return metric
        }
        let metrics = RepMetricsSnapshot(configuration: .init(), configurationHash: "test", reps: reps)
        let snapshot = V2ProcessorSnapshot(
            ingestSequence: 1, setState: .active, quality: .usable, detectorPhase: .ready,
            committedCount: 5, reference: nil, filteredSignal: nil, landmarks: .init(),
            recentEvents: [], metrics: metrics)
        let coaching = WorkoutCoach.evaluate(snapshot: snapshot, reps: 8, prescription: weightedPrescription())
        XCTAssertEqual(coaching.state, .steady)
        XCTAssertGreaterThan(coaching.slowdownPercent ?? 0, 10)

        var result = WorkoutSetResult(id: setID, prescription: weightedPrescription(), reps: 8,
                                      averageRepDuration: nil, movementDuration: nil,
                                      interrupted: false, finishedAt: Date(),
                                      slowdownPercent: coaching.slowdownPercent, coaching: coaching)
        result.nextSetPlan = WorkoutCoach.nextSetPlan(for: result)
        XCTAssertEqual(result.nextSetPlan?.action, .keepLoad)
    }

    func testInterruptedSetRecommendsRetryingCurrentLoad() {
        let snapshot = V2ProcessorSnapshot(
            ingestSequence: 1, setState: .active, quality: .stale, detectorPhase: .recovering,
            committedCount: 4, reference: nil, filteredSignal: nil, landmarks: .init(),
            recentEvents: [], qualityDetail: "Motion stream is stale", isRecovering: true)
        let coaching = WorkoutCoach.evaluate(snapshot: snapshot, reps: 4, prescription: weightedPrescription())
        XCTAssertEqual(coaching.state, .unavailable)
        let result = WorkoutSetResult(id: UUID(), prescription: weightedPrescription(), reps: 4,
                                      averageRepDuration: nil, movementDuration: nil,
                                      interrupted: true, finishedAt: Date(), coaching: coaching)
        XCTAssertEqual(WorkoutCoach.nextSetPlan(for: result).action, .keepLoad)
    }

    func testSteadyFullRangeSuggestsHeavierLoad() {
        let coaching = WorkoutCoachingSnapshot(
            state: .targetReached, slowdownPercent: 4,
            explanation: "You reached the top of your target range.", evidenceIsValid: true)
        let result = WorkoutSetResult(
            id: UUID(), prescription: weightedPrescription(), reps: 12,
            averageRepDuration: nil, movementDuration: nil,
            interrupted: false, finishedAt: Date(), slowdownPercent: 4, coaching: coaching)

        XCTAssertEqual(WorkoutCoach.nextSetPlan(for: result).action, .considerHeavierLoad)
    }

    func testGenericVelocityProfileDrivesTheSameCoachingStates() throws {
        let profile = SetVelocityProfile(meanLiftingSpeeds: [1.0, 0.98, 0.96, 0.8])
        let coaching = WorkoutCoach.evaluate(
            velocityProfile: profile, reps: 4, prescription: weightedPrescription())

        XCTAssertEqual(coaching.state, .steady)
        XCTAssertGreaterThan(try XCTUnwrap(coaching.slowdownPercent), 0)
        XCTAssertTrue(coaching.evidenceIsValid)
    }
}

@MainActor
final class WorkoutCaptureRoutingTests: XCTestCase {
    func testCompletedWorkoutFreezesInputsAndSavesSummary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = MockMotionProvider()
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        var sentStreams: [AISetRequest] = []
        let model = WorkoutModel(sessionDirectory: directory,
            historyFileURL: directory.appendingPathComponent("history.json"), analyzeAI: { input, _, _ in
                sentStreams.append(input)
                return AISetAdvice(estimatedRIR: 3, confidence: "low", notes: "Test stream analysis.",
                    weakPoints: [], nextSet: .init(loadLB: 30, reps: 10, targetRIR: 2),
                    rest: .init(seconds: 150, reason: "Recover before the heavier set."))
            })
        capture.startMotion()
        provider.emit(.sample(experimentalRawSample(index: 0, time: 0,
            receiptTime: ProcessInfo.processInfo.systemUptime)))
        for _ in 0..<1000 { if capture.latestSample != nil { break }; await Task.yield() }
        model.prescription.loadLB = 25
        await model.start(capture)
        XCTAssertEqual(model.state, .active)
        XCTAssertTrue(model.learningMovement)
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
        XCTAssertFalse(model.learningMovement)
        XCTAssertNotNil(model.currentPace)
        XCTAssertGreaterThan(model.activeTime, 0)
        XCTAssertLessThan(model.activeTime, model.elapsedTime)
        await model.endSet()
        XCTAssertEqual(model.state, .finalizing)
        for index in 511...545 { await model.ingest(raw(index)) }
        XCTAssertEqual(model.state, .complete)
        let setResult = try XCTUnwrap(model.latestSetResult)
        XCTAssertEqual(setResult.prescription.loadLB, 25)
        XCTAssertFalse(setResult.interrupted)
        XCTAssertGreaterThan(try XCTUnwrap(setResult.peakSpeedMPS), 0)
        XCTAssertGreaterThan(try XCTUnwrap(setResult.averageSpeedMPS), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(setResult.averageSpeedMPS),
                                 try XCTUnwrap(setResult.peakSpeedMPS))
        let roundTrip = try JSONDecoder().decode(WorkoutSetResult.self,
            from: JSONEncoder().encode(setResult))
        XCTAssertEqual(roundTrip.peakSpeedMPS, setResult.peakSpeedMPS)
        XCTAssertEqual(roundTrip.averageSpeedMPS, setResult.averageSpeedMPS)
        XCTAssertEqual(roundTrip.slowdownPercent, setResult.slowdownPercent)
        XCTAssertEqual(model.completedSetResults.count, 1)
        await model.analyzeLatestSet(model: "", apiKey: "")
        let sent = try XCTUnwrap(sentStreams.first)
        XCTAssertEqual(sent.reps.count, setResult.reps)
        XCTAssertTrue(sent.reps.contains { $0.meanSpeedMPS != nil })
        XCTAssertEqual(sent.reps.first?.durationSeconds, ((model.completedSets.last!.reps.first!.duration) * 100).rounded() / 100)
        XCTAssertEqual(sent.speedMeasurement, "whole-rep 3D device speed")
        let compactData = try JSONEncoder().encode(sent)
        XCTAssertLessThan(compactData.count, 5000)
        XCTAssertFalse(String(decoding: compactData, as: UTF8.self).contains("userAcceleration"))
        XCTAssertNil(sent.confirmedRIR)
        XCTAssertEqual(model.latestSetResult?.aiAdvice?.estimatedRIR, 3)
        let savedAI = try JSONDecoder().decode(WorkoutSetResult.self,
            from: Data(contentsOf: XCTUnwrap(model.summaryURL)))
        XCTAssertEqual(savedAI.aiAdvice?.estimatedRIR, 3)
        XCTAssertEqual(savedAI.aiAdvice?.rest?.seconds, 150)
        XCTAssertEqual(model.latestSetResult?.aiAdvice?.rest?.reason, "Recover before the heavier set.")
        let source = LoggedWorkoutSet(id: UUID(), sessionID: UUID(), sourceSetID: "recommendation",
            exercise: .bicepsCurl, loadLB: 40, reps: 8, repsInReserve: 2,
            averageRepDuration: nil, performedAt: Date(), velocityProfile: nil,
            rirValueSource: nil, precedingSetID: nil, precedingRestSeconds: nil)
        // A same-weight suggestion must still update reps and RIR.
        let prediction = LoadPrediction(loadLB: 40, targetReps: 9, targetRIR: 3,
            estimatedCapacityLB: 50, source: source, sourceCount: 1, confidence: .low,
            action: .keep, explanation: "Keep weight and adjust target")
        XCTAssertFalse(model.isNextSetSelected(loadLB: 40, reps: 9, rir: 3))
        model.use(prediction)
        XCTAssertTrue(model.isNextSetSelected(loadLB: 40, reps: 9, rir: 3))
        XCTAssertEqual(model.session?.prescription.maximumReps, 9)
        XCTAssertEqual(model.session?.prescription.targetRIR, 3)
        XCTAssertEqual(model.latestSetResult?.prescription.loadLB, 25)
        model.useAIAdvice()
        XCTAssertEqual(model.prescription.loadLB, 30)
        XCTAssertEqual(model.prescription.minimumReps, 10)
        XCTAssertEqual(model.prescription.maximumReps, 10)
        XCTAssertEqual(model.prescription.targetRIR, 2)
        let completedSummaryURL = model.summaryURL
        let liveSample = raw(546)
        provider.emit(.sample(RawMotionSample(
            index: liveSample.index, sourceTimestamp: liveSample.sourceTimestamp,
            receiptUptime: ProcessInfo.processInfo.systemUptime,
            sensorLocation: liveSample.sensorLocation,
            userAccelerationX: liveSample.userAccelerationX,
            userAccelerationY: liveSample.userAccelerationY,
            userAccelerationZ: liveSample.userAccelerationZ,
            gravityX: liveSample.gravityX, gravityY: liveSample.gravityY, gravityZ: liveSample.gravityZ,
            rotationRateX: liveSample.rotationRateX, rotationRateY: liveSample.rotationRateY,
            rotationRateZ: liveSample.rotationRateZ,
            quaternionW: liveSample.quaternionW, quaternionX: liveSample.quaternionX,
            quaternionY: liveSample.quaternionY, quaternionZ: liveSample.quaternionZ,
            roll: liveSample.roll, pitch: liveSample.pitch, yaw: liveSample.yaw)))
        for _ in 0..<1000 {
            if capture.latestSample?.index == liveSample.index { break }
            await Task.yield()
        }
        model.countingMode = .exercise
        let recommendedRest = try XCTUnwrap(model.latestSetResult?.aiAdvice?.rest?.seconds)
        let restStarted = try XCTUnwrap(model.restStart)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - restStarted, Double(recommendedRest))
        XCTAssertTrue(model.canStart(capture), "Recommended rest is advisory; an early next set must remain available.")
        await model.startSet(capture)
        XCTAssertEqual(model.state, .preparing)
        XCTAssertEqual(model.activePrescription.loadLB, 30)
        XCTAssertEqual(model.activePrescription.minimumReps, 10)
        XCTAssertEqual(model.activePrescription.maximumReps, 10)
        XCTAssertEqual(model.activePrescription.targetRIR, 2)
        await model.cancelPreparation()
        XCTAssertTrue(model.betweenSets)
        XCTAssertEqual(model.latestSetResult?.id, setResult.id)
        XCTAssertEqual(model.summaryURL, completedSummaryURL)
        model.finishWorkout()
        let result = try XCTUnwrap(model.result)
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
        XCTAssertEqual(V2Exercise.allCases.map(\.rawValue), [
            "RDL", "Goblet Squat", "Chest Press", "Overhead Press", "Lateral Raise",
            "Biceps Curl", "External Rotation", "Skull Crusher", "Lunge", "Bent Over Rows"
        ])
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
        await model.start(capture)
        XCTAssertEqual(model.state, .active)
        await model.checkStaleness(now: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(model.state, .interrupted)
        XCTAssertTrue(model.latestSetResult?.interrupted == true)
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

    func testStartRequiresLiveRightSideWithoutMountConfirmation() async {
        let provider = MockMotionProvider()
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        let model = WorkoutModel()
        capture.startMotion()
        provider.emit(.sample(makeSample(receiptUptime: ProcessInfo.processInfo.systemUptime)))
        for _ in 0..<100 { if capture.latestSample != nil { break }; await Task.yield() }
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
        let first = SessionSet(id: "set-1", prescription: weightedPrescription(), reps: (0..<10).map {
            .init(id: "a-\($0)", start: Double($0 * 3), end: Double($0 * 3 + 2))
        })
        let second = SessionSet(id: "set-2", prescription: weightedPrescription(), reps: (0..<8).map {
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
                                         set: SessionSet(id: "set-3", prescription: weightedPrescription(),
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
        XCTAssertEqual(estimate?.velocityLossPercent ?? 0, 50, accuracy: 2)
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
            let set = SessionSet(id: "set-\(setIndex)", prescription: weightedPrescription(), reps: reps)
            let draft = SetReviewDraft(sessionID: UUID(), set: set, velocityProfile: profile)
            XCTAssertTrue(store.confirm(draft, loadLB: 30, reps: 6, repsInReserve: 0))
        }
        let current = SetVelocityProfile(meanLiftingSpeeds: [0.9, 0.81, 0.72, 0.63])
        let estimate = try XCTUnwrap(store.automaticRIR(for: .bicepsCurl, completedReps: 4,
                                                        velocityProfile: current, loadLB: 30))
        XCTAssertEqual(estimate.repsInReserve, 2)
        XCTAssertEqual(estimate.method, .individualized)
        XCTAssertEqual(estimate.confidence, .low)
        XCTAssertEqual(estimate.calibrationSetCount, 2)
    }

    func testConfirmedSetsPersistByDayAndDuplicateSourceIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workouts.json")
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: weightedPrescription(),
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
        let set = SessionSet(id: "set-1", prescription: weightedPrescription(),
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

    func testPredictionWithoutRIRUsesRepBasedKeepRecommendation() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        let set = SessionSet(id: "set-1", prescription: weightedPrescription(),
                             reps: [.init(id: "rep-1", start: 0, end: 2)])
        XCTAssertTrue(store.confirm(SetReviewDraft(sessionID: UUID(), set: set),
                                    loadLB: 30, reps: 12, repsInReserve: nil))
        XCTAssertEqual(store.nextSetRecommendation(for: .bicepsCurl,
                                                 repRange: 8...12, targetRIR: 2)?.action, .keep)
    }

    func testPredictionCombinesConsistentConfirmedSets() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutHistoryStore(fileURL: file)
        for index in 0..<3 {
            let set = SessionSet(id: "set-\(index)", prescription: weightedPrescription(),
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
        let set = SessionSet(id: "set-1", prescription: weightedPrescription(),
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
        let set = SessionSet(id: "set-1", prescription: weightedPrescription(),
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
        let set = SessionSet(id: "set-1", prescription: weightedPrescription(),
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
        var session = automaticSession()
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
        var session = automaticSession()
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
        var session = automaticSession()
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
        var session = automaticSession()
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
        let original = weightedPrescription()
        var session = automaticSession()
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

    private func automaticSession() -> WorkoutSessionReducer {
        WorkoutSessionReducer(
            prescription: weightedPrescription(),
            policy: .init(version: "automatic-sets-v1", inactivitySeconds: 12)
        )
    }
}


@MainActor
final class RIRReliabilityTests: XCTestCase {
    private func store() -> WorkoutHistoryStore {
        WorkoutHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json"))
    }

    private func seed(_ store: WorkoutHistoryStore, sessionID: UUID = UUID(),
                      rir: Int = 0, load: Double = 25,
                      speeds: [Double?] = [1, 0.9, 0.8, 0.7, 0.6, 0.5],
                      exercise: V2Exercise = .bicepsCurl) {
        var prescription = WorkoutPrescription(); prescription.exercise = exercise
        let set = SessionSet(id: UUID().uuidString, prescription: prescription,
            reps: speeds.indices.map { SessionRep(id: "\($0)", start: Double($0 * 3), end: Double($0 * 3 + 2)) })
        let draft = SetReviewDraft(sessionID: sessionID, set: set,
            velocityProfile: .init(meanLiftingSpeeds: speeds))
        XCTAssertTrue(store.confirm(draft, loadLB: load, reps: speeds.count, repsInReserve: rir))
    }

    func testRobustTrendIgnoresSingleFinalSpikeButTracksSustainedDecline() throws {
        let clean = SetVelocityProfile(meanLiftingSpeeds: [1, 0.9, 0.8, 0.7, 0.6])
        let spike = SetVelocityProfile(meanLiftingSpeeds: [1, 0.9, 0.8, 0.7, 0.1])
        XCTAssertEqual(try XCTUnwrap(clean.recentSpeed), 0.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(spike.recentSpeed), 0.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(clean.slowdownPerRep), 10, accuracy: 0.001)
        XCTAssertFalse(clean.isNoisy)
        XCTAssertTrue(spike.isNoisy)
        let startup = SetVelocityProfile(meanLiftingSpeeds: [3, 1, 1, 1, 1, 1])
        XCTAssertEqual(startup.baselineSpeed, 1)
        XCTAssertEqual(startup.velocityLossPercent, 0)
    }

    func testMissingFinalRepInvalidNumbersAndMismatchedRepCountsDoNotCreateRIR() {
        let store = store()
        for speeds: [Double?] in [[1, 1, nil], [1, .nan, 0.8], [1, .infinity, 0.8],
                                  [1, -1, 0.8], [1, nil, nil, nil, 0.8, 0.7]] {
            XCTAssertNil(store.automaticRIR(for: .bicepsCurl, completedReps: speeds.count,
                velocityProfile: .init(meanLiftingSpeeds: speeds)))
        }
        XCTAssertNil(store.automaticRIR(for: .bicepsCurl, completedReps: 20,
            velocityProfile: .init(meanLiftingSpeeds: [1, 0.9, 0.8])))
    }

    func testSeparateSessionsValidatePersonalTrajectoryAndSameSessionDoesNot() throws {
        let profile = SetVelocityProfile(meanLiftingSpeeds: [1, 0.9, 0.8, 0.7])
        let validated = store()
        for _ in 0..<3 { seed(validated) }
        let estimate = try XCTUnwrap(validated.automaticRIR(for: .bicepsCurl, completedReps: 4,
            velocityProfile: profile, loadLB: 25))
        XCTAssertEqual(estimate.method, .individualized)
        XCTAssertEqual(estimate.repsInReserve, 2)
        XCTAssertEqual(estimate.confidence, .medium)
        XCTAssertEqual(try XCTUnwrap(estimate.validationMAE), 0, accuracy: 0.001)
        let sameSession = store(), sessionID = UUID()
        for _ in 0..<3 { seed(sameSession, sessionID: sessionID) }
        let unvalidated = try XCTUnwrap(sameSession.automaticRIR(for: .bicepsCurl, completedReps: 4,
            velocityProfile: profile, loadLB: 25))
        XCTAssertEqual(unvalidated.confidence, .low)
        XCTAssertNil(unvalidated.validationMAE)
    }

    func testInconsistentPersonalLabelsFailHeldOutValidation() throws {
        let store = store()
        for rir in [0, 4, 4] { seed(store, rir: rir) }
        let estimate = try XCTUnwrap(store.automaticRIR(for: .bicepsCurl, completedReps: 6,
            velocityProfile: .init(meanLiftingSpeeds: [1, 0.9, 0.8, 0.7, 0.6, 0.5]), loadLB: 25))
        XCTAssertEqual(estimate.confidence, .low)
        XCTAssertEqual(estimate.method, .populationHeuristic)
        XCTAssertGreaterThan(try XCTUnwrap(estimate.validationMAE), 2)
    }

    func testDifferentExerciseLoadAndEstimatorDoNotTrainPersonalModel() throws {
        let store = store()
        for _ in 0..<3 { seed(store, load: 60, exercise: .lateralRaise) }
        let profile = SetVelocityProfile(meanLiftingSpeeds: [1, 0.9, 0.8, 0.7])
        let mismatch = try XCTUnwrap(store.automaticRIR(for: .bicepsCurl, completedReps: 4,
            velocityProfile: profile, loadLB: 25))
        XCTAssertEqual(mismatch.method, .populationHeuristic)
        for _ in 0..<3 { seed(store, load: 60) }
        XCTAssertEqual(store.automaticRIR(for: .bicepsCurl, completedReps: 4,
            velocityProfile: profile, loadLB: 25)?.method, .populationHeuristic)
        for _ in 0..<3 { seed(store) }
        XCTAssertEqual(store.automaticRIR(for: .bicepsCurl, completedReps: 4,
            velocityProfile: .init(meanLiftingSpeeds: [1, 0.9, 0.8, 0.7], estimatorVersion: "new"),
            loadLB: 25)?.method, .populationHeuristic)
    }

    func testCoachingUsesSelectedRIRAndRepCeilingWithoutSpeed() {
        let profile = SetVelocityProfile(meanLiftingSpeeds: [1, 0.9, 0.8, 0.7])
        let estimate = AutomaticRIREstimate(repsInReserve: 1, velocityLossPercent: 30,
            measuredRepCount: 4, method: .individualized, confidence: .medium,
            calibrationSetCount: 3, cappedAtFourPlus: false, lowerRIR: 0, upperRIR: 2)
        var prescription = WorkoutPrescription()
        XCTAssertEqual(WorkoutCoach.evaluate(velocityProfile: profile, reps: 4,
            prescription: prescription, rirEstimate: estimate).state, .targetReached)
        prescription.targetRIR = 0
        XCTAssertEqual(WorkoutCoach.evaluate(velocityProfile: profile, reps: 4,
            prescription: prescription, rirEstimate: estimate).state, .approachingTarget)
        let ceiling = WorkoutCoach.evaluate(velocityProfile: nil, reps: 20,
            prescription: prescription, signalUsable: false)
        XCTAssertEqual(ceiling.state, .targetReached)
        XCTAssertFalse(ceiling.evidenceIsValid)
        XCTAssertNil(WorkoutCoach.evaluate(velocityProfile: profile, reps: 4,
            prescription: prescription, rirEstimate: estimate, signalUsable: false).slowdownPercent)
    }

    func testSameFinalSpeedWithDifferentDegradationPatternsChangesRIR() throws {
        let store = store()
        let declining: [Double?] = [1, 0.92, 0.84, 0.75, 0.67, 0.58, 0.5]
        let plateau: [Double?] = [1, 1, 0.5, 0.5, 0.5, 0.5, 0.5]
        for _ in 0..<3 {
            seed(store, rir: 0, speeds: declining)
            seed(store, rir: 4, speeds: plateau)
        }
        let fading = try XCTUnwrap(store.automaticRIR(for: .bicepsCurl, completedReps: 7,
            velocityProfile: .init(meanLiftingSpeeds: declining), loadLB: 25))
        let steady = try XCTUnwrap(store.automaticRIR(for: .bicepsCurl, completedReps: 7,
            velocityProfile: .init(meanLiftingSpeeds: plateau), loadLB: 25))
        XCTAssertEqual(fading.velocityLossPercent, steady.velocityLossPercent, accuracy: 1)
        XCTAssertLessThan(fading.repsInReserve, steady.repsInReserve)
        XCTAssertEqual(fading.method, .individualized)
        XCTAssertEqual(steady.method, .individualized)
    }

    func testInterRepRestKeepsEstimateProvisionalAndLegacyProfilesDecode() throws {
        let store = store()
        for _ in 0..<3 { seed(store) }
        var profile = SetVelocityProfile(meanLiftingSpeeds: [1, 0.9, 0.8, 0.7])
        profile.precedingPauses = [0, 1, 5, 1]
        let estimate = try XCTUnwrap(store.automaticRIR(for: .bicepsCurl, completedReps: 4,
            velocityProfile: profile, loadLB: 25))
        XCTAssertEqual(estimate.confidence, .low)
        XCTAssertEqual(estimate.method, .populationHeuristic)
        XCTAssertTrue(estimate.explanation.contains("pauses"))
        let legacy = Data(#"{"meanLiftingSpeeds":[1,0.9,0.8],"estimatorVersion":"old","measurementKind":"cycle"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SetVelocityProfile.self, from: legacy).precedingPauses)
    }

    func testLatestMetricRevisionAndMixedEpochsAreRejected() {
        let reps = (0..<4).map { SessionRep(id: "\($0)", start: Double($0 * 3), end: Double($0 * 3 + 2)) }
        let set = SessionSet(id: "set", prescription: weightedPrescription(), reps: reps)
        var metrics = reps.map { rep in
            var metric = GenericCycleMetrics(id: rep.id, learningEpoch: 1)
            metric.status = .available; metric.meanSpeed = 1
            return metric
        }
        XCTAssertNotNil(SetVelocityProfile(set: set, genericMetrics: metrics))
        var invalid = metrics[3]; invalid.status = .unavailable
        XCTAssertNil(SetVelocityProfile(set: set, genericMetrics: metrics + [invalid]))
        var changed = GenericCycleMetrics(id: "3", learningEpoch: 2)
        changed.status = .available; changed.meanSpeed = 1
        metrics[3] = changed
        XCTAssertNil(SetVelocityProfile(set: set, genericMetrics: metrics))
    }
}

final class AIWorkoutCoachTests: XCTestCase {
    func testRestHasItsOwnRequiredSchemaSectionAndSurvivesDecoding() throws {
        let schema = try AIWorkoutCoach.responseSchema(for: input())
        XCTAssertTrue(try XCTUnwrap(schema["required"] as? [String]).contains("rest"))
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let rest = try XCTUnwrap(properties["rest"] as? [String: Any])
        let object = try XCTUnwrap((rest["anyOf"] as? [[String: Any]])?.first)
        XCTAssertEqual(object["required"] as? [String], ["seconds", "reason"])
        let advice = AISetAdvice(estimatedRIR: 2, confidence: "medium", notes: "You kept a steady pace.",
            weakPoints: [], nextSet: nil, rest: .init(seconds: 120, reason: "Recover for another steady set."))
        let decoded = try JSONDecoder().decode(AISetAdvice.self, from: JSONEncoder().encode(advice))
        XCTAssertEqual(try decoded.validatedForDisplay(for: input()).rest, advice.rest)
    }

    func testInvalidRestDoesNotDiscardCoachingAndOldAdviceStillLoads() throws {
        let advice = AISetAdvice(estimatedRIR: 2, confidence: "medium", notes: "Steady pace.",
            weakPoints: [], nextSet: nil, rest: .init(seconds: 0, reason: "No rest"))
        let displayed = try advice.validatedForDisplay(for: input())
        XCTAssertNil(displayed.rest)
        XCTAssertEqual(displayed.notes, advice.notes)
        XCTAssertEqual(displayed.estimatedRIR, 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(advice)) as? [String: Any])
        json.removeValue(forKey: "rest")
        XCTAssertNil(try JSONDecoder().decode(AISetAdvice.self,
            from: JSONSerialization.data(withJSONObject: json)).rest)
    }

    func testUnknownWeightAllowsNotesButDisallowsInventedLoad() throws {
        let measured = input()
        let request = AISetRequest(prescription: .init(), reps: measured.reps,
            speedDegradationPercent: measured.speedDegradationPercent,
            speedMeasurement: measured.speedMeasurement, signalUsable: true, interrupted: false)
        let schema = try AIWorkoutCoach.responseSchema(for: request)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["nextSet"] as? [String: Any])?["type"] as? String, "null")
        let advice = AISetAdvice(estimatedRIR: 2, confidence: "low", notes: "Steady pace.",
            weakPoints: [], nextSet: .init(loadLB: 25, reps: 10, targetRIR: 2))
        let displayed = try advice.validatedForDisplay(for: request)
        XCTAssertEqual(displayed.notes, "Steady pace.")
        XCTAssertNil(displayed.nextSet)
    }

    func testObservedOversizedRequestErrorReportsTokenCounts() throws {
        let body: [String: Any] = ["error": ["code": "rate_limit_exceeded", "type": "tokens",
            "message": "Request too large for gpt-5.6-luna on tokens per min (TPM): Limit 60000, Requested 137415. The input or output tokens must be reduced."]]
        let error = AIWorkoutCoach.serviceError(statusCode: 429, data: try JSONSerialization.data(withJSONObject: body))
        guard case .requestTooLarge(let required, let limit) = error else {
            return XCTFail("Expected the concrete failure observed in the single live request")
        }
        XCTAssertEqual(required, 137415)
        XCTAssertEqual(limit, 60000)
    }

    func testQuotaAndTransientRateLimitRemainDistinct() throws {
        let quota = try JSONSerialization.data(withJSONObject: ["error": ["code": "insufficient_quota", "message": "Quota unavailable"]])
        guard case .quotaExceeded = AIWorkoutCoach.serviceError(statusCode: 429, data: quota) else {
            return XCTFail("Expected billing-specific error")
        }
        let rate = try JSONSerialization.data(withJSONObject: ["error": ["code": "rate_limit_exceeded", "message": "Limit 60000, Requested 5000"]])
        guard case .service(429) = AIWorkoutCoach.serviceError(statusCode: 429, data: rate) else {
            return XCTFail("A request below the limit can be retried later")
        }
    }

    func testInvalidOptionalEvidenceDoesNotDiscardRIRAndNotes() throws {
        let advice = AISetAdvice(estimatedRIR: 2, confidence: "low", notes: "Provisional RIR estimate.",
            weakPoints: [
                .init(rep: 2, observation: "Invalid rep", cue: "Cue"),
                .init(rep: 1, observation: "Slower rep", cue: "Cue")],
            nextSet: .init(loadLB: 27, reps: 10, targetRIR: 2))
        let text = String(decoding: try JSONEncoder().encode(advice), as: UTF8.self)
        let envelope: [String: Any] = ["status": "completed", "output": [
            ["type": "message", "content": [["type": "output_text", "text": text]]]]]
        let result = try AIWorkoutCoach.decodeResponse(JSONSerialization.data(withJSONObject: envelope), for: input())
        XCTAssertEqual(result.estimatedRIR, 2)
        XCTAssertEqual(result.notes, advice.notes)
        XCTAssertEqual(result.weakPoints.count, 1)
        XCTAssertEqual(result.weakPoints.first?.rep, 1)
        XCTAssertNil(result.nextSet)
        XCTAssertEqual(result.validationWarnings?.count, 2)
        XCTAssertNoThrow(try result.validate(for: input()))
    }

    func testRequestSchemaConstrainsEquipmentAndRepNumbers() throws {
        let schema = try AIWorkoutCoach.responseSchema(for: input())
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let next = try XCTUnwrap(properties["nextSet"] as? [String: Any])
        let targets = try XCTUnwrap((next["anyOf"] as? [[String: Any]])?.first?["properties"] as? [String: Any])
        XCTAssertEqual((targets["loadLB"] as? [String: Any])?["enum"] as? [Double], [20, 25, 30])
        XCTAssertEqual((targets["reps"] as? [String: Any])?["maximum"] as? Int, 12)
        let points = try XCTUnwrap(properties["weakPoints"] as? [String: Any])
        let items = try XCTUnwrap(points["items"] as? [String: Any])
        let fields = try XCTUnwrap(items["properties"] as? [String: Any])
        XCTAssertEqual((fields["rep"] as? [String: Any])?["maximum"] as? Int, 1)
        XCTAssertNil(fields["startTime"])
        XCTAssertNil(fields["endTime"])
    }

    func testIncompleteOutputExplainsTokenLimit() throws {
        let envelope: [String: Any] = ["status": "incomplete", "output": [],
            "incomplete_details": ["reason": "max_output_tokens"]]
        XCTAssertThrowsError(try AIWorkoutCoach.decodeResponse(
            JSONSerialization.data(withJSONObject: envelope), for: input())) { error in
                XCTAssertTrue(error.localizedDescription.contains("output limit"))
        }
        let invalidCore = AISetAdvice(estimatedRIR: 99, confidence: "low", notes: "Invalid RIR", weakPoints: [], nextSet: nil)
        XCTAssertThrowsError(try invalidCore.validatedForDisplay(for: input()))
    }

    func testDirectRequestContainsOnlyCompactMetricsAndStrictSchema() throws {
        let input = input()
        let request = try AIWorkoutCoach.makeRequest(input, model: "gpt-4.1", apiKey: " test-key ")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-4.1")
        XCTAssertEqual(body["store"] as? Bool, false)
        let sentInput = try XCTUnwrap(body["input"] as? String)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sentInput.utf8)) as? [String: Any])
        XCTAssertNil(sent["stream"])
        XCTAssertNil(sent["genericMetrics"])
        XCTAssertNil(sent["genericPhases"])
        let reps = try XCTUnwrap(sent["reps"] as? [[String: Any]])
        XCTAssertEqual(reps.count, 1)
        XCTAssertEqual(reps[0]["meanSpeedMPS"] as? Double, 0.5)
        XCTAssertEqual(sent["speedDegradationPercent"] as? Double, 20)
        XCTAssertLessThan(try XCTUnwrap(request.httpBody).count, 8000)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertThrowsError(try AIWorkoutCoach.makeRequest(input, model: "gpt-4.1", apiKey: "  "))
    }

    func testDirectResponseHandlesReasoningAndUnavailableRIR() throws {
        let advice = AISetAdvice(estimatedRIR: nil, confidence: "low", notes: "Insufficient evidence.",
            weakPoints: [], nextSet: nil)
        let text = String(decoding: try JSONEncoder().encode(advice), as: UTF8.self)
        let body: [String: Any] = ["status": "completed", "output": [
            ["type": "reasoning"],
            ["type": "message", "content": [["type": "output_text", "text": text]]]
        ]]
        let result = try AIWorkoutCoach.decodeResponse(JSONSerialization.data(withJSONObject: body), for: input())
        XCTAssertEqual(result, advice)
    }

    func testDirectResponseRejectsRefusalIncompleteAndInvalidJSON() throws {
        let envelopes: [[String: Any]] = [
            ["status": "incomplete", "output": []],
            ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "No"]]]]],
            ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "invalid"]]]]]
        ]
        for envelope in envelopes {
            XCTAssertThrowsError(try AIWorkoutCoach.decodeResponse(
                JSONSerialization.data(withJSONObject: envelope), for: input()))
        }
    }

    private func input() -> AISetRequest {
        let rep = SessionRep(id: "r1", start: 10, end: 12)
        let metric = GenericCycleMetrics(id: "r1", learningEpoch: 0, status: .available, meanSpeed: 0.5, peakSpeed: 0.8)
        return AISetRequest(prescription: weightedPrescription(), reps: [.init(rep: rep, generic: metric)],
            speedDegradationPercent: 20, speedMeasurement: "whole-rep 3D device speed", signalUsable: true, interrupted: false)
    }

    func testSummaryRoundsMeasurementsAndSuppressesUnavailableSpeeds() throws {
        let rep = SessionRep(id: "r1", start: 10, end: 12.1234567)
        var metric = GenericCycleMetrics(id: "r1", learningEpoch: 0, status: .available, meanSpeed: 0.1234567, peakSpeed: 0.8765432)
        let summary = AIRepSummary(rep: rep, generic: metric)
        XCTAssertEqual(summary.durationSeconds, 2.12)
        XCTAssertEqual(summary.meanSpeedMPS, 0.123)
        XCTAssertEqual(summary.peakSpeedMPS, 0.877)
        metric.status = .unavailable
        let missing = AIRepSummary(rep: rep, generic: metric)
        XCTAssertNil(missing.meanSpeedMPS)
        XCTAssertNil(missing.peakSpeedMPS)
        XCTAssertEqual(missing.speedQuality, "unavailable")
        metric.status = .available; metric.meanSpeed = .nan
        XCTAssertNil(AIRepSummary(rep: rep, generic: metric).meanSpeedMPS)
    }

    func testRejectsInventedEvidenceAndOffIncrementLoad() throws {
        let valid = AISetAdvice(estimatedRIR: 2, confidence: "low", notes: "Provisional estimate.",
            weakPoints: [.init(rep: 1, startTime: 10.5, endTime: 11,
                              observation: "Pause", cue: "Maintain your pace")],
            nextSet: .init(loadLB: 30, reps: 10, targetRIR: 2))
        XCTAssertNoThrow(try valid.validate(for: input()))
        let outside = AISetAdvice(estimatedRIR: 2, confidence: "low", notes: "Pause.",
            weakPoints: [.init(rep: 2,
                              observation: "Pause", cue: "Maintain your pace")], nextSet: nil)
        XCTAssertThrowsError(try outside.validate(for: input()))
        let offStep = AISetAdvice(estimatedRIR: nil, confidence: "low", notes: "Uncertain.",
            weakPoints: [], nextSet: .init(loadLB: 27, reps: 10, targetRIR: 2))
        XCTAssertThrowsError(try offStep.validate(for: input()))
        let unavailable = AISetAdvice(estimatedRIR: nil, confidence: "low", notes: "Insufficient evidence.", weakPoints: [], nextSet: nil)
        XCTAssertNoThrow(try unavailable.validate(for: input()))
    }

    func testOldSummaryStillDecodesWithoutAIAdvice() throws {
        let result = WorkoutSetResult(id: UUID(), prescription: weightedPrescription(), reps: 10,
            averageRepDuration: 2, movementDuration: 20, interrupted: false, finishedAt: Date())
        let data = try JSONEncoder().encode(result)
        XCTAssertNil(try JSONDecoder().decode(WorkoutSetResult.self, from: data).aiAdvice)
    }
}

final class RepTargetProgressTests: XCTestCase {
    func testRepsFillTargetThenOverwriteFromLeft() {
        for reps in 0...24 {
            let progress = RepTargetProgress(reps: reps, target: 12)
            XCTAssertEqual(progress.segmentCount, 12)
            XCTAssertEqual(progress.completed, min(reps, 12))
            XCTAssertEqual(progress.overflow, max(0, reps - 12))
        }
    }

    func testOverflowStaysFullBeyondTwoTargetsAndInvalidInputsAreBounded() {
        XCTAssertEqual(RepTargetProgress(reps: 30, target: 12).overflow, 12)
        XCTAssertEqual(RepTargetProgress(reps: -1, target: 12).completed, 0)
        XCTAssertEqual(RepTargetProgress(reps: 0, target: 0).segmentCount, 1)
        XCTAssertEqual(RepTargetProgress(reps: 13, target: 15).overflow, 0)
        XCTAssertEqual(RepTargetProgress(reps: 13, target: 10).overflow, 3)
    }
}

private func weightedPrescription() -> WorkoutPrescription {
    var value = WorkoutPrescription()
    value.loadLB = 25
    return value
}

@MainActor
final class OptionalWorkoutWeightTests: XCTestCase {
    func testWeightIsOptionalAndSurvivesArchiveRoundTrip() throws {
        let value = WorkoutPrescription()
        XCTAssertNil(value.loadLB)
        XCTAssertTrue(value.isValid)
        let decoded = try JSONDecoder().decode(WorkoutPrescription.self, from: JSONEncoder().encode(value))
        XCTAssertNil(decoded.loadLB)
        XCTAssertTrue(decoded.isValid)
        var zero = value
        zero.loadLB = 0
        XCTAssertEqual(try JSONDecoder().decode(WorkoutPrescription.self,
            from: JSONEncoder().encode(zero)).loadLB, 0)
    }

    func testWeightCarriesWithinExerciseAndRestoresOnReturn() {
        let model = WorkoutModel()
        model.prescription.loadLB = 30
        model.updateNextSet()
        XCTAssertEqual(model.prescription.loadLB, 30)
        model.prescription.exercise = .lateralRaise
        XCTAssertNil(model.prescription.loadLB)
        model.prescription.loadLB = 15
        model.prescription.exercise = .bicepsCurl
        XCTAssertEqual(model.prescription.loadLB, 30)
        model.prescription.exercise = .lateralRaise
        XCTAssertEqual(model.prescription.loadLB, 15)
        model.prescription.loadLB = nil
        model.prescription.exercise = .bicepsCurl
        model.prescription.exercise = .lateralRaise
        XCTAssertNil(model.prescription.loadLB)
    }

    func testEditingCompletedWeightDoesNotChangeUpcomingWeight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let model = WorkoutModel(sessionDirectory: directory, historyFileURL: url)
        model.prescription.loadLB = 35
        let set = SessionSet(id: "completed", prescription: weightedPrescription(),
            reps: [.init(id: "rep", start: 0, end: 1)])
        let draft = SetReviewDraft(sessionID: UUID(), set: set)
        XCTAssertTrue(model.confirmSet(draft, loadLB: 25, reps: 1, repsInReserve: 2))
        let logged = try XCTUnwrap(model.history.sets.first)
        model.updateCompletedWeight(logged, loadLB: 30)
        XCTAssertEqual(model.prescription.loadLB, 35)
        XCTAssertEqual(model.history.sets.count, 1)
        XCTAssertEqual(model.history.sets.first?.loadLB, 30)
        XCTAssertEqual(WorkoutHistoryStore(fileURL: url).sets.first?.loadLB, 30)
        model.updateCompletedWeight(logged, loadLB: nil)
        XCTAssertNil(model.history.sets.first?.loadLB)
        XCTAssertEqual(model.prescription.loadLB, 35)
    }

    func testUnknownWeightCanBeSavedWithoutInventingVolumeOrLoadAdvice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = WorkoutHistoryStore(fileURL: url)
        let set = SessionSet(id: "unknown", prescription: .init(),
            reps: (0..<10).map { .init(id: "rep-\($0)", start: Double($0 * 2), end: Double($0 * 2 + 1)) })
        let draft = SetReviewDraft(sessionID: UUID(), set: set)
        XCTAssertTrue(store.confirm(draft, loadLB: nil, reps: 10, repsInReserve: 2))
        XCTAssertNil(store.sets.first?.loadLB)
        XCTAssertNil(store.sets.first?.volumeLB)
        XCTAssertNil(WorkoutHistoryStore(fileURL: url).sets.first?.loadLB)
        XCTAssertNil(store.nextSetRecommendation(for: .bicepsCurl, repRange: 8...12, targetRIR: 2))
        XCTAssertNotNil(store.restRecommendation(after: try XCTUnwrap(store.sets.first)))
        let result = WorkoutSetResult(id: UUID(), prescription: .init(), reps: 10,
            averageRepDuration: nil, movementDuration: nil, interrupted: false, finishedAt: Date())
        XCTAssertEqual(WorkoutCoach.nextSetPlan(for: result).action, .noRecommendation)
    }
}

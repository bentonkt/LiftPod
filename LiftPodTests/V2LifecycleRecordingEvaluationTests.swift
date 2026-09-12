import XCTest
@testable import LiftPod

final class V2ProfileHashTests: XCTestCase {
    func testDSPIdentityHashIsStableAndIgnoresDescriptionAndValidation() {
        let original = V2DSPProfile.bundledCurl
        var changedDescription = original
        changedDescription.descriptiveNotes = "Different diagnostic description"
        changedDescription.validationStatus = .validated
        XCTAssertEqual(original.contentHash, changedDescription.contentHash)
        XCTAssertEqual(original.contentHash.count, 64)
    }

    func testThresholdChangeChangesHashAndMalformedProfileFails() {
        let profile = V2DSPProfile.bundledCurl
        var local = profile.identity.localCycle; local.leaveStart += 0.01
        let identity = V2DSPIdentity(profileVersion: profile.identity.profileVersion,
                                     exercise: profile.identity.exercise,
                                     expectedSensorSide: profile.identity.expectedSensorSide,
                                     setupIdentifier: profile.identity.setupIdentifier,
                                     sampleRate: profile.identity.sampleRate,
                                     signalSource: profile.identity.signalSource,
                                     projectionAxis: profile.identity.projectionAxis,
                                     polarity: profile.identity.polarity, filter: profile.identity.filter,
                                     reference: profile.identity.reference, localCycle: local,
                                     templateConfiguration: profile.identity.templateConfiguration,
                                     timing: profile.identity.timing, positiveTemplates: [], negativeTemplates: [],
                                     kind: .localCycle)
        let changed = V2DSPProfile(profileID: profile.profileID, identity: identity,
                                   validationStatus: .experimental, descriptiveNotes: nil)
        XCTAssertNotEqual(profile.contentHash, changed.contentHash)
        let malformedIdentity = V2DSPIdentity(profileVersion: "unsupported", exercise: .bicepsCurl,
                                              expectedSensorSide: .right, setupIdentifier: "setup", sampleRate: 50,
                                              signalSource: .gravity, projectionAxis: .x, polarity: 1, filter: .v2Fixed4Hz,
                                              reference: .init(), localCycle: .init(), templateConfiguration: .init(),
                                              timing: .init(), positiveTemplates: [], negativeTemplates: [], kind: .localCycle)
        XCTAssertThrowsError(try V2DSPProfile(profileID: "bad", identity: malformedIdentity,
                                              validationStatus: .experimental, descriptiveNotes: nil).validated())
    }

    func testProfileStoreIsContentAddressedAndImportedClaimsAreNotTrusted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = V2ProfileStore(directory: directory)
        let original = V2DSPProfile.bundledCurl
        await store.freeze(original)
        let firstURL = try await store.save(original)
        var notesOnly = original; notesOnly.descriptiveNotes = "Different note"
        let notesURL = try await store.save(notesOnly)
        XCTAssertEqual(notesURL, firstURL)
        let exported = try await store.exportData(original)
        let imported = try await store.importProfile(exported)
        XCTAssertEqual(imported.validationStatus, .importedUnvalidated)
        XCTAssertEqual(imported.contentHash, original.contentHash)
        await store.release(original)
    }
}

final class V2SetLifecycleTests: XCTestCase {
    func testStartPreparingActivationAndEndDrain() async throws {
        let engine = V2SetEngine(); let recorder = V2TestRecorder()
        try await engine.start(profile: .bundledCurl, recorder: recorder, motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true)
        var state = await engine.state
        XCTAssertEqual(state, .preparing)
        for index in 0...150 { await engine.ingest(v2Raw(index)) }
        state = await engine.state
        XCTAssertEqual(state, .active)
        try await engine.requestEnd(at: 3.0)
        state = await engine.state
        XCTAssertEqual(state, .finalizing)
        for index in 151...171 { await engine.ingest(v2Raw(index)) }
        state = await engine.state
        let rawCount = await recorder.rawCount
        XCTAssertEqual(state, .complete)
        XCTAssertEqual(rawCount, 172)
    }

    func testWrongSideAndRecordingFailureInterrupt() async throws {
        var engine = V2SetEngine(); var recorder = V2TestRecorder()
        try await engine.start(profile: .bundledCurl, recorder: recorder, motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true)
        await engine.ingest(v2Raw(0, side: .leftHeadphone))
        let interruptedState = await engine.state
        let sideInterruption = await engine.interruption
        XCTAssertEqual(interruptedState, .interrupted)
        XCTAssertEqual(sideInterruption, .wrongSensorSide)

        engine = V2SetEngine(); recorder = V2TestRecorder()
        try await engine.start(profile: .bundledCurl, recorder: recorder, motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true)
        await recorder.injectAppendFailure(); await engine.ingest(v2Raw(0))
        let recordingInterruption = await engine.interruption
        XCTAssertEqual(recordingInterruption, .recordingFailure)
    }

    func testStartRequirementsAndEndOnlyWhileActive() async {
        let engine = V2SetEngine(); let recorder = V2TestRecorder()
        await XCTAssertThrowsErrorAsync {
            try await engine.start(profile: .bundledCurl, recorder: recorder, motionActive: false,
                                   sideVerified: true, noOtherRecording: true, setupConfirmed: true)
        }
        await XCTAssertThrowsErrorAsync { try await engine.requestEnd(at: 0) }
    }
}

final class V2RecordingReplayTests: XCTestCase {
    func testBoundedQueueOverflowAndTerminationAreExplicit() async throws {
        let queue = V2BoundedRecordingQueue<Int>(capacity: 2)
        try await queue.enqueue(1); try await queue.enqueue(2)
        await XCTAssertThrowsErrorAsync { try await queue.enqueue(3) }
        _ = await queue.dequeue(); await queue.terminate()
        await XCTAssertThrowsErrorAsync { try await queue.enqueue(4) }
    }

    func testSelfContainedBundleFinalizationIsIdempotentAndReplayChecksOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = V2SessionRecorder(directory: directory)
        let profile = V2DSPProfile.bundledCurl, descriptor = v2Descriptor(profile: profile)
        try await recorder.start(descriptor: descriptor, profile: profile)
        let raw = v2Raw(0); try await recorder.appendRaw(raw)
        let uniform = try V2UniformSourceResampler().resample([raw], profile: profile).samples
        let snapshot = V2ProcessorSnapshot(ingestSequence: 0, setState: .preparing, quality: .warmingUp,
                                           detectorPhase: .waitingForBottom, committedCount: 0,
                                           reference: nil, filteredSignal: nil, landmarks: .init(), recentEvents: [])
        try await recorder.appendTransaction(.init(schemaVersion: 2, processorVersion: "rep-analysis-v2",
                                                   ingestSequence: 0, boundary: .start, input: RawMotionEvent(raw),
                                                   output: snapshot, uniformSamples: uniform,
                                                   profileID: profile.profileID, profileHash: profile.contentHash))
        let first = try await recorder.finalize(state: .complete, failure: nil, snapshot: snapshot, reference: nil)
        let second = try await recorder.finalize(state: .complete, failure: nil, snapshot: snapshot, reference: nil)
        XCTAssertEqual(first, second)
        let urls = try XCTUnwrap(first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: urls.directory.path).count, 6)
        let manifest = try JSONDecoder().decode(V2AnalysisManifest.self, from: Data(contentsOf: urls.manifest))
        let transactions = try Data(contentsOf: urls.transactions).split(separator: 0x0A).map {
            try JSONDecoder().decode(V2ProcessorTransaction.self, from: Data($0))
        }
        let archive = V2ReplayArchive(manifest: manifest, profile: profile, transactions: transactions)
        XCTAssertTrue(V2ReplayVerifier().verify(archive).passed)
        var altered = transactions
        let old = altered[0]
        let changedSnapshot = V2ProcessorSnapshot(ingestSequence: 0, setState: .preparing, quality: .warmingUp,
                                                  detectorPhase: .waitingForBottom, committedCount: 1,
                                                  reference: nil, filteredSignal: nil, landmarks: .init(), recentEvents: [])
        altered[0] = .init(schemaVersion: 2, processorVersion: old.processorVersion,
                           ingestSequence: 0, boundary: .start, input: old.input, output: changedSnapshot,
                           uniformSamples: old.uniformSamples, profileID: old.profileID,
                           profileHash: old.profileHash, outputHash: old.outputHash)
        XCTAssertEqual(V2ReplayVerifier().verify(.init(manifest: manifest, profile: profile,
                                                      transactions: altered)).field, "output")
    }
}

final class V2OfflineEvaluationTests: XCTestCase {
    func testCandidateGridMedoidAndNoEligibleSelectionAreDeterministic() {
        let evaluator = V2OfflineEvaluator()
        XCTAssertEqual(evaluator.candidateGrid().count, 60)
        XCTAssertEqual(evaluator.candidateGrid(), evaluator.candidateGrid())
        XCTAssertEqual(evaluator.medoidIndex([[[0]], [[1]], [[10]]]), 1)
        XCTAssertNil(evaluator.select(validationScores: []) { _, _ in true })
    }

    func testSplitLeakageAndTrainingSourceFail() async {
        let fit = trial(id: "fit", setup: "shared", split: .fit, cadence: "normal")
        let validation = trial(id: "validation", setup: "shared", split: .validation, cadence: nil)
        XCTAssertThrowsError(try V2OfflineEvaluator().validateTrials([fit, validation]))
        let validTrials = [trial(id: "normal", setup: "a", split: .fit, cadence: "normal"),
                           trial(id: "slow", setup: "b", split: .fit, cadence: "slow"),
                           trial(id: "fast", setup: "c", split: .fit, cadence: "fast")]
        XCTAssertThrowsError(try V2OfflineEvaluator().validateTrials(validTrials,
                                                                      trainingTrialIDs: ["missing-validation"]))
    }

    func testMetricsOneToOneSubtypeAndWilsonRemainFinite() {
        let trial = V2EvaluationTrial(trialID: "metrics", participantPseudonym: "operator-a",
                                      setupSessionID: "setup-a", split: .evaluation, exercise: .bicepsCurl,
                                      inputs: [], annotations: [
                                        .init(completionTimestamp: 1, completeness: .complete, negativeSubtype: nil),
                                        .init(completionTimestamp: 2, completeness: .incomplete, negativeSubtype: "partial")
                                      ], negativeExampleDuration: 60, transitionScript: true, cadenceGroup: nil)
        var first = cycleEvidence(id: "a", completion: 1.1); first.committed = true
        var second = cycleEvidence(id: "b", completion: 2.1); second.committed = true
        let metrics = V2OfflineEvaluator().metrics(trials: [trial], candidates: [trial.trialID: [first, second]])
        XCTAssertEqual(metrics.truePositives, 1); XCTAssertEqual(metrics.falsePositives, 1)
        XCTAssertEqual(metrics.partialOrAbandonedTriggers, 1)
        XCTAssertEqual(metrics.negativeSubtypeBreakdown["partial"], 1)
        XCTAssertTrue(metrics.precisionInterval.lower.isFinite && metrics.recallInterval.upper.isFinite)
    }

    private func trial(id: String, setup: String, split: V2TrialSplit, cadence: String?) -> V2EvaluationTrial {
        .init(trialID: id, participantPseudonym: "operator", setupSessionID: setup, split: split,
              exercise: .bicepsCurl, inputs: [],
              annotations: [.init(completionTimestamp: 1, completeness: .incomplete, negativeSubtype: "negative")],
              negativeExampleDuration: 1, transitionScript: false, cadenceGroup: cadence)
    }

    private func cycleEvidence(id: String, completion: Double) -> V2CycleEvidence {
        let descriptor = v2Descriptor()
        return .init(id: id, setID: descriptor.setID, exercise: .bicepsCurl, authorizationSource: .manual,
                     profileID: descriptor.profileID, dspContentHash: descriptor.dspContentHash,
                     detectorEpoch: 0, cycleSequence: 0, startTimestamp: completion - 1,
                     topTimestamp: completion - 0.5, completionTimestamp: completion,
                     detectionTimestamp: completion + 0.1, bottom: 0, top: 1, returned: 0,
                     outboundArea: 0.2, returnArea: 0.2, committed: true, rejectionReason: nil)
    }
}

func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected an error", file: file, line: line) }
    catch { }
}

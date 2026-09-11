import XCTest
@testable import LiftPod

final class ExperimentalOrchestrationTests: XCTestCase {
    private func rawFixture(side: HeadphoneSensorLocation = .rightHeadphone, gapAfter: Int? = nil) -> [RawMotionSample] {
        var offset = 0.0
        return biphasicFixture().enumerated().map { index, signal in
            if gapAfter == index { offset += 0.20 }
            return experimentalRawSample(index: UInt64(index + 1), time: Double(index) * 0.02 + offset,
                                         side: side, acceleration: .init(x: signal, y: 0, z: 0))
        }
    }

    private func input(exercise: ExperimentalExercise = .lateralRaise,
                       side: HeadphoneSensorLocation = .rightHeadphone,
                       gapAfter: Int? = nil) -> ExperimentalProcessorInput {
        let selection = StableExerciseSelection(epoch: 0, selectedProfile: exercise,
                                                supportStartTimestamp: 0, effectiveFromTimestamp: 0,
                                                decisionTimestamp: 0, confidence: nil, reason: .manualSelection)
        return ExperimentalProcessorInput(samples: rawFixture(side: side, gapAfter: gapAfter),
                                          sourceFilename: "synthetic.csv", selection: selection,
                                          expectedSensorSide: .right, configuration: .init())
    }

    func testManualSelectionCommitsOnlyMatchingCandidates() throws {
        let selected = try ExperimentalV1Processor().analyze(input()).summary
        XCTAssertEqual(selected.committedCount, 1)
        XCTAssertTrue(selected.candidates.filter { $0.disposition == .committed }.allSatisfy { $0.exercise == .lateralRaise })

        let conflicting = try ExperimentalV1Processor().analyze(input(exercise: .overheadPress)).summary
        XCTAssertEqual(conflicting.committedCount, 0)
    }

    func testDelayedAuthorizationCommitsOnceAndConflictDoesNotCommit() {
        let candidate = evidence(id: "candidate", exercise: .lateralRaise, completion: 2)
        let delayed = StableExerciseSelection(epoch: 1, selectedProfile: .lateralRaise,
                                              supportStartTimestamp: 1, effectiveFromTimestamp: 1,
                                              decisionTimestamp: 3, confidence: nil, reason: .manualSelection)
        var authorizer = CandidateAuthorizer()
        let first = authorizer.authorize([candidate], decision: delayed, retentionDuration: 8)
        XCTAssertEqual(first[0].disposition, .committed)
        XCTAssertTrue(first[0].qualityFlags.contains(.delayedAuthorization))
        XCTAssertNotEqual(authorizer.authorize([candidate], decision: delayed, retentionDuration: 8)[0].disposition, .committed)

        let expired = StableExerciseSelection(epoch: 2, selectedProfile: .lateralRaise,
                                              supportStartTimestamp: 0, effectiveFromTimestamp: 0,
                                              decisionTimestamp: 11, confidence: nil, reason: .manualSelection)
        var expiredAuthorizer = CandidateAuthorizer()
        XCTAssertNotEqual(expiredAuthorizer.authorize([candidate], decision: expired, retentionDuration: 8)[0].disposition, .committed)

        let conflict = StableExerciseSelection(epoch: 1, selectedProfile: .overheadPress,
                                               supportStartTimestamp: 1, effectiveFromTimestamp: 1,
                                               decisionTimestamp: 3, confidence: nil, reason: .manualSelection)
        var other = CandidateAuthorizer()
        XCTAssertNotEqual(other.authorize([candidate], decision: conflict, retentionDuration: 8)[0].disposition, .committed)
    }

    func testWrongSideAndGapPreventCountingAcrossBreak() throws {
        let wrong = try ExperimentalV1Processor().analyze(input(side: .leftHeadphone)).summary
        XCTAssertEqual(wrong.committedCount, 0)
        XCTAssertEqual(wrong.finalQuality, .wrongSensorSide)
        let split = try ExperimentalV1Processor().analyze(input(gapAfter: 48)).summary
        XCTAssertEqual(split.committedCount, 0)
    }

    func testQualityRecoveryDisconnectAndReset() {
        var tracker = SignalQualityTracker(expectedSide: .right)
        for index in 0...13 { tracker.observe(experimentalRawSample(index: UInt64(index), time: Double(index) * 0.02)) }
        XCTAssertEqual(tracker.state, .usable)
        tracker.disconnect(at: 0.3)
        XCTAssertEqual(tracker.state, .disconnected)
        for index in 0...13 { tracker.observe(experimentalRawSample(index: UInt64(index + 20), time: 1 + Double(index) * 0.02)) }
        XCTAssertEqual(tracker.state, .usable)
        tracker.reset()
        XCTAssertEqual(tracker.state, .warmingUp)
        XCTAssertEqual(tracker.epoch, 0)
    }

    func testDegradedStreamRequiresRecoveryDuration() {
        var tracker = SignalQualityTracker(expectedSide: .right)
        tracker.observe(experimentalRawSample(index: 1, time: 0))
        tracker.observe(experimentalRawSample(index: 2, time: 0.2))
        XCTAssertEqual(tracker.state, .degraded)
        for index in 1...12 {
            tracker.observe(experimentalRawSample(index: UInt64(index + 2), time: 0.2 + Double(index) * 0.02))
        }
        XCTAssertEqual(tracker.state, .degraded)
        tracker.observe(experimentalRawSample(index: 16, time: 0.46))
        XCTAssertEqual(tracker.state, .usable)
    }
}

final class ExperimentalReplayEvaluationTests: XCTestCase {
    private func analysisInput() -> ExperimentalProcessorInput {
        let samples = biphasicFixture().enumerated().map {
            experimentalRawSample(index: UInt64($0.offset + 1), time: Double($0.offset) * 0.02,
                                  acceleration: .init(x: $0.element, y: 0, z: 0))
        }
        let selection = StableExerciseSelection(epoch: 0, selectedProfile: .lateralRaise,
                                                supportStartTimestamp: 0, effectiveFromTimestamp: 0,
                                                decisionTimestamp: 0, confidence: nil, reason: .manualSelection)
        return ExperimentalProcessorInput(samples: samples, sourceFilename: "fixture.csv", selection: selection,
                                          expectedSensorSide: .right, configuration: .init())
    }

    func testReplayIsDeterministicAndAlteredValueIsDetected() throws {
        let output = try ExperimentalV1Processor().process(analysisInput())
        XCTAssertEqual(ExperimentalReplayVerifier().verify(output.trace).passed, true)
        XCTAssertEqual(ExperimentalReplayVerifier().verify(output.trace), ExperimentalReplayVerifier().verify(output.trace))
        var transactions = output.trace.transactions
        let old = transactions[transactions.count - 1]
        let changedSnapshot = DetectionSnapshot(committedCount: old.resultingOutput.committedCount + 1,
                                                provisionalCount: old.resultingOutput.provisionalCount,
                                                rejectedCount: old.resultingOutput.rejectedCount,
                                                quality: old.resultingOutput.quality,
                                                detectorPhase: old.resultingOutput.detectorPhase,
                                                candidateIDs: old.resultingOutput.candidateIDs)
        transactions[transactions.count - 1] = ReplayTransaction(
            ingestSequence: old.ingestSequence, inputEvent: old.inputEvent, resultingOutput: changedSnapshot,
            qualityState: old.qualityState, detectorPhase: old.detectorPhase,
            provisionalCandidateIDs: old.provisionalCandidateIDs, stableExerciseState: old.stableExerciseState,
            detectorVersion: old.detectorVersion, sourceFilename: old.sourceFilename,
            expectedSensorSide: old.expectedSensorSide, configuration: old.configuration,
            neutralReference: old.neutralReference)
        let altered = ReplayTrace(schemaVersion: output.trace.schemaVersion, detectorVersion: output.trace.detectorVersion,
                                  sourceFilename: output.trace.sourceFilename,
                                  expectedSensorSide: output.trace.expectedSensorSide,
                                  selection: output.trace.selection, configuration: output.trace.configuration,
                                  transactions: transactions)
        let verification = ExperimentalReplayVerifier().verify(altered)
        XCTAssertFalse(verification.passed)
        XCTAssertEqual(verification.mismatchTransaction, transactions.count - 1)
    }

    func testAnnotationValidationAndWriteOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("annotations.json")
        let valid = AnnotationSidecar(schemaVersion: 1, annotations: [
            .init(exercise: .lateralRaise, completionTimestamp: 1, completeness: .complete, note: nil)
        ])
        try AnnotationSidecarWriter().write(valid, to: url)
        XCTAssertThrowsError(try AnnotationSidecarWriter().write(valid, to: url))
        XCTAssertThrowsError(try AnnotationSidecar(schemaVersion: 1, annotations: [
            .init(exercise: .lateralRaise, completionTimestamp: 2, completeness: .complete, note: nil),
            .init(exercise: .lateralRaise, completionTimestamp: 1, completeness: .complete, note: nil)
        ]).validated())
        XCTAssertThrowsError(try AnnotationSidecar(schemaVersion: 1, annotations: [
            .init(exercise: .lateralRaise, completionTimestamp: .nan, completeness: .complete, note: nil)
        ]).validated())
    }

    func testOneToOnePartialAccountingAndFiniteZeroMetrics() throws {
        let candidates = [evidence(id: "a", exercise: .lateralRaise, completion: 1.1),
                          evidence(id: "b", exercise: .lateralRaise, completion: 2.1)]
        let annotations = AnnotationSidecar(schemaVersion: 1, annotations: [
            .init(exercise: .lateralRaise, completionTimestamp: 1, completeness: .complete, note: nil),
            .init(exercise: .lateralRaise, completionTimestamp: 2, completeness: .partial, note: nil)
        ])
        let metrics = try ExperimentalEvaluator().evaluate(candidates: candidates, annotations: annotations)
        XCTAssertEqual(metrics.truePositives, 1)
        XCTAssertEqual(metrics.falsePositives, 1)
        XCTAssertEqual(metrics.partialOrAbandonedTriggers, 1)
        let zero = try ExperimentalEvaluator().evaluate(candidates: [], annotations: .init(schemaVersion: 1, annotations: []))
        XCTAssertEqual(zero.precision, 0); XCTAssertEqual(zero.recall, 0); XCTAssertEqual(zero.f1, 0)
        XCTAssertTrue(zero.precision.isFinite && zero.recall.isFinite && zero.f1.isFinite)
    }


    func testExportsAreMachineReadableAndContainNoSourcePath() throws {
        var input = analysisInput()
        input = ExperimentalProcessorInput(samples: input.samples,
                                           sourceFilename: "nested/input.csv",
                                           selection: input.selection,
                                           expectedSensorSide: input.expectedSensorSide,
                                           configuration: input.configuration)
        let output = try ExperimentalV1Processor().process(input)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try ExperimentalV1Exporter(directory: directory).export(summary: output.summary, trace: output.trace)
        let summaryData = try Data(contentsOf: urls.summary)
        XCTAssertNoThrow(try JSONDecoder().decode(ExperimentalAnalysisResult.self, from: summaryData))
        let traceData = try Data(contentsOf: urls.replayTrace)
        XCTAssertEqual(try ReplayTrace.decodeJSONL(traceData).transactions.count, input.samples.count)
        XCTAssertFalse(String(decoding: summaryData + traceData, as: UTF8.self).contains("nested/"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix("partial") })
    }
}

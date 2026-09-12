import Foundation
import XCTest
@testable import LiftPod

final class ContinuousRepMetricsTests: XCTestCase {
    func testBriefSettlingEvidenceHandsOffWithoutQuietOrForcedZero() throws {
        let run = settlingHandoffRun()
        let decision = try XCTUnwrap(run.boundaryDecisions?.first { $0.boundaryID == "brief-settle" })
        XCTAssertEqual(decision.kind, .continuousReversal)
        XCTAssertTrue(decision.accepted, "\(decision.reason), \(String(describing: decision.innovation))")
        XCTAssertEqual(run.reps.first?.status, .available, metricFailureSummary(run.reps))
        XCTAssertLessThanOrEqual(try XCTUnwrap(run.reps.first?.finalizedAt), 3.600000001)
        XCTAssertEqual(run.configuration.quietDuration, 0.2)
        XCTAssertEqual(run.configuration.quietGyro, 0.35)
    }

    func testVerticalReversalAloneCannotUpgradeStationaryBoundary() {
        let run = settlingHandoffRun(orientationReverses: false)
        XCTAssertFalse(run.boundaryDecisions?.contains { $0.accepted && $0.kind == .continuousReversal } ?? false)
        XCTAssertEqual(run.reps.first?.status, .unavailable)
    }

    func testArchivedV2ConfigurationKeepsOriginalBoundaryBehavior() throws {
        let run = settlingHandoffRun(handoffEnabled: false)
        XCTAssertEqual(run.reps.first?.status, .unavailable)
        XCTAssertFalse(run.boundaryDecisions?.contains { $0.kind == .continuousReversal } ?? false)
        let encoded = try JSONEncoder().encode(run.configuration)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("boundaryHandoff"))
        XCTAssertEqual(try JSONDecoder().decode(RepMetricsConfiguration.self, from: encoded), run.configuration)
    }

    private func settlingHandoffRun(orientationReverses: Bool = true,
                                    handoffEnabled: Bool = true) -> RepMetricsSnapshot {
        var config = RepMetricsConfiguration.continuousV2
        if !handoffEnabled { config.boundaryHandoff = nil }
        var observer = PassiveRepMetrics(configuration: config)
        var event = cycle(id: "brief-rep", start: 1, top: 2, completion: 3)
        event.movementAxis = .init(x: 0, y: 1, z: 0)
        for index in 0...185 {
            let t = Double(index) / 50
            let angle: Double
            let rate: Double
            if t < 1 { angle = 0; rate = 0 }
            else if t < 2 { angle = (t - 1) * 0.8; rate = 0.8 }
            else if t < 3 { angle = (3 - t) * 0.8; rate = -0.8 }
            else if orientationReverses { angle = (t - 3) * 0.8; rate = 0.8 }
            else { angle = -(t - 3) * 0.8; rate = -0.8 }
            let gravity = ExperimentalVector3(x: -sin(angle), y: 0, z: cos(angle))
            let a = analyticAcceleration(at: t) / 9.80665
            observer.observe(.init(sourceTimestamp: t, sessionTime: t, sensorSide: .right,
                userAcceleration: .init(x: gravity.x * a, y: 0, z: gravity.z * a),
                rotationRate: .init(x: 0, y: rate, z: 0), gravity: gravity,
                attitude: .init(w: 1, x: 0, y: 0, z: 0), interpolationStatus: .delivered, epoch: 0))
            observer.observeBoundaryEvidence(index == 154 ? [boundary(id: "brief-settle", observed: 3,
                confirmed: 3.08, kind: .stationary, candidates: [event.id], interval: 3...3.08)] : [], at: t)
            observer.observeCommitted(index == 154 ? [event] : [], at: t)
        }
        return observer.snapshot
    }

    func testNineCurlCaptureHandoffRegressionAndReplay() async throws {
        let fixture = try ContinuousCaptureFixture.load(name: "nine-curl-brief-bottoms")
        var originalV2 = RepMetricsConfiguration.continuousV2
        originalV2.boundaryHandoff = nil
        var committedTimes: [Double]?
        for configuration in [nil, originalV2, RepMetricsConfiguration.continuousV2, RepMetricsConfiguration.devicePath3D, RepMetricsConfiguration.cyclicDevicePath3D] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let engine = V2SetEngine(), recorder = V2SessionRecorder(directory: directory)
            try await engine.start(profile: .adaptiveCurlV6, recorder: recorder, motionActive: true,
                                   sideVerified: true, noOtherRecording: true, setupConfirmed: true,
                                   metricsConfiguration: configuration)
            for (index, raw) in fixture.raw.enumerated() {
                if index == fixture.expected.endRequestBeforeInputSequence {
                    try await engine.requestEnd(at: fixture.raw[index - 1].sourceTimestamp)
                }
                await engine.ingest(raw)
            }
            let snapshot = await engine.snapshot
            XCTAssertEqual(snapshot.committedCount, 9)
            let times = snapshot.recentEvents.filter(\.committed).map(\.completionTimestamp)
            if let committedTimes { XCTAssertEqual(times, committedTimes) }
            else { committedTimes = times }
            let bundle = await engine.completedBundle
            let archive = try V2ReplayArchive.load(from: XCTUnwrap(bundle).directory)
            let replay = V2ReplayVerifier().verify(archive)
            XCTAssertTrue(replay.passed, "\(replay.field ?? "unknown") at \(String(describing: replay.mismatchSequence))")
            if let metrics = snapshot.metrics {
                XCTAssertEqual(metrics.reps.count, 9)
                XCTAssertTrue(metrics.reps.allSatisfy { $0.status != .pending })
                if configuration?.devicePath == nil {
                    XCTAssertEqual(metrics.reps.filter { $0.status == .available }.count,
                                   configuration?.boundaryHandoff == nil ? 1 : 2)
                } else if configuration?.devicePath?.cyclic != nil {
                    XCTAssertEqual(metrics.reps.filter { $0.status == .available }.count, 9,
                                   "\(metricFailureSummary(metrics.reps))")
                    for (index,rep) in metrics.reps.enumerated() {
                        print("CYCLIC REP \(index+1): mean=\(String(describing:rep.meanLiftingSpeed)) peak=\(String(describing:rep.peakLiftingSpeed)) lower=\(String(describing:rep.meanLoweringSpeed)) uncertainty=\(String(describing:rep.maximumVelocityStandardDeviation)) bias=\(String(describing:rep.equivalentAccelerationBias)) residual=\(String(describing:rep.endpointVelocityResidual))")
                    }
                } else {
                    XCTAssertEqual(metrics.reps.filter { $0.status == .available }.count, 1,
                                   "3D capture availability is not a nine-of-nine release gate pass")
                }
                for (event, metric) in zip(fixture.legacyCommittedEvents, metrics.reps) {
                    XCTAssertLessThanOrEqual(try XCTUnwrap(metric.finalizedAt) - event.completionTimestamp, 0.600000001)
                }
                print("NINE CURL version=\(configuration?.version ?? "off") handoff=\(configuration?.boundaryHandoff != nil) available=\(metrics.reps.filter { $0.status == .available }.count)/9: \(metricFailureSummary(metrics.reps))")
                print("NINE CURL decisions: \(boundaryDecisionSummary(metrics))")
            }
        }
    }

    func testV1HashIsFrozenAndV2ConfigurationIsExplicitAndValidated() throws {
        let v1 = RepMetricsConfiguration()
        XCTAssertEqual(v1.version, "vertical-metrics-v1")
        XCTAssertEqual(v1.contentHash, "4a58add833093280ec49ce3968df6a7d2f4737040ef0ffb2f8984faccd786c5f")
        XCTAssertEqual(try v1.validated(), v1)

        let v2 = RepMetricsConfiguration.continuousV2
        XCTAssertEqual(v2.version, "vertical-metrics-v2")
        XCTAssertNotEqual(v2.contentHash, v1.contentHash)
        XCTAssertEqual(try v2.validated(), v2)
        var invalid = v2
        invalid.finalizationDeadline = 0.601
        XCTAssertThrowsError(try invalid.validated())
        invalid = v2
        invalid.maximumVelocityStandardDeviation = nil
        XCTAssertThrowsError(try invalid.validated())
    }

    func testLatestCaptureFixtureIsLosslessAndRetainsEightCommittedEvents() throws {
        let fixture = try ContinuousCaptureFixture.load()

        XCTAssertEqual(fixture.raw.count, fixture.expected.rawSampleCount)
        XCTAssertEqual(fixture.uniform.count, fixture.expected.uniformSampleCount)
        XCTAssertEqual(fixture.uniformBatchCounts.count, fixture.raw.count)
        XCTAssertEqual(fixture.uniformBatchCounts.reduce(0, +), fixture.uniform.count)
        XCTAssertEqual(fixture.legacyCommittedEvents.count, fixture.expected.committedRepCount)
        XCTAssertEqual(Set(fixture.legacyCommittedEvents.map(\.id)).count, fixture.expected.committedRepCount)
        XCTAssertTrue(fixture.legacyCommittedEvents.allSatisfy { $0.committed && $0.rejectionReason == nil })
        XCTAssertTrue(zip(fixture.raw, fixture.raw.dropFirst()).allSatisfy {
            $0.0.sourceTimestamp < $0.1.sourceTimestamp && $0.0.index < $0.1.index
        })
        XCTAssertTrue(zip(fixture.uniform, fixture.uniform.dropFirst()).allSatisfy {
            $0.0.sourceTimestamp < $0.1.sourceTimestamp
        })
        XCTAssertEqual(fixture.expected.legacyAvailableMetricCount, 2,
                       "The archived V1 result is context, not speed ground truth")
        XCTAssertFalse(fixture.speedValuesAreGroundTruth)

        for pair in fixture.expected.sharedBottomCandidatePairs {
            XCTAssertEqual(pair.count, 2)
            let first = fixture.legacyCommittedEvents[pair[0]]
            let second = fixture.legacyCommittedEvents[pair[1]]
            XCTAssertLessThan(first.completionTimestamp, second.startTimestamp)
            XCTAssertLessThan(second.startTimestamp - first.completionTimestamp, 1.5)
        }
    }

    func testLatestCaptureRawReproducesRecordedUniformStreamExactly() throws {
        let fixture = try ContinuousCaptureFixture.load()
        var resampler = V2StreamingResampler()
        var replayed: [ResampledMotionSample] = []
        for (index, raw) in fixture.raw.enumerated() {
            let step = try resampler.append(raw)
            XCTAssertNil(step.discontinuity)
            XCTAssertEqual(step.samples.count, fixture.uniformBatchCounts[index])
            replayed.append(contentsOf: step.samples)
        }
        XCTAssertEqual(replayed.count, fixture.uniform.count)
        for (actual, recorded) in zip(replayed, fixture.uniform) {
            XCTAssertEqual(actual.sourceTimestamp, recorded.sourceTimestamp, accuracy: 1e-9)
            XCTAssertEqual(actual.sessionTime, recorded.sessionTime, accuracy: 1e-9)
            XCTAssertEqual(actual.sensorSide, recorded.sensorSide)
            assertVector(actual.userAcceleration, recorded.userAcceleration)
            assertVector(actual.rotationRate, recorded.rotationRate)
            assertVector(actual.gravity, recorded.gravity)
            XCTAssertEqual(actual.attitude.w, recorded.attitude.w, accuracy: 1e-9)
            XCTAssertEqual(actual.attitude.x, recorded.attitude.x, accuracy: 1e-9)
            XCTAssertEqual(actual.attitude.y, recorded.attitude.y, accuracy: 1e-9)
            XCTAssertEqual(actual.attitude.z, recorded.attitude.z, accuracy: 1e-9)
            XCTAssertEqual(actual.interpolationStatus, recorded.interpolationStatus)
            XCTAssertEqual(actual.epoch, recorded.epoch)
        }
    }

    func testLatestCaptureV7CountsAreIndependentOfV2MetricsAndFinalizeByDeadline() async throws {
        let fixture = try ContinuousCaptureFixture.load()
        let enabledRecorder = V2TestRecorder()
        let disabledRecorder = V2TestRecorder()
        let enabled = try await runCapture(fixture, metrics: .continuousV2, recorder: enabledRecorder)
        let disabled = try await runCapture(fixture, metrics: nil, recorder: disabledRecorder)

        XCTAssertEqual(enabled.snapshot.committedCount, fixture.expected.committedRepCount)
        XCTAssertEqual(disabled.snapshot.committedCount, fixture.expected.committedRepCount)
        XCTAssertEqual(enabled.snapshot.recentEvents.map(\.id), disabled.snapshot.recentEvents.map(\.id))
        XCTAssertEqual(enabled.snapshot.recentEvents.map(\.completionTimestamp),
                       disabled.snapshot.recentEvents.map(\.completionTimestamp))

        let reps = try XCTUnwrap(enabled.snapshot.metrics?.reps)
        XCTAssertEqual(reps.count, fixture.expected.committedRepCount)
        XCTAssertTrue(reps.allSatisfy { $0.status != .pending }, metricFailureSummary(reps))
        XCTAssertEqual(enabled.firstFinal.count, fixture.expected.committedRepCount)
        for rep in reps {
            let event = try XCTUnwrap(enabled.snapshot.recentEvents.first { $0.id == rep.id })
            let finalizedAt = try XCTUnwrap(rep.finalizedAt)
            XCTAssertLessThanOrEqual(finalizedAt - event.completionTimestamp, 0.600_000_001,
                                     "\(rep.id) exceeded the immutable publication deadline")
        }
    }

    func testAnalyticBackToBackRepsAcceptNonzeroAccelerationReversal() throws {
        let run = analyticContinuousRun()
        XCTAssertEqual(run.reps.count, 3)
        XCTAssertTrue(run.reps.allSatisfy { $0.status == .available },
                      "\(metricFailureSummary(run.reps)); \(boundaryDecisionSummary(run))")

        let first = try XCTUnwrap(run.reps.first)
        let second = try XCTUnwrap(run.reps.last)
        XCTAssertEqual(try XCTUnwrap(first.peakLiftingSpeed), 0.8, accuracy: 0.14)
        XCTAssertEqual(try XCTUnwrap(first.meanLiftingSpeed), 2 * 0.8 / .pi, accuracy: 0.10)
        XCTAssertEqual(first.boundaryKind, .continuousReversal)
        XCTAssertNil(first.bottomPauseDuration, "The first rep has no preceding set boundary")
        XCTAssertEqual(second.bottomPauseDuration ?? -1, 0, accuracy: 0.04)
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.finalizedAt) - 3.0, 0.600_000_001)

        let decision = try XCTUnwrap(run.boundaryDecisions?.first { $0.boundaryID == "shared-bottom" })
        XCTAssertTrue(decision.accepted, "\(decision.reason)")
        XCTAssertEqual(decision.kind, .continuousReversal)
        XCTAssertEqual(Set(decision.associatedCandidateIDs), Set(["rep-1", "rep-2"]))
        XCTAssertGreaterThan(abs(analyticAcceleration(at: 3)), 2,
                             "The fixture must exercise reversal without a quiet acceleration dwell")
    }

    func testFinalizedMetricsAndSlowdownBaselineAreImmutable() throws {
        var observer = analyticContinuousObserver()
        let finalized = observer.snapshot
        XCTAssertTrue(finalized.reps.allSatisfy { $0.status != .pending })
        let baseline = try XCTUnwrap(finalized.baselineMeanLiftingSpeed)

        for index in 391...460 {
            let time = Double(index) / 50
            observer.observe(analyticFrame(time: time))
            observer.observeBoundaryEvidence([], at: time)
            observer.observeCommitted([], at: time)
        }
        observer.observeBoundaryEvidence([
            boundary(id: "late-conflict", observed: 3, confirmed: 9.4, kind: .continuousReversal,
                     candidates: ["rep-1", "rep-2"], interval: 2.96...3.04)
        ], at: 9.4)

        XCTAssertEqual(observer.snapshot.reps, finalized.reps)
        XCTAssertEqual(try XCTUnwrap(observer.snapshot.baselineMeanLiftingSpeed), baseline, accuracy: 1e-12)
    }

    func testRejectedHighVelocityBoundaryDoesNotContaminateAcceptedBoundary() throws {
        let control = analyticContinuousObserver().snapshot
        let challenged = analyticContinuousObserver(includingRejectedBoundary: true).snapshot
        let rejected = try XCTUnwrap(challenged.boundaryDecisions?.first { $0.boundaryID == "early-zero-claim" })
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.reason, .excessiveInnovation)
        XCTAssertGreaterThan(abs(try XCTUnwrap(rejected.innovation)), 0.20)

        let controlAccepted = try XCTUnwrap(control.boundaryDecisions?.first { $0.boundaryID == "shared-bottom" })
        let challengedAccepted = try XCTUnwrap(challenged.boundaryDecisions?.first { $0.boundaryID == "shared-bottom" })
        XCTAssertTrue(challengedAccepted.accepted)
        XCTAssertEqual(challengedAccepted.estimatedVelocity, controlAccepted.estimatedVelocity)
        XCTAssertEqual(challengedAccepted.velocityStandardDeviation, controlAccepted.velocityStandardDeviation)
        XCTAssertEqual(challenged.reps, control.reps)
    }

    func testSourceGapFinalizesPendingRepUnavailableWithinDeadline() throws {
        var observer = PassiveRepMetrics(configuration: .continuousV2)
        let event = cycle(id: "gap-rep", start: 1, top: 2, completion: 3)
        for index in 0...154 {
            let time = Double(index) / 50
            observer.observe(analyticFrame(time: time))
            observer.observeBoundaryEvidence([], at: time)
            observer.observeCommitted(index == 154 ? [event] : [], at: time)
        }
        XCTAssertEqual(observer.snapshot.reps.first?.status, .pending)
        observer.observe(analyticFrame(time: 3.40))
        let result = try XCTUnwrap(observer.snapshot.reps.first)
        XCTAssertEqual(result.id, event.id)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.reason, .invalidInterval)
        XCTAssertEqual(try XCTUnwrap(result.finalizedAt), 3.40, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.finalizedAt) - event.completionTimestamp, 0.60)
    }

    func testVerticalMetricsAreInvariantToEquivalentSensorRotation() throws {
        let normal = analyticContinuousObserver().snapshot
        let rotated = analyticContinuousObserver(rotated: true).snapshot
        XCTAssertEqual(normal.reps.map(\.status), rotated.reps.map(\.status))
        XCTAssertTrue(normal.reps.allSatisfy { $0.status == .available }, metricFailureSummary(normal.reps))
        for (left, right) in zip(normal.reps, rotated.reps) {
            XCTAssertEqual(try XCTUnwrap(left.meanLiftingSpeed), try XCTUnwrap(right.meanLiftingSpeed), accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(left.peakLiftingSpeed), try XCTUnwrap(right.peakLiftingSpeed), accuracy: 1e-12)
            XCTAssertEqual(left.maximumVelocityStandardDeviation, right.maximumVelocityStandardDeviation)
        }
    }

    func testSameTravelAtSlowerCadenceHasLowerEstimatedSpeed() throws {
        let fast = try XCTUnwrap(stationaryRep(leg: 1, peak: 0.8).reps.first)
        let slow = try XCTUnwrap(stationaryRep(leg: 2, peak: 0.4).reps.first)
        XCTAssertEqual(fast.status, .available, metricFailureSummary([fast]))
        XCTAssertEqual(slow.status, .available, metricFailureSummary([slow]))
        XCTAssertLessThan(try XCTUnwrap(slow.meanLiftingSpeed), try XCTUnwrap(fast.meanLiftingSpeed) * 0.65)
        XCTAssertLessThan(try XCTUnwrap(slow.peakLiftingSpeed), try XCTUnwrap(fast.peakLiftingSpeed) * 0.65)
        XCTAssertGreaterThan(try XCTUnwrap(slow.liftingDuration), try XCTUnwrap(fast.liftingDuration) * 1.7)
    }

    func testMissingInitialStationaryAnchorDoesNotInventVelocity() throws {
        var observer = PassiveRepMetrics(configuration: .continuousV2)
        let event = cycle(id: "no-anchor", start: 0.1, top: 1.0, completion: 2.0)
        for index in 0...130 {
            let time = Double(index) / 50
            observer.observe(analyticFrame(time: time, acceleration: analyticAcceleration(at: time + 1)))
            let evidence = index == 104
                ? [boundary(id: "no-anchor-bottom", observed: 2, confirmed: 2.08,
                            kind: .continuousReversal, candidates: [event.id], interval: 1.96...2.04)] : []
            observer.observeBoundaryEvidence(evidence, at: time)
            observer.observeCommitted(index == 104 ? [event] : [], at: time)
        }
        let result = try XCTUnwrap(observer.snapshot.reps.first)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.reason, .missingInitialAnchor)
        XCTAssertNil(result.meanLiftingSpeed)
    }

    private func runCapture(_ fixture: ContinuousCaptureFixture,
                            metrics: RepMetricsConfiguration?,
                            recorder: V2TestRecorder) async throws -> (snapshot: V2ProcessorSnapshot, firstFinal: [String: RepMotionMetrics]) {
        let engine = V2SetEngine()
        try await engine.start(profile: .adaptiveCurlV7, recorder: recorder, motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true,
                               metricsConfiguration: metrics)
        var firstFinal: [String: RepMotionMetrics] = [:]
        for (index, raw) in fixture.raw.enumerated() {
            if index == fixture.expected.endRequestBeforeInputSequence {
                try await engine.requestEnd(at: fixture.raw[index - 1].sourceTimestamp)
            }
            await engine.ingest(raw)
            if let reps = await engine.snapshot.metrics?.reps {
                for rep in reps where rep.status != .pending && firstFinal[rep.id] == nil { firstFinal[rep.id] = rep }
                for rep in reps where firstFinal[rep.id] != nil { XCTAssertEqual(rep, firstFinal[rep.id]) }
            }
        }
        return (await engine.snapshot, firstFinal)
    }

    private func analyticContinuousRun() -> RepMetricsSnapshot { analyticContinuousObserver().snapshot }

    private func stationaryRep(leg: Double, peak: Double) -> RepMetricsSnapshot {
        var observer = PassiveRepMetrics(configuration: .continuousV2)
        let start = 1.0, top = start + leg, completion = top + leg
        let event = cycle(id: "cadence-\(leg)", start: start, top: top, completion: completion)
        let end = completion + 0.8
        for index in 0...Int((end * 50).rounded()) {
            let time = Double(index) / 50
            let acceleration: Double
            if time >= start && time < top {
                acceleration = peak * .pi / leg * cos(.pi * (time - start) / leg)
            } else if time >= top && time < completion {
                acceleration = -peak * .pi / leg * cos(.pi * (time - top) / leg)
            } else { acceleration = 0 }
            let moving = time >= start && time < completion
            let sample = ResampledMotionSample(
                sourceTimestamp: time, sessionTime: time, sensorSide: .right,
                userAcceleration: .init(x: 0, y: 0, z: -acceleration / 9.80665),
                rotationRate: .init(x: 0, y: moving ? 0.8 : 0, z: 0),
                gravity: .init(x: 0, y: 0, z: -1),
                attitude: .init(w: 1, x: 0, y: 0, z: 0),
                interpolationStatus: .delivered, epoch: 0)
            observer.observe(sample)
            observer.observeBoundaryEvidence([], at: time)
            observer.observeCommitted(time >= event.detectionTimestamp ? [event] : [], at: time)
        }
        return observer.snapshot
    }

    private func analyticContinuousObserver(includingRejectedBoundary: Bool = false,
                                            rotated: Bool = false) -> PassiveRepMetrics {
        var observer = PassiveRepMetrics(configuration: .continuousV2)
        let first = cycle(id: "rep-1", start: 1, top: 2, completion: 3)
        let second = cycle(id: "rep-2", start: 3, top: 4, completion: 5)
        let third = cycle(id: "rep-3", start: 5, top: 6, completion: 7)
        for index in 0...390 {
            let time = Double(index) / 50
            observer.observe(analyticFrame(time: time, rotated: rotated))
            var evidence: [V2BoundaryEvidence] = []
            var committed: [V2CycleEvidence] = []
            if index == 154 {
                if includingRejectedBoundary {
                    evidence.append(boundary(id: "early-zero-claim", observed: 2.90, confirmed: 3.08,
                                             kind: .continuousReversal, candidates: [first.id, second.id],
                                             interval: 2.86...2.94))
                }
                evidence.append(boundary(id: "shared-bottom", observed: 3, confirmed: 3.08,
                                         kind: .continuousReversal, candidates: [first.id, second.id],
                                         interval: 2.96...3.04))
                committed = [first]
            } else if index == 254 {
                evidence = [boundary(id: "shared-bottom-2", observed: 5, confirmed: 5.08,
                                     kind: .continuousReversal, candidates: [second.id, third.id],
                                     interval: 4.96...5.04)]
                committed = [second]
            } else if index == 354 {
                committed = [third]
            } else if index == 360 {
                evidence = [boundary(id: "final-stationary", observed: 7, confirmed: 7.20,
                                     kind: .stationary, candidates: [third.id], interval: 7...7.20)]
            }
            observer.observeBoundaryEvidence(evidence, at: time)
            observer.observeCommitted(committed, at: time)
        }
        return observer
    }

    private func analyticFrame(time: Double, acceleration: Double? = nil,
                               rotated: Bool = false) -> ResampledMotionSample {
        let acceleration = acceleration ?? analyticAcceleration(at: time)
        let moving = time >= 1 && time < 7
        let direction: Double
        switch time {
        case 1..<2, 3..<4, 5..<6: direction = 0.8
        case 2..<3, 4..<5, 6..<7: direction = -0.8
        default: direction = 0
        }
        return .init(sourceTimestamp: time, sessionTime: time, sensorSide: .right,
                     userAcceleration: rotated
                        ? .init(x: -acceleration / 9.80665, y: 0, z: 0)
                        : .init(x: 0, y: 0, z: -acceleration / 9.80665),
                     rotationRate: .init(x: 0, y: moving ? direction : 0, z: 0),
                     gravity: rotated ? .init(x: -1, y: 0, z: 0) : .init(x: 0, y: 0, z: -1),
                     attitude: .init(w: 1, x: 0, y: 0, z: 0),
                     interpolationStatus: .delivered, epoch: 0)
    }

    private func analyticAcceleration(at time: Double) -> Double {
        switch time {
        case 1..<2: return 0.8 * .pi * cos(.pi * (time - 1))
        case 2..<3: return -0.8 * .pi * cos(.pi * (time - 2))
        case 3..<4: return 0.8 * .pi * cos(.pi * (time - 3))
        case 4..<5: return -0.8 * .pi * cos(.pi * (time - 4))
        case 5..<6: return 0.8 * .pi * cos(.pi * (time - 5))
        case 6..<7: return -0.8 * .pi * cos(.pi * (time - 6))
        default: return 0
        }
    }

    private func cycle(id: String, start: Double, top: Double, completion: Double) -> V2CycleEvidence {
        let profile = V2DSPProfile.adaptiveCurlV7
        return .init(id: id, setID: v2Descriptor(profile: profile).setID, exercise: .bicepsCurl,
                     authorizationSource: .manual, profileID: profile.profileID,
                     dspContentHash: profile.contentHash, detectorEpoch: 0,
                     cycleSequence: id == "rep-2" ? 2 : (id == "rep-3" ? 3 : 1), startTimestamp: start,
                     topTimestamp: top, completionTimestamp: completion,
                     detectionTimestamp: completion + 0.08, bottom: 0, top: 2, returned: 0,
                     outboundArea: 1, returnArea: 1, committed: true, rejectionReason: nil)
    }

    private func boundary(id: String, observed: Double, confirmed: Double, kind: V2BoundaryKind,
                          candidates: [String], interval: ClosedRange<Double>) -> V2BoundaryEvidence {
        .init(boundaryID: id, sourceSegmentID: "analytic-epoch-0",
              observedTimestamp: observed, confirmedTimestamp: confirmed, kind: kind,
              associatedCandidateIDs: candidates, endpointStartTimestamp: interval.lowerBound,
              endpointEndTimestamp: interval.upperBound,
              returnedTimestamp: kind == .continuousReversal ? observed : nil,
              direction: kind == .continuousReversal ? .loweringToLifting : .stationary)
    }

    private func assertVector(_ actual: ExperimentalVector3, _ expected: ExperimentalVector3,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-9, file: file, line: line)
    }

}

/// Kept separate so a failed capture promotion gate is distinguishable from numerical/unit regressions.
final class ContinuousMetricsReleaseGateTests: XCTestCase {
    @MainActor
    func testAppDefaultsToCyclic3DWithoutChangingDetectorOrLegacyConfiguration() {
        let suite = "RepLabDefaultsTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = ExperimentalV2Model(preferences: preferences)
        XCTAssertTrue(model.devicePathMetricsEnabled)
        XCTAssertTrue(model.continuousMetricsEnabled)
        XCTAssertEqual(model.selectedAlgorithm, .adaptiveAxis)
        XCTAssertEqual(RepMetricsConfiguration().version, "vertical-metrics-v1")
    }

    @MainActor
    func testModeChoicesPersistAndInvalidAlgorithmFallsBack() {
        let suite = "RepLabModeTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = ExperimentalV2Model(preferences: preferences)
        first.selectedAlgorithm = .adaptiveAxisV7
        first.continuousMetricsEnabled = false
        first.devicePathMetricsEnabled = true
        let second = ExperimentalV2Model(preferences: preferences)
        XCTAssertEqual(second.selectedAlgorithm, .adaptiveAxisV7)
        XCTAssertEqual(second.profile?.identity.algorithm, .adaptiveAxisV7)
        XCTAssertFalse(second.continuousMetricsEnabled)
        XCTAssertTrue(second.devicePathMetricsEnabled)
        second.devicePathMetricsEnabled = false
        XCTAssertFalse(ExperimentalV2Model(preferences: preferences).devicePathMetricsEnabled)
        second.continuousMetricsEnabled = true
        XCTAssertTrue(ExperimentalV2Model(preferences: preferences).continuousMetricsEnabled)
        preferences.set("unsupported", forKey: "repLab.detectorAlgorithm")
        XCTAssertEqual(ExperimentalV2Model(preferences: preferences).selectedAlgorithm, .adaptiveAxis)
    }

    func testLatestCaptureReportsAvailabilityWithoutClaimingValidation() async throws {
        let fixture = try ContinuousCaptureFixture.load()
        let result = try await runReleaseGateCapture(fixture)
        let reps = try XCTUnwrap(result.metrics?.reps)
        let available = reps.filter { $0.status == .available }
        XCTAssertEqual(result.committedCount, fixture.expected.committedRepCount)
        XCTAssertEqual(RepMetricsConfiguration().version, "vertical-metrics-v1",
                       "Legacy configuration construction must remain unchanged")
        XCTAssertTrue(reps.filter { $0.status == .available }.allSatisfy {
            $0.estimatorVersion == "vertical-metrics-v2"
        })
        if available.count != fixture.expected.committedRepCount {
            print("RELEASE GATE BLOCKED — available=\(available.count) required=\(fixture.expected.committedRepCount); \(metricFailureSummary(reps))")
        }
    }

    private func runReleaseGateCapture(_ fixture: ContinuousCaptureFixture) async throws -> V2ProcessorSnapshot {
        let engine = V2SetEngine()
        try await engine.start(profile: .adaptiveCurlV7, recorder: V2TestRecorder(), motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true,
                               metricsConfiguration: .continuousV2)
        for (index, raw) in fixture.raw.enumerated() {
            if index == fixture.expected.endRequestBeforeInputSequence {
                try await engine.requestEnd(at: fixture.raw[index - 1].sourceTimestamp)
            }
            await engine.ingest(raw)
        }
        return await engine.snapshot
    }
}

private func metricFailureSummary(_ reps: [RepMotionMetrics]) -> String {
    reps.map { "\($0.id):\($0.status.rawValue)/\($0.reason?.rawValue ?? "none")" }.joined(separator: ", ")
}

private func boundaryDecisionSummary(_ snapshot: RepMetricsSnapshot) -> String {
    (snapshot.boundaryDecisions ?? []).map {
        "\($0.boundaryID):\($0.accepted ? "accepted" : $0.reason.rawValue)" +
        "/innovation=\($0.innovation.map(String.init(describing:)) ?? "nil")" +
        "/nis=\($0.normalizedInnovationSquared.map(String.init(describing:)) ?? "nil")"
    }.joined(separator: ", ")
}

struct ContinuousCaptureFixture {
    struct Expected {
        let rawSampleCount: Int
        let uniformSampleCount: Int
        let committedRepCount: Int
        let legacyAvailableMetricCount: Int
        let endRequestBeforeInputSequence: Int
        let sharedBottomCandidatePairs: [[Int]]
    }

    let raw: [RawMotionSample]
    let uniform: [ResampledMotionSample]
    let uniformBatchCounts: [Int]
    let legacyCommittedEvents: [V2CycleEvidence]
    let expected: Expected
    let speedValuesAreGroundTruth: Bool

    static func load(name: String = "latest-continuous-eight-curl", file: StaticString = #filePath, line: UInt = #line) throws -> Self {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        let provenance = try XCTUnwrap(root["provenance"] as? [String: Any], file: file, line: line)
        let expectedJSON = try XCTUnwrap(root["expected"] as? [String: Any], file: file, line: line)
        let rawRows = try XCTUnwrap(root["rawRows"] as? [[Any]], file: file, line: line)
        let uniformRows = try XCTUnwrap(root["uniformRows"] as? [[Any]], file: file, line: line)
        let batchCounts = try XCTUnwrap(root["uniformBatchCounts"] as? [NSNumber], file: file, line: line).map(\.intValue)
        let eventsObject = try XCTUnwrap(root["legacyCommittedEvents"], file: file, line: line)
        let eventsData = try JSONSerialization.data(withJSONObject: eventsObject)

        func number(_ row: [Any], _ index: Int) throws -> Double {
            try XCTUnwrap(row[index] as? NSNumber, file: file, line: line).doubleValue
        }
        let raw = try rawRows.map { row in
            guard row.count == 20 else { throw FixtureError.invalidRow }
            let location = try XCTUnwrap(row[3] as? String, file: file, line: line)
            return RawMotionSample(
                index: try XCTUnwrap(row[0] as? NSNumber, file: file, line: line).uint64Value,
                sourceTimestamp: try number(row, 1), receiptUptime: try number(row, 2),
                sensorLocation: location == "Right headphone" ? .rightHeadphone : .leftHeadphone,
                userAccelerationX: try number(row, 4), userAccelerationY: try number(row, 5),
                userAccelerationZ: try number(row, 6), gravityX: try number(row, 7),
                gravityY: try number(row, 8), gravityZ: try number(row, 9),
                rotationRateX: try number(row, 10), rotationRateY: try number(row, 11),
                rotationRateZ: try number(row, 12), quaternionW: try number(row, 13),
                quaternionX: try number(row, 14), quaternionY: try number(row, 15),
                quaternionZ: try number(row, 16), roll: try number(row, 17),
                pitch: try number(row, 18), yaw: try number(row, 19))
        }
        let uniform = try uniformRows.map { row in
            guard row.count == 18 else { throw FixtureError.invalidRow }
            let sideText = row[2] as? String
            let statusText = try XCTUnwrap(row[16] as? String, file: file, line: line)
            return ResampledMotionSample(
                sourceTimestamp: try number(row, 0), sessionTime: try number(row, 1),
                sensorSide: sideText.flatMap(ExperimentalSensorSide.init(rawValue:)),
                userAcceleration: .init(x: try number(row, 3), y: try number(row, 4), z: try number(row, 5)),
                rotationRate: .init(x: try number(row, 6), y: try number(row, 7), z: try number(row, 8)),
                gravity: .init(x: try number(row, 9), y: try number(row, 10), z: try number(row, 11)),
                attitude: .init(w: try number(row, 12), x: try number(row, 13),
                                y: try number(row, 14), z: try number(row, 15)),
                interpolationStatus: try XCTUnwrap(InterpolationStatus(rawValue: statusText), file: file, line: line),
                epoch: try XCTUnwrap(row[17] as? NSNumber, file: file, line: line).intValue)
        }
        func integer(_ key: String) throws -> Int {
            try XCTUnwrap(expectedJSON[key] as? NSNumber, file: file, line: line).intValue
        }
        let pairs = try XCTUnwrap(expectedJSON["sharedBottomCandidatePairs"] as? [[NSNumber]], file: file, line: line)
            .map { $0.map(\.intValue) }
        return .init(raw: raw, uniform: uniform, uniformBatchCounts: batchCounts,
                     legacyCommittedEvents: try JSONDecoder().decode([V2CycleEvidence].self, from: eventsData),
                     expected: .init(rawSampleCount: try integer("rawSampleCount"),
                                     uniformSampleCount: try integer("uniformSampleCount"),
                                     committedRepCount: try integer("committedRepCount"),
                                     legacyAvailableMetricCount: try integer("legacyAvailableMetricCount"),
                                     endRequestBeforeInputSequence: try integer("endRequestBeforeInputSequence"),
                                     sharedBottomCandidatePairs: pairs),
                     speedValuesAreGroundTruth: (provenance["speedValuesAreGroundTruth"] as? Bool) ?? true)
    }

    private enum FixtureError: Error { case invalidRow }
}

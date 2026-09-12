import XCTest
@testable import LiftPod

final class PassiveRepMetricsTests: XCTestCase {
    func testConfigurationHashAndValidation() throws {
        let original = RepMetricsConfiguration()
        XCTAssertEqual(try original.validated(), original)
        var changed = original; changed.accelerationSign = 1
        XCTAssertNotEqual(original.contentHash, changed.contentHash)
        changed.version = "unknown"
        XCTAssertThrowsError(try changed.validated())
        changed = original; changed.maximumEquivalentBias = .nan
        XCTAssertThrowsError(try changed.validated())
    }

    func testProjectionSignAndMountRotationInvariance() throws {
        let configuration = RepMetricsConfiguration()
        let a = frame(time: 0, acceleration: 2)
        let b = frame(time: 0, acceleration: 2, rotated: true)
        XCTAssertEqual(try XCTUnwrap(PassiveRepMetrics.verticalAcceleration(a, configuration: configuration)), 2, accuracy: 1e-12)
        XCTAssertEqual(PassiveRepMetrics.verticalAcceleration(a, configuration: configuration),
                       PassiveRepMetrics.verticalAcceleration(b, configuration: configuration))
    }

    func testKnownTrajectorySpeedAndTiming() throws {
        let result = try XCTUnwrap(run().reps.first)
        XCTAssertEqual(result.status, .available, "\(String(describing: result.reason))")
        XCTAssertEqual(try XCTUnwrap(result.peakLiftingSpeed), 0.8, accuracy: 0.08)
        XCTAssertEqual(try XCTUnwrap(result.peakLoweringSpeed), 0.8, accuracy: 0.08)
        // v(t) = 0.8 sin²(pi*t): travel is 0.4 m; speed threshold trims near-zero tails.
        let movingDuration = 1 - 2 * asin(sqrt(0.04 / 0.8)) / .pi
        XCTAssertEqual(try XCTUnwrap(result.meanLiftingSpeed), 0.4 / movingDuration, accuracy: 0.06)
        XCTAssertEqual(try XCTUnwrap(result.liftingDuration), movingDuration, accuracy: 0.08)
        XCTAssertEqual(try XCTUnwrap(result.loweringDuration), movingDuration, accuracy: 0.08)
        XCTAssertEqual(try XCTUnwrap(result.topPauseDuration), 0.4, accuracy: 0.12)
        XCTAssertGreaterThan(try XCTUnwrap(result.movementStart), 0.95)
        XCTAssertLessThan(abs(try XCTUnwrap(result.verticalClosure)), 0.05)
    }

    func testSlowerSameTravelHasLowerMeanAndPeak() throws {
        let fast = try XCTUnwrap(run().reps.first)
        let slow = try XCTUnwrap(run(leg: 2, peak: 0.4).reps.first)
        XCTAssertEqual(slow.status, .available, "\(String(describing: slow.reason))")
        XCTAssertLessThan(try XCTUnwrap(slow.meanLiftingSpeed), try XCTUnwrap(fast.meanLiftingSpeed) * 0.6)
        XCTAssertLessThan(try XCTUnwrap(slow.peakLiftingSpeed), try XCTUnwrap(fast.peakLiftingSpeed) * 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(slow.liftingDuration), try XCTUnwrap(fast.liftingDuration) * 1.8)
    }

    func testLongTopPauseDoesNotRequireGyroRest() throws {
        let result = try XCTUnwrap(run(pause: 1.2, topGyro: 0.7).reps.first)
        XCTAssertEqual(result.status, .available, "\(String(describing: result.reason))")
        XCTAssertGreaterThan(try XCTUnwrap(result.topPauseDuration), 1)
    }

    func testRotationDoesNotChangeSpeeds() throws {
        XCTAssertEqual(run().reps, run(rotated: true).reps)
    }

    func testMissingStartHoldDoesNotInventZeroVelocity() throws {
        let result = try XCTUnwrap(run(noStartHold: true).reps.first)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.reason, .missingStartHold)
        XCTAssertNil(result.meanLiftingSpeed)
    }

    func testMissingEndHoldFinalizesUnavailable() throws {
        let result = try XCTUnwrap(run(noEndHold: true).reps.first)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.reason, .missingEndHold)
    }

    func testWrongSignFailsInsteadOfAutoFlippingEachRep() throws {
        var configuration = RepMetricsConfiguration(); configuration.accelerationSign = 1
        let result = try XCTUnwrap(run(configuration: configuration).reps.first)
        XCTAssertEqual(result.reason, .ambiguousDirection)
        XCTAssertNil(result.peakLiftingSpeed)
    }

    func testUncommittedEventsAndDuplicateDelivery() {
        var observer = PassiveRepMetrics()
        var event = event()
        observer.observeCommitted([event, event], at: event.detectionTimestamp)
        XCTAssertEqual(observer.snapshot.reps.count, 1)
        event = self.event(id: "rejected"); event.committed = false
        observer.observeCommitted([event], at: event.detectionTimestamp)
        XCTAssertEqual(observer.snapshot.reps.count, 1)
    }

    func testGapAndInterruptionCannotFinalizePendingSpeed() {
        var observer = PassiveRepMetrics()
        for index in 0...172 { observer.observe(trajectory(index: index)) }
        observer.observeCommitted([event()], at: 3.44)
        XCTAssertEqual(observer.snapshot.reps.first?.status, .pending)
        observer.observe(frame(time: 3.8, acceleration: 0))
        XCTAssertEqual(observer.snapshot.reps.first?.reason, .invalidInterval)
        observer.finish(at: 3.8, interrupted: true)
        XCTAssertNil(observer.snapshot.reps.first?.peakLiftingSpeed)
    }

    func testOrderedBatchingProducesSameResults() {
        var a = PassiveRepMetrics(), b = PassiveRepMetrics()
        let samples = (0...230).map { trajectory(index: $0) }
        let event = event()
        for sample in samples {
            a.observe(sample)
            if sample.sourceTimestamp >= event.detectionTimestamp { a.observeCommitted([event], at: sample.sourceTimestamp) }
        }
        for start in stride(from: 0, to: samples.count, by: 7) {
            for sample in samples[start..<min(samples.count, start + 7)] {
                b.observe(sample)
                if sample.sourceTimestamp >= event.detectionTimestamp { b.observeCommitted([event], at: sample.sourceTimestamp) }
            }
        }
        XCTAssertEqual(a.snapshot, b.snapshot)
    }

    func testSetSlowdownUsesArithmeticMeanOfFirstThreeEligibleReps() {
        var reps = (0..<4).map { RepMotionMetrics(id: "\($0)", setID: v2Descriptor().setID, status: .available, updatedAt: 0) }
        for (index, speed) in [0.4, 0.6, 0.8, 0.3].enumerated() { reps[index].meanLiftingSpeed = speed }
        let snapshot = RepMetricsSnapshot(configuration: .init(), configurationHash: "test", reps: reps)
        XCTAssertEqual(snapshot.baselineMeanLiftingSpeed ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(snapshot.slowdownPercent(for: reps[3]) ?? 0, 50, accuracy: 1e-9)
    }

    func testEngineMetricsEnabledAndDisabledPreserveRepEvents() async throws {
        let enabled = V2SetEngine(), disabled = V2SetEngine()
        let a = V2TestRecorder(), b = V2TestRecorder()
        try await enabled.start(profile: .adaptiveCurlV6, recorder: a, motionActive: true,
                                sideVerified: true, noOtherRecording: true, setupConfirmed: true)
        try await disabled.start(profile: .adaptiveCurlV6, recorder: b, motionActive: true,
                                 sideVerified: true, noOtherRecording: true, setupConfirmed: true, metricsConfiguration: nil)
        for index in 0...400 {
            let raw = rawCurl(index)
            await enabled.ingest(raw); await disabled.ingest(raw)
        }
        let left = await enabled.snapshot, right = await disabled.snapshot
        XCTAssertEqual(left.committedCount, right.committedCount)
        XCTAssertEqual(left.recentEvents.map(\.id), right.recentEvents.map(\.id))
        XCTAssertEqual(left.recentEvents.map(\.completionTimestamp), right.recentEvents.map(\.completionTimestamp))
        XCTAssertGreaterThan(left.committedCount, 0)
        XCTAssertNotNil(left.metrics); XCTAssertNil(right.metrics)
    }

    func testRecordedMetricsReplayAndRehashedTampering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = V2SetEngine(), recorder = V2SessionRecorder(directory: root)
        try await engine.start(profile: .adaptiveCurlV6, recorder: recorder, motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true)
        for index in 0...400 { await engine.ingest(rawCurl(index)) }
        try await engine.requestEnd(at: 8)
        for index in 401...425 { await engine.ingest(rawCurl(index)) }
        let bundle = await engine.completedBundle
        let archive = try V2ReplayArchive.load(from: XCTUnwrap(bundle).directory)
        XCTAssertEqual(archive.manifest.metricsConfigurationHash, RepMetricsConfiguration().contentHash)
        let replay = V2ReplayVerifier().verify(archive)
        XCTAssertTrue(replay.passed, "\(String(describing: replay.field)) at \(String(describing: replay.mismatchSequence))")
        XCTAssertEqual(archive.transactions.last?.output.metrics?.reps.first?.status, .available)
        var transactions = archive.transactions
        let index = try XCTUnwrap(transactions.firstIndex { !($0.output.metrics?.reps.isEmpty ?? true) })
        let original = transactions[index]
        var reps = try XCTUnwrap(original.output.metrics).reps
        reps[0].peakLiftingSpeed = 99
        var output = original.output
        output.metrics = .init(configuration: .init(), configurationHash: RepMetricsConfiguration().contentHash, reps: reps)
        transactions[index] = .init(schemaVersion: original.schemaVersion, processorVersion: original.processorVersion,
                                     ingestSequence: original.ingestSequence, boundary: original.boundary,
                                     input: original.input, output: output, uniformSamples: original.uniformSamples,
                                     profileID: original.profileID, profileHash: original.profileHash)
        XCTAssertEqual(V2ReplayVerifier().verify(.init(manifest: archive.manifest, profile: archive.profile,
                                                       transactions: transactions)).field, "regeneratedMetrics")
        var badManifest = archive.manifest; badManifest.metricsConfigurationHash = "wrong"
        XCTAssertEqual(V2ReplayVerifier().verify(.init(manifest: badManifest, profile: archive.profile,
                                                       transactions: archive.transactions)).field, "metricsConfiguration")
        XCTAssertFalse(V2ReplayVerifier().verify(.init(manifest: archive.manifest, profile: archive.profile,
                                                       transactions: Array(archive.transactions.dropLast()))).passed)
    }

    func testPendingFinalizationAndTimingFallback() throws {
        var observer = PassiveRepMetrics()
        for index in 0...172 { observer.observe(trajectory(index: index)) }
        observer.observeCommitted([event()], at: 3.44)
        observer.finish(at: 3.44, interrupted: false)
        let result = try XCTUnwrap(observer.snapshot.reps.first)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.reason, .missingEndHold)
        XCTAssertEqual(result.timingSource, .detectorLandmarks)
        XCTAssertNotNil(result.liftingDuration)
        XCTAssertNil(result.meanLiftingSpeed)
    }

    private func rawCurl(_ index: Int) -> RawMotionSample {
        // Real v6 detector sees a smooth two-radian gravity rotation with an observable gyro axis.
        let t = Double(index) / 50
        let phase = max(0, min(1, (t - 3.5) / 2))
        let angle = 2.2 * sin(.pi * phase)
        let rate = t > 3.5 && t < 5.5 ? 2.2 * .pi / 2 * cos(.pi * phase) : 0
        let gravity = ExperimentalVector3(x: -sin(angle), y: 0, z: cos(angle))
        var vertical = 0.0
        if t >= 3.5 && t < 4.5 { vertical = 0.8 * .pi * sin(2 * .pi * (t - 3.5)) }
        if t >= 4.5 && t < 5.5 { vertical = -0.8 * .pi * sin(2 * .pi * (t - 4.5)) }
        return experimentalRawSample(index: UInt64(index), time: t, side: .rightHeadphone,
                                     acceleration: .init(x: gravity.x * vertical / 9.80665, y: 0,
                                                         z: gravity.z * vertical / 9.80665),
                                     gravity: gravity,
                                     rotation: .init(x: 0, y: rate, z: 0))
    }

    private func run(leg: Double = 1, peak: Double = 0.8, pause: Double = 0.4,
                     rotated: Bool = false, noStartHold: Bool = false, noEndHold: Bool = false,
                     topGyro: Double = 0, configuration: RepMetricsConfiguration = .init()) -> RepMetricsSnapshot {
        var observer = PassiveRepMetrics(configuration: configuration)
        let event = event(leg: leg, pause: pause)
        for index in 0...Int((event.completionTimestamp + 2.2) * 50) {
            let sample = trajectory(index: index, leg: leg, peak: peak, pause: pause, rotated: rotated,
                                    noStartHold: noStartHold, noEndHold: noEndHold, topGyro: topGyro)
            observer.observe(sample)
            if sample.sourceTimestamp >= event.detectionTimestamp { observer.observeCommitted([event], at: sample.sourceTimestamp) }
        }
        return observer.snapshot
    }

    private func event(id: String = "rep", leg: Double = 1, pause: Double = 0.4) -> V2CycleEvidence {
        let profile = V2DSPProfile.adaptiveCurlV6
        return .init(id: id, setID: v2Descriptor().setID, exercise: .bicepsCurl, authorizationSource: .manual,
                     profileID: profile.profileID, dspContentHash: profile.contentHash, detectorEpoch: 0, cycleSequence: 1,
                     startTimestamp: 1, topTimestamp: 1 + leg + pause / 2, completionTimestamp: 1 + 2 * leg + pause,
                     detectionTimestamp: 1 + 2 * leg + pause + 0.04, bottom: 0, top: 2, returned: 0,
                     outboundArea: 1, returnArea: 1, committed: true, rejectionReason: nil)
    }

    private func trajectory(index: Int, leg: Double = 1, peak: Double = 0.8, pause: Double = 0.4,
                            rotated: Bool = false, noStartHold: Bool = false, noEndHold: Bool = false,
                            topGyro: Double = 0) -> ResampledMotionSample {
        let t = Double(index) / 50
        let lower = 1 + leg + pause, end = lower + leg
        var acceleration = 0.0, gyro = 0.0
        if t >= 1 && t < 1 + leg { acceleration = peak * .pi / leg * sin(2 * .pi * (t - 1) / leg); gyro = 0.5 }
        if t >= lower && t < end { acceleration = -peak * .pi / leg * sin(2 * .pi * (t - lower) / leg); gyro = 0.5 }
        if t >= 1 + leg && t < lower { gyro = topGyro }
        if noStartHold && t < 1 { gyro = 0.5 }
        if noEndHold && t >= end { gyro = 0.5 }
        return frame(time: t, acceleration: acceleration, gyro: gyro, rotated: rotated)
    }

    private func frame(time: Double, acceleration: Double, gyro: Double = 0,
                       rotated: Bool = false) -> ResampledMotionSample {
        .init(sourceTimestamp: time, sessionTime: time, sensorSide: .right,
              userAcceleration: rotated ? .init(x: -acceleration / 9.80665, y: 0, z: 0) : .init(x: 0, y: 0, z: -acceleration / 9.80665),
              rotationRate: .init(x: 0, y: gyro, z: 0),
              gravity: rotated ? .init(x: -1, y: 0, z: 0) : .init(x: 0, y: 0, z: -1),
              attitude: .init(w: 1, x: 0, y: 0, z: 0), interpolationStatus: .delivered, epoch: 0)
    }
}

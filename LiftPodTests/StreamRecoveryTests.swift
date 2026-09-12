import XCTest
@testable import LiftPod

final class StreamRecoveryTests: XCTestCase {
    func testIncrementalMatchesCleanBatchAndKeepsGlobalGridAcrossGap() throws {
        let raws = (0..<100).map { raw($0) }
        var stream = V2StreamingResampler()
        let actual = try raws.flatMap { try stream.append($0).samples }
        let expected = try V2UniformSourceResampler().resample(raws, profile: .adaptiveCurlV6).samples
        XCTAssertEqual(actual.count, expected.count)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.sourceTimestamp, b.sourceTimestamp, accuracy: 1e-9)
            XCTAssertEqual(a.gravity, b.gravity)
            XCTAssertEqual(a.epoch, b.epoch)
        }
        let gap = try stream.append(raw(105, time: 2.107))
        XCTAssertNotNil(gap.discontinuity)
        XCTAssertTrue(gap.samples.isEmpty)
        let next = try stream.append(raw(106, time: 2.127))
        XCTAssertEqual(next.samples.first?.sourceTimestamp ?? 0, 2.12, accuracy: 1e-9)
        XCTAssertEqual(next.samples.first?.sessionTime ?? 0, 2.12, accuracy: 1e-9)
        XCTAssertEqual(next.samples.first?.epoch, 1)
    }

    func testSixtyMillisecondBoundaryDuplicatesAndQuaternionSign() throws {
        var stream = V2StreamingResampler()
        _ = try stream.append(raw(0))
        let bracket = try stream.append(raw(3, quaternion: .init(w: -1, x: 0, y: 0, z: 0)))
        XCTAssertNil(bracket.discontinuity); XCTAssertEqual(bracket.samples.count, 3)
        XCTAssertTrue(try stream.append(raw(3)).samples.isEmpty)
        XCTAssertNotNil(try stream.append(raw(7)).discontinuity)
        XCTAssertThrowsError(try stream.append(raw(6)))
    }

    func testAttitudeJumpAndInvalidQuaternionAreRecoverableDiscontinuities() throws {
        var stream = V2StreamingResampler()
        _ = try stream.append(raw(0))
        let jump = try stream.append(raw(1, quaternion: .init(w: 0, x: 1, y: 0, z: 0)))
        XCTAssertTrue(jump.discontinuity?.reason.contains("Attitude") == true)
        let invalid = try stream.append(raw(2, quaternion: .init(w: 0, x: 0, y: 0, z: 0)))
        XCTAssertTrue(invalid.samples.isEmpty)
        XCTAssertNotNil(invalid.discontinuity)
        XCTAssertFalse(try stream.append(raw(3)).samples.isEmpty)
    }

    func testSourceGapPreservesCountAndNextCompleteCurlCounts() async throws {
        let engine = try await engine()
        for index in 0...330 { await engine.ingest(raw(index, curlStart: 3.5)) }
        var snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.committedCount, 1)
        let reference = snapshot.reference
        await engine.ingest(raw(334)) // 80 ms missing bracket, not a failed set.
        snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.setState, .active)
        XCTAssertEqual(snapshot.isRecovering, true)
        XCTAssertEqual(snapshot.committedCount, 1)
        XCTAssertTrue(snapshot.qualityDetail?.contains("80 ms") == true)
        for index in 335...346 { await engine.ingest(raw(index)) }
        snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.isRecovering, true)
        for index in 347...530 { await engine.ingest(raw(index, curlStart: 7.5)) }
        snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.setState, .active)
        XCTAssertEqual(snapshot.isRecovering, false)
        XCTAssertEqual(snapshot.committedCount, 2)
        XCTAssertEqual(snapshot.reference, reference)
        XCTAssertEqual(Set(snapshot.recentEvents.map(\.id)).count, 2)
    }

    func testGapDuringMovementCannotStitchARepAndFinalizationCannotAdmitOne() async throws {
        let engine = try await engine()
        for index in 0...212 { await engine.ingest(raw(index, curlStart: 3.5)) }
        for index in 222...345 { await engine.ingest(raw(index, curlStart: 3.5)) }
        var snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.setState, .active)
        XCTAssertEqual(snapshot.committedCount, 0)
        try await engine.requestEnd(at: 6.9)
        for index in 346...375 { await engine.ingest(raw(index, curlStart: 6.92)) }
        snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.setState, .complete)
        XCTAssertEqual(snapshot.committedCount, 0)
    }

    func testReceiptPauseWithContinuousSourceTimesRecoversWithoutEndingSet() async throws {
        let engine = try await engine()
        for index in 0...160 { await engine.ingest(raw(index)) }
        await engine.ingest(raw(161, receiptOffset: 0.4))
        var snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.setState, .active)
        XCTAssertEqual(snapshot.quality, .stale)
        for index in 162...180 { await engine.ingest(raw(index, receiptOffset: 0.4)) }
        snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.quality, .usable)
        XCTAssertEqual(snapshot.isRecovering, false)
        XCTAssertEqual(snapshot.committedCount, 0)
    }

    func testClockResetStillInterruptsWithSpecificReason() async throws {
        let engine = try await engine()
        for index in 0...160 { await engine.ingest(raw(index)) }
        await engine.ingest(raw(0))
        let snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.setState, .interrupted)
        XCTAssertTrue(snapshot.qualityDetail?.contains("backwardSourceClock") == true)
    }

    func testRepeatedGapsRestartContinuousRecoveryDwell() async throws {
        let engine = try await engine()
        for index in 0...160 { await engine.ingest(raw(index)) }
        await engine.ingest(raw(164))
        await engine.ingest(raw(165))
        await engine.ingest(raw(170))
        for index in 171...182 { await engine.ingest(raw(index)) }
        let waiting = await engine.snapshot
        XCTAssertEqual(waiting.isRecovering, true)
        await engine.ingest(raw(183))
        let recovered = await engine.snapshot
        XCTAssertEqual(recovered.isRecovering, false)
        XCTAssertEqual(recovered.committedCount, 0)
    }

    func testFiveMinuteIncrementalStreamHasNoDroppedUniformFrames() throws {
        var stream = V2StreamingResampler()
        var durations: [Double] = []
        var count = 0
        for index in 0..<15_000 {
            let input = raw(index)
            let start = ProcessInfo.processInfo.systemUptime
            let step = try stream.append(input)
            durations.append(ProcessInfo.processInfo.systemUptime - start)
            count += step.samples.count
            XCTAssertNil(step.discontinuity)
        }
        XCTAssertEqual(count, 15_000)
        let p95 = durations.sorted()[14_249]
        print("Five-minute synthetic streaming resampler p95: \(p95 * 1000) ms (simulator, not a phone benchmark)")
        XCTAssertLessThan(p95, 0.01)
    }

    func testRecoveredSetReplayRetainsBothReps() async throws {
        let recorder = V2SessionRecorder(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let engine = V2SetEngine()
        try await engine.start(profile: .adaptiveCurlV6, recorder: recorder, motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true)
        for index in 0...330 { await engine.ingest(raw(index, curlStart: 3.5)) }
        for index in 334...530 { await engine.ingest(raw(index, curlStart: 7.5)) }
        try await engine.requestEnd(at: 10.6)
        for index in 531...555 { await engine.ingest(raw(index)) }
        let bundle = await engine.completedBundle
        let archive = try V2ReplayArchive.load(from: XCTUnwrap(bundle).directory)
        XCTAssertEqual(archive.manifest.committedRepCount, 2)
        let replay = V2ReplayVerifier().verify(archive)
        XCTAssertTrue(replay.passed, "\(replay)")
        var manifest = archive.manifest; manifest.streamVersion = "unsupported"
        XCTAssertEqual(V2ReplayVerifier().verify(.init(manifest: manifest, profile: archive.profile,
                                                       transactions: archive.transactions)).field, "streamVersion")
    }

    @MainActor
    func testCaptureForwardsEverySampleInOrderWithoutUIViewUpdates() async {
        let provider = MockMotionProvider()
        // Use one capture provider and deliberately suspend the observer between samples.
        let capture = CaptureModel(provider: provider, recorder: MockRecorder())
        var received: [UInt64] = []
        capture.analysisEventConsumer = { event in
            if case .sample(let sample) = event {
                await Task.yield()
                received.append(sample.index)
            }
        }
        capture.startMotion()
        for index in 1...100 { provider.emit(.sample(raw(index))) }
        let complete = await eventually { received.count == 100 }
        XCTAssertTrue(complete)
        XCTAssertEqual(received, Array(1...100).map(UInt64.init))
        await capture.stopMotion()
    }

    @MainActor
    func testLabDefaultsToAdaptiveV6() {
        let model = ExperimentalV2Model()
        XCTAssertEqual(model.selectedAlgorithm, .adaptiveAxis)
        XCTAssertEqual(model.profile?.contentHash, V2DSPProfile.adaptiveCurlV6.contentHash)
    }

    private func engine() async throws -> V2SetEngine {
        let engine = V2SetEngine()
        try await engine.start(profile: .adaptiveCurlV6, recorder: V2TestRecorder(), motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true)
        return engine
    }

    private func raw(_ index: Int, time: Double? = nil, receiptOffset: Double = 0,
                     curlStart: Double? = nil,
                     quaternion: ExperimentalQuaternion = .init(w: 1, x: 0, y: 0, z: 0)) -> RawMotionSample {
        let time = time ?? Double(index) / 50
        let phase = curlStart.map { max(0, min(1, (time - $0) / 2)) } ?? 0
        let angle = 2.2 * sin(.pi * phase)
        let rate = phase > 0 && phase < 1 ? 2.2 * .pi / 2 * cos(.pi * phase) : 0
        return .init(index: UInt64(index), sourceTimestamp: time, receiptUptime: time + 100 + receiptOffset,
                     sensorLocation: .rightHeadphone, userAccelerationX: 0, userAccelerationY: 0, userAccelerationZ: 0,
                     gravityX: -sin(angle), gravityY: 0, gravityZ: cos(angle),
                     rotationRateX: 0, rotationRateY: rate, rotationRateZ: 0,
                     quaternionW: quaternion.w, quaternionX: quaternion.x, quaternionY: quaternion.y, quaternionZ: quaternion.z,
                     roll: 0, pitch: 0, yaw: 0)
    }
}

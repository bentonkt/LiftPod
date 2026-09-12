import XCTest
@testable import LiftPod

final class ContinuousRecordingTests: XCTestCase {
    func testDevicePathRecordingReplaysAndRejectsConfigurationTampering() async throws {
        let archive = try await record(metrics: .devicePath3D)
        XCTAssertEqual(archive.manifest.schemaVersion, 7)
        XCTAssertTrue(V2ReplayVerifier().verify(archive).passed)
        let reps = try XCTUnwrap(archive.transactions.last?.output.metrics?.reps)
        XCTAssertFalse(reps.isEmpty)
        XCTAssertTrue(reps.allSatisfy { $0.measurementKind == "device-path-3d" && $0.status != .pending })
        var manifest = archive.manifest
        manifest.metricsConfiguration?.devicePath?.maximumVelocityNormStandardDeviation = 0.19
        XCTAssertFalse(V2ReplayVerifier().verify(.init(manifest: manifest, profile: archive.profile,
                                                      transactions: archive.transactions)).passed)
    }
    func testSchemaSevenRecordsPerFrameOrderAndReplays() async throws {
        let archive = try await record()
        XCTAssertEqual(archive.manifest.schemaVersion, 7)
        XCTAssertEqual(archive.manifest.processingOrderVersion, V2RecordingFormat.continuousOrder)
        XCTAssertGreaterThan(archive.manifest.committedRepCount, 0)
        XCTAssertTrue(archive.transactions.allSatisfy { $0.metricsFrames?.count == $0.uniformSamples.count })
        let events = archive.transactions.flatMap { $0.metricsFrames ?? [] }.flatMap(\.committedEvents)
        XCTAssertEqual(Set(events.map(\.id)).count, archive.manifest.committedRepCount)
        XCTAssertFalse(archive.transactions.flatMap { $0.metricsFrames ?? [] }.flatMap(\.boundaryEvidence).isEmpty)
        let replay = V2ReplayVerifier().verify(archive)
        XCTAssertTrue(replay.passed, "\(replay.field ?? "unknown") at \(String(describing: replay.mismatchSequence))")
    }

    func testMissingFrameEvidenceWrongOrderAndUnsupportedVersionFail() async throws {
        let archive = try await record()
        var transactions = archive.transactions
        transactions[0].metricsFrames = nil
        XCTAssertEqual(V2ReplayVerifier().verify(.init(manifest: archive.manifest, profile: archive.profile,
                                                       transactions: transactions)).field, "metricsFrames")
        var manifest = archive.manifest
        manifest.processingOrderVersion = "unsupported"
        XCTAssertFalse(V2ReplayVerifier().verify(.init(manifest: manifest, profile: archive.profile,
                                                      transactions: archive.transactions)).passed)
        manifest = archive.manifest
        manifest.metricsConfiguration?.version = "unsupported"
        XCTAssertFalse(V2ReplayVerifier().verify(.init(manifest: manifest, profile: archive.profile,
                                                      transactions: archive.transactions)).passed)
        XCTAssertFalse(V2ReplayVerifier().verify(.init(manifest: archive.manifest, profile: archive.profile,
                                                      transactions: [])).passed)
    }

    func testCommittedMetricsInputCannotBeRemovedEvenWhenOutputsAreUnchanged() async throws {
        let archive = try await record()
        var transactions = archive.transactions
        let transactionIndex = try XCTUnwrap(transactions.firstIndex {
            $0.metricsFrames?.contains(where: { !$0.committedEvents.isEmpty }) == true
        })
        var frames = try XCTUnwrap(transactions[transactionIndex].metricsFrames)
        let frameIndex = try XCTUnwrap(frames.firstIndex { !$0.committedEvents.isEmpty })
        let old = frames[frameIndex]
        frames[frameIndex] = .init(sourceTimestamp: old.sourceTimestamp,
                                  boundaryEvidence: old.boundaryEvidence, committedEvents: [])
        transactions[transactionIndex].metricsFrames = frames
        XCTAssertFalse(V2ReplayVerifier().verify(.init(manifest: archive.manifest, profile: archive.profile,
                                                      transactions: transactions)).passed)
    }

    func testV7MetricsOnOffPreserveCommittedEventsAndEndSetAdmission() async throws {
        let on = V2SetEngine(), off = V2SetEngine()
        try await on.start(profile: .adaptiveCurlV7, recorder: V2TestRecorder(), motionActive: true,
                           sideVerified: true, noOtherRecording: true, setupConfirmed: true,
                           metricsConfiguration: .continuousV2)
        try await off.start(profile: .adaptiveCurlV7, recorder: V2TestRecorder(), motionActive: true,
                            sideVerified: true, noOtherRecording: true, setupConfirmed: true,
                            metricsConfiguration: nil)
        for index in 0...350 { await on.ingest(raw(index)); await off.ingest(raw(index)) }
        try await on.requestEnd(at: 7); try await off.requestEnd(at: 7)
        for index in 351...390 { await on.ingest(raw(index)); await off.ingest(raw(index)) }
        let a = await on.snapshot, b = await off.snapshot
        XCTAssertEqual(a.setState, .complete); XCTAssertEqual(b.setState, .complete)
        XCTAssertEqual(a.committedCount, b.committedCount)
        XCTAssertGreaterThan(a.committedCount, 0)
        XCTAssertEqual(a.recentEvents.map(\.id), b.recentEvents.map(\.id))
        XCTAssertEqual(a.recentEvents.map(\.completionTimestamp), b.recentEvents.map(\.completionTimestamp))
        XCTAssertTrue(a.recentEvents.filter(\.committed).allSatisfy { $0.completionTimestamp <= 7 })
    }

    private func record(metrics: RepMetricsConfiguration = .continuousV2) async throws -> V2ReplayArchive {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = V2SetEngine(), recorder = V2SessionRecorder(directory: directory)
        try await engine.start(profile: .adaptiveCurlV7, recorder: recorder, motionActive: true,
                               sideVerified: true, noOtherRecording: true, setupConfirmed: true,
                               metricsConfiguration: metrics)
        for index in 0...350 { await engine.ingest(raw(index, validWorldAttitude: metrics.devicePath != nil)) }
        try await engine.requestEnd(at: 7)
        for index in 351...390 { await engine.ingest(raw(index, validWorldAttitude: metrics.devicePath != nil)) }
        let bundle = await engine.completedBundle
        return try V2ReplayArchive.load(from: XCTUnwrap(bundle).directory)
    }

    private func raw(_ index: Int, validWorldAttitude: Bool = false) -> RawMotionSample {
        let t = Double(index) / 50
        let p = max(0, min(1, (t - 3.5) / 2))
        let angle = 2.2 * sin(.pi * p)
        let rate = t > 3.5 && t < 5.5 ? 2.2 * .pi / 2 * cos(.pi * p) : 0
        let g = ExperimentalVector3(x: -sin(angle), y: 0, z: cos(angle))
        var a = 0.0
        if t >= 3.5 && t < 4.5 { a = 0.8 * .pi * sin(2 * .pi * (t - 3.5)) }
        if t >= 4.5 && t < 5.5 { a = -0.8 * .pi * sin(2 * .pi * (t - 4.5)) }
        return experimentalRawSample(index: UInt64(index), time: t, side: .rightHeadphone,
            acceleration: .init(x: g.x * a / 9.80665, y: 0, z: g.z * a / 9.80665),
            gravity: g, rotation: .init(x: 0, y: rate, z: 0),
            attitude: validWorldAttitude ? .init(w: cos((angle + .pi)/2),x: 0,y: sin((angle + .pi)/2),z: 0) : .init(w: 1,x: 0,y: 0,z: 0))
    }
}

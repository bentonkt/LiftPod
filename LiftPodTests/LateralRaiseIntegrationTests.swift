import CryptoKit
import XCTest
import simd

@testable import LiftPod

final class LateralRaiseIntegrationTests: XCTestCase {
    @MainActor
    func testPickerRegistersLateralWithoutChangingCurlOrGenericMode() throws {
        let name = "LateralPicker-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name) }
        let model = ExperimentalV2Model(preferences: prefs)
        XCTAssertEqual(model.profile?.identity.algorithm, .adaptiveAxis)
        model.selectedExercise = .lateralRaise
        XCTAssertEqual(model.profile?.identity.algorithm, .gravityTilt)
        XCTAssertNil(model.unavailableMessage)
        XCTAssertFalse(model.canStart(motionActive: true, sideVerified: true, otherRecordingActive: false))
        model.setupConfirmed = true
        XCTAssertTrue(model.canStart(motionActive: true, sideVerified: true, otherRecordingActive: false))
        XCTAssertTrue(model.devicePathMetricsEnabled)
        model.selectedSide = .left
        XCTAssertNil(model.profile)
        XCTAssertNotNil(model.unavailableMessage)
        model.countingMode = .generic
        XCTAssertNil(model.unavailableMessage)
        model.countingMode = .exercise
        model.selectedSide = .right
        model.selectedExercise = .overheadPress
        XCTAssertNil(model.profile)
    }

    func testProfileIdentityValidationAndLegacyHash() throws {
        let profile = try V2DSPProfile.lateralRaiseV6.validated()
        let decoded = try JSONDecoder().decode(V2DSPProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.contentHash, profile.contentHash)
        XCTAssertEqual(
            V2DSPProfile.adaptiveCurlV6.contentHash,
            "8ef55b2a54b13facada2cc7bc43c29319792f69cfef2432e1bdfb72ac4240c32")
        var identity = profile.identity
        func changed() -> V2DSPProfile {
            .init(
                profileID: profile.profileID, identity: identity, validationStatus: .experimental,
                descriptiveNotes: "Profile validation test")
        }
        identity.gravityTilt?.directionApexFraction = 0.9
        XCTAssertNotEqual(changed().contentHash, profile.contentHash)
        identity.gravityTilt?.directionApexFraction = .nan
        XCTAssertThrowsError(try changed().validated())
        identity = profile.identity
        identity.gravityTilt = nil
        XCTAssertThrowsError(try changed().validated())
    }

    func testCapturedCountsAndPassiveMetricsIsolation() async throws {
        for (name, count) in [
            ("normal_five", 5), ("slow_five", 5), ("fast_continuous_five", 5),
            ("three_quarter_five", 5), ("four_plus_hand_motion", 4),
        ] {
            let samples = try preparedCapture(name)
            let on = try await run(samples, metrics: .cyclicDevicePath3D)
            let off = try await run(samples, metrics: nil)
            let events = on.recentEvents.filter(\.committed)
            XCTAssertEqual(on.committedCount, count, name)
            XCTAssertEqual(Set(events.map(\.id)).count, count, name)
            XCTAssertEqual(on.committedCount, off.committedCount)
            XCTAssertEqual(on.recentEvents.map(\.id), off.recentEvents.map(\.id))
            XCTAssertEqual(on.recentEvents.map(\.committed), off.recentEvents.map(\.committed))
            XCTAssertEqual(on.recentEvents.map(\.completionTimestamp), off.recentEvents.map(\.completionTimestamp))
            let metrics = try XCTUnwrap(on.metrics?.reps)
            XCTAssertEqual(metrics.count, count)
            XCTAssertTrue(metrics.allSatisfy { $0.measurementKind == "cyclic-device-path-3d" })
            print("LATERAL \(name): \(count), speeds \(metrics.map { $0.reason?.rawValue ?? $0.status.rawValue })")
            if name == "four_plus_hand_motion" {
                XCTAssertTrue(on.recentEvents.contains { $0.rejectionReason == .inconsistentDirection })
                let origin = try XCTUnwrap(try capture(name).first).sourceTimestamp
                XCTAssertTrue(events.allSatisfy { $0.topTimestamp < origin + 12 })
            }
        }
    }

    func testMountRotationAndQuaternionSignsPreserveCounts() async throws {
        let samples = try preparedCapture("four_plus_hand_motion")
        let baseline = try await run(samples, metrics: nil)
        for rotation in [
            simd_quatd(angle: 1.3, axis: simd_normalize(SIMD3(1.0, 2.0, -0.5))),
            simd_quatd(angle: -2.1, axis: simd_normalize(SIMD3(-0.3, 1.0, 2.0))),
        ] {
            let result = try await run(samples.map { remount($0, rotation) }, metrics: nil)
            XCTAssertEqual(result.committedCount, 4)
            XCTAssertEqual(result.recentEvents.map(\.id), baseline.recentEvents.map(\.id))
            XCTAssertEqual(result.recentEvents.map(\.committed), baseline.recentEvents.map(\.committed))
            for (a, b) in zip(result.recentEvents, baseline.recentEvents) {
                XCTAssertEqual(a.completionTimestamp, b.completionTimestamp, accuracy: 1e-9)
            }
        }
    }

    func testSmallMovementRecoveryAndFirstLastRep() async throws {
        let full = try await run(synthetic(), metrics: nil)
        XCTAssertEqual(full.committedCount, 2)
        XCTAssertTrue(full.recentEvents.filter(\.committed).allSatisfy { $0.top > 0.8 })
        let single = try await run(synthetic().filter { $0.sourceTimestamp < 6.8 }, metrics: nil)
        XCTAssertEqual(single.committedCount, 1)
    }

    func testEndSetGapAndWrongBudExcludeInvalidCycles() async throws {
        let samples = synthetic()
        let engine = try await started(metrics: nil)
        for sample in samples where sample.sourceTimestamp <= 5 { await engine.ingest(sample) }
        try await engine.requestEnd(at: 5)
        for sample in samples where sample.sourceTimestamp > 5 { await engine.ingest(sample) }
        let ended = await engine.snapshot
        XCTAssertEqual(ended.setState, .complete)
        XCTAssertEqual(ended.committedCount, 0)
        let gapped = try await run(samples.filter { !(4.9...5.2).contains($0.sourceTimestamp) }, metrics: nil)
        XCTAssertEqual(gapped.committedCount, 1)
        XCTAssertTrue(gapped.recentEvents.filter(\.committed).allSatisfy { $0.startTimestamp > 5.2 })
        let wrong = try await started(metrics: nil)
        for sample in samples where sample.sourceTimestamp < 5 { await wrong.ingest(sample) }
        await wrong.ingest(experimentalRawSample(index: 250, time: 5, side: .leftHeadphone))
        for sample in samples where sample.sourceTimestamp > 5 { await wrong.ingest(sample) }
        let failed = await wrong.snapshot
        XCTAssertEqual(failed.setState, .interrupted)
        XCTAssertEqual(failed.committedCount, 0)
    }

    func testCapturedRecordingReplaysWith3DMetrics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = V2SetEngine()
        try await engine.start(
            profile: .lateralRaiseV6, recorder: V2SessionRecorder(directory: directory),
            motionActive: true, sideVerified: true, noOtherRecording: true,
            setupConfirmed: true, metricsConfiguration: .cyclicDevicePath3D)
        let samples = try preparedCapture("normal_five")
        for sample in samples { await engine.ingest(sample) }
        let last = try XCTUnwrap(samples.last)
        try await engine.requestEnd(at: last.sourceTimestamp)
        // Synthetic post-End drain tests lifecycle/replay, not measured speed accuracy.
        for i in 1...40 { await engine.ingest(hold(last, at: last.sourceTimestamp + Double(i) / 50, index: UInt64(i))) }
        let bundle = await engine.completedBundle
        let archive = try V2ReplayArchive.load(from: XCTUnwrap(bundle).directory)
        XCTAssertEqual(archive.manifest.committedRepCount, 5)
        let replay = V2ReplayVerifier().verify(archive)
        XCTAssertTrue(replay.passed, replay.field ?? "unknown replay mismatch")
    }

    func testCaptureManifestHashes() throws {
        struct Manifest: Decodable {
            struct Capture: Decodable {
                let file: String
                let sha256: String
                let bytes: Int
                let observedCount: Int
            }
            let captures: [Capture]
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: dataRoot.appendingPathComponent("lateral_manifest.json")))
        XCTAssertEqual(manifest.captures.count, 5)
        for entry in manifest.captures {
            let data = try Data(contentsOf: dataRoot.appendingPathComponent(entry.file))
            XCTAssertEqual(data.count, entry.bytes)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), entry.sha256)
            XCTAssertTrue([4, 5].contains(entry.observedCount))
        }
    }

    private var dataRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/rep_captures")
    }
    private func capture(_ name: String) throws -> [RawMotionSample] {
        try RawMotionCSVDecoder().decode(
            data: Data(contentsOf: dataRoot.appendingPathComponent("lateral_raise_\(name).csv")))
    }
    private func preparedCapture(_ name: String) throws -> [RawMotionSample] {
        let samples = try capture(name)
        let first = try XCTUnwrap(samples.first)
        // Record-only captures omit preparation: explicit synthetic idle, originals unchanged.
        return (0..<170).map { hold(first, at: first.sourceTimestamp - 3.4 + Double($0) / 50, index: UInt64($0)) }
            + samples
    }
    private func started(metrics: RepMetricsConfiguration?) async throws -> V2SetEngine {
        let engine = V2SetEngine()
        try await engine.start(
            profile: .lateralRaiseV6, recorder: V2TestRecorder(), motionActive: true,
            sideVerified: true, noOtherRecording: true, setupConfirmed: true,
            metricsConfiguration: metrics)
        return engine
    }
    private func run(_ samples: [RawMotionSample], metrics: RepMetricsConfiguration?) async throws
        -> V2ProcessorSnapshot
    {
        let engine = try await started(metrics: metrics)
        for sample in samples { await engine.ingest(sample) }
        return await engine.snapshot
    }
    private func hold(_ sample: RawMotionSample, at time: Double, index: UInt64) -> RawMotionSample {
        experimentalRawSample(
            index: index, time: time,
            gravity: .init(x: sample.gravityX, y: sample.gravityY, z: sample.gravityZ),
            attitude: .init(w: sample.quaternionW, x: sample.quaternionX, y: sample.quaternionY, z: sample.quaternionZ),
            receiptTime: sample.receiptUptime + time - sample.sourceTimestamp)
    }
    private func remount(_ sample: RawMotionSample, _ rotation: simd_quatd) -> RawMotionSample {
        func vector(_ x: Double, _ y: Double, _ z: Double) -> ExperimentalVector3 {
            let v = rotation.act(SIMD3(x, y, z))
            return .init(x: v.x, y: v.y, z: v.z)
        }
        let original = simd_quatd(
            ix: sample.quaternionX, iy: sample.quaternionY, iz: sample.quaternionZ, r: sample.quaternionW)
        let q = original * rotation.inverse
        let sign = sample.index.isMultiple(of: 2) ? -1.0 : 1.0
        return experimentalRawSample(
            index: sample.index, time: sample.sourceTimestamp,
            acceleration: vector(sample.userAccelerationX, sample.userAccelerationY, sample.userAccelerationZ),
            gravity: vector(sample.gravityX, sample.gravityY, sample.gravityZ),
            rotation: vector(sample.rotationRateX, sample.rotationRateY, sample.rotationRateZ),
            attitude: .init(w: sign * q.real, x: sign * q.imag.x, y: sign * q.imag.y, z: sign * q.imag.z),
            receiptTime: sample.receiptUptime)
    }
    private func synthetic() -> [RawMotionSample] {
        (0...450).map { index in
            let time = Double(index) / 50
            var angle = 0.0
            var rate = 0.0
            for (start, duration, excursion) in [(3.6, 0.7, 0.24), (4.3, 1.8, 1.1), (6.9, 1.6, 1.15)] {
                if time > start && time < start + duration {
                    let phase = (time - start) / duration
                    angle = excursion * pow(sin(.pi * phase), 2)
                    rate = excursion * .pi / duration * sin(2 * .pi * phase)
                }
            }
            return experimentalRawSample(
                index: UInt64(index), time: time,
                gravity: .init(x: sin(angle), y: 0, z: -cos(angle)),
                rotation: .init(x: 0, y: rate, z: 0),
                attitude: .init(w: cos(angle / 2), x: 0, y: sin(angle / 2), z: 0))
        }
    }
}

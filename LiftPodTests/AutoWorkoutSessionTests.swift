import Foundation
import XCTest
@testable import LiftPod

final class AutoWorkoutSessionTests: XCTestCase {
    func testFinishedWorkoutRoundTripsAndExportsCompleteBundle() async throws {
        let root = scratch("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = AutoWorkoutConfiguration()
        configuration.metricsEnabled = false
        let session = AutoWorkoutSession()
        try await session.start(configuration: configuration, root: root)
        try await feedGenericMotion(to: session, indices: 0...650)
        let beforeFinish = await session.snapshot
        XCTAssertGreaterThanOrEqual(beforeFinish.sets.first?.count ?? 0, 3)
        try await session.apply(.init(kind: .finish, timestamp: try XCTUnwrap(beforeFinish.timestamp)))

        let finishedDirectory = await session.directory
        let directory = try XCTUnwrap(finishedDirectory)
        let exports = await session.exportURLs
        XCTAssertEqual(exports.count, 5)
        XCTAssertTrue(exports.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let finished = await session.snapshot
        XCTAssertEqual(finished.state, .finished)
        XCTAssertTrue(try AutoWorkoutReplay.verify(directory: directory))
    }

    func testReplayRejectsTamperedRawCSV() async throws {
        let root = scratch("raw-tamper")
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = AutoWorkoutConfiguration()
        configuration.metricsEnabled = false
        let session = AutoWorkoutSession()
        try await session.start(configuration: configuration, root: root)
        try await feedGenericMotion(to: session, indices: 0...180)
        let active = await session.snapshot
        let timestamp = try XCTUnwrap(active.timestamp)
        try await session.apply(.init(kind: .finish, timestamp: timestamp))
        let finishedDirectory = await session.directory
        let directory = try XCTUnwrap(finishedDirectory)
        XCTAssertTrue(try AutoWorkoutReplay.verify(directory: directory))

        let rawURL = directory.appendingPathComponent("raw-motion.csv")
        let handle = try FileHandle(forWritingTo: rawURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered\n".utf8))
        try handle.close()
        XCTAssertFalse(try AutoWorkoutReplay.verify(directory: directory))
    }

    func testPartialJournalTailRecoversVerifiedPrefixAndRequiresExplicitResume() async throws {
        let originalRoot = scratch("interrupted")
        let recoveryRoot = scratch("recovered")
        defer {
            try? FileManager.default.removeItem(at: originalRoot)
            try? FileManager.default.removeItem(at: recoveryRoot)
        }
        var configuration = AutoWorkoutConfiguration()
        configuration.metricsEnabled = false
        let interrupted = AutoWorkoutSession()
        try await interrupted.start(configuration: configuration, root: originalRoot)
        try await feedGenericMotion(to: interrupted, indices: 0...220)
        let active = await interrupted.snapshot
        let pausedAt = try XCTUnwrap(active.timestamp)
        try await interrupted.apply(.init(kind: .pause, timestamp: pausedAt))
        let originalDirectory = await interrupted.directory
        let original = try XCTUnwrap(originalDirectory)
        let journal = original.appendingPathComponent("processor-transactions.jsonl")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"sequence":999,"input":"#.utf8))
        try handle.close()

        let recovered = AutoWorkoutSession()
        try await recovered.recover(from: original, root: recoveryRoot)
        let suspended = await recovered.snapshot
        XCTAssertEqual(suspended.state, .suspended)
        let resumeAt = (suspended.timestamp ?? pausedAt) + 0.1
        try await recovered.apply(.init(kind: .resume, timestamp: resumeAt))
        let resumed = await recovered.snapshot
        XCTAssertEqual(resumed.state, .running)
        try await recovered.apply(.init(kind: .finish, timestamp: resumeAt))
        let finishedDirectory = await recovered.directory
        let recoveredDirectory = try XCTUnwrap(finishedDirectory)
        XCTAssertTrue(try AutoWorkoutReplay.verify(directory: recoveredDirectory))
    }

    func testRecoveryRejectsConfigurationThatDoesNotMatchJournalAnchor() async throws {
        let originalRoot = scratch("configuration-anchor")
        let recoveryRoot = scratch("configuration-anchor-recovery")
        defer {
            try? FileManager.default.removeItem(at: originalRoot)
            try? FileManager.default.removeItem(at: recoveryRoot)
        }
        var configuration = AutoWorkoutConfiguration()
        configuration.metricsEnabled = false
        let original = AutoWorkoutSession()
        try await original.start(configuration: configuration, root: originalRoot)
        try await original.apply(.init(kind: .sample, raw: RawMotionEvent(raw(0))))
        try await original.apply(.init(kind: .pause, timestamp: 0))
        let originalDirectory = await original.directory
        let savedDirectory = try XCTUnwrap(originalDirectory)

        var changed = configuration
        changed.metricsEnabled = true
        try GenericHash.data(changed).write(
            to: savedDirectory.appendingPathComponent("auto-configuration.json"), options: .atomic
        )
        let recovered = AutoWorkoutSession()
        await XCTAssertThrowsErrorAsync {
            try await recovered.recover(from: savedDirectory, root: recoveryRoot)
        }
    }

    func testUICommandsAcquireAndJournalCurrentActorTimestamp() async throws {
        let root = scratch("command-clock")
        defer { try? FileManager.default.removeItem(at:root) }
        let session = AutoWorkoutSession()
        try await session.start(configuration:.init(),root:root)
        try await session.apply(.init(kind:.sample,raw:RawMotionEvent(raw(20))))
        let before = await session.snapshot
        try await session.apply(.init(kind:.pause))
        let paused = await session.snapshot
        XCTAssertEqual(paused.timestamp,before.timestamp)
        XCTAssertEqual(paused.state,.paused)
        try await session.apply(.init(kind:.resume))
        try await session.apply(.init(kind:.finish))
        let directory = await session.directory
        XCTAssertTrue(try AutoWorkoutReplay.verify(directory:try XCTUnwrap(directory)))
    }

    func testPauseResumeAndFinishCompleteWithoutAdditionalSamples() async throws {
        let root = scratch("pause-finish")
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = AutoWorkoutConfiguration()
        configuration.metricsEnabled = false
        let session = AutoWorkoutSession()
        try await session.start(configuration: configuration, root: root)
        try await session.apply(.init(kind: .sample, raw: RawMotionEvent(raw(0))))
        let connected = await session.snapshot
        let sampleTime = try XCTUnwrap(connected.timestamp)
        try await session.apply(.init(kind: .pause, timestamp: sampleTime))
        let paused = await session.snapshot
        XCTAssertEqual(paused.state, .paused)
        try await session.apply(.init(kind: .resume, timestamp: sampleTime + 0.1))
        let resumed = await session.snapshot
        XCTAssertEqual(resumed.state, .running)
        try await session.apply(.init(kind: .finish, timestamp: sampleTime + 0.1))
        let finished = await session.snapshot
        let finishedDirectory = await session.directory
        XCTAssertEqual(finished.state, .finished)
        XCTAssertTrue(try AutoWorkoutReplay.verify(directory: try XCTUnwrap(finishedDirectory)))
    }

    private func feedGenericMotion(to session: AutoWorkoutSession, indices: ClosedRange<Int>) async throws {
        for index in indices {
            try await session.apply(.init(kind: .sample, raw: RawMotionEvent(raw(index))))
        }
    }

    private func raw(_ index: Int) -> RawMotionSample {
        let time = Double(index) / 50
        let phase = Double.pi * time
        return experimentalRawSample(
            index: UInt64(index), time: time, side: .rightHeadphone,
            acceleration: .init(x: 0.35 * cos(phase), y: 0.105 * sin(phase), z: 0),
            gravity: .init(x: 0, y: 0, z: -1)
        )
    }

    private func scratch(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("auto-session-\(label)-\(UUID().uuidString)")
    }
}

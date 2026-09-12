import XCTest
import simd
@testable import LiftPod

final class AutoPatternEngineTests: XCTestCase {
    private let workoutID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!

    private func configuration() -> AutoWorkoutConfiguration {
        var value = AutoWorkoutConfiguration()
        value.workoutID = workoutID
        value.metricsEnabled = false
        return value
    }

    private func sample(_ index: Int, offset: Double = 0, epoch: Int = 0,
                        moving: Bool = true) -> ResampledMotionSample {
        let t = offset + Double(index) / 50
        let phase = Double.pi * (t - offset)
        return .init(sourceTimestamp: t, sessionTime: t, sensorSide: .right,
            userAcceleration: moving ? .init(x: 0.35 * cos(phase), y: 0.105 * sin(phase), z: 0) : .init(x: 0, y: 0, z: 0),
            rotationRate: .init(x: 0, y: 0, z: 0), gravity: .init(x: 0, y: 0, z: -1),
            attitude: .init(w: 1, x: 0, y: 0, z: 0),
            interpolationStatus: .delivered, epoch: epoch)
    }

    func testTemplateFreezeBackfillsOnlyOwnedChronologicalCycles() {
        var engine = AutoPatternEngine(configuration: configuration())
        var cycles: [AutoCycleEvidence] = []
        var templates: [GenericPattern] = []
        for i in 0...510 {
            let batch = engine.observe(sample(i))
            cycles += batch.cycles
            templates += batch.templates
        }
        XCTAssertEqual(templates.count, 1)
        XCTAssertGreaterThanOrEqual(cycles.count, 4)
        XCTAssertEqual(Set(cycles.map(\.id)).count, cycles.count)
        XCTAssertEqual(cycles.map(\.start), cycles.map(\.start).sorted())
        for pair in zip(cycles, cycles.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.start, pair.0.completion - 0.021)
        }
        XCTAssertTrue(cycles.allSatisfy { $0.id.hasPrefix(workoutID.uuidString) })
    }

    func testRecordedRDLAndCurlRecoveriesArePreserved() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var rdlEngine = AutoPatternEngine(configuration: configuration())
        var resampler = V2StreamingResampler()
        var rdlCycles: [AutoCycleEvidence] = []
        try GenericFrameHistory.lines(fixtureRoot.appendingPathComponent("Fixtures/rdl-six-patterns/processor-transactions.jsonl")) { data in
            let transaction = try JSONDecoder().decode(GenericSessionTransaction.self, from: data)
            guard transaction.input.kind == .sample, let raw = transaction.input.raw?.sample else { return }
            for uniform in try resampler.append(raw).samples { rdlCycles += rdlEngine.observe(uniform).cycles }
        }
        XCTAssertEqual(rdlCycles.count, 6)

        let curl = try ContinuousCaptureFixture.load(name: "latest-continuous-eight-curl")
        var curlEngine = AutoPatternEngine(configuration: configuration())
        var curlCycles: [AutoCycleEvidence] = []
        for uniform in curl.uniform { curlCycles += curlEngine.observe(uniform).cycles }
        XCTAssertEqual(curlCycles.count, curl.expected.committedRepCount)
    }

    func testHardBoundaryPreventsBackfillAcrossCutoff() {
        var engine = AutoPatternEngine(configuration: configuration())
        for i in 0...185 { _ = engine.observe(sample(i)) } // fewer than three complete cycles
        engine.boundary(at: 3.7)
        var cycles: [AutoCycleEvidence] = []
        for i in 186...650 { cycles += engine.observe(sample(i)).cycles }
        XCTAssertFalse(cycles.isEmpty)
        XCTAssertTrue(cycles.allSatisfy { $0.start >= 3.7 - 1e-9 })
        XCTAssertGreaterThanOrEqual(engine.resolvedThrough, 3.7)
    }

    func testQuietGraceCreatesNewOwnershipWithoutRepeatedBoundaries() {
        var engine = AutoPatternEngine(configuration: configuration())
        var before: [AutoCycleEvidence] = []
        for i in 0...500 { before += engine.observe(sample(i)).cycles }
        XCTAssertFalse(before.isEmpty)
        let quietStart = 10.02
        var last: AutoEvidenceBatch?
        for i in 0...550 { last = engine.observe(sample(i, offset: quietStart, moving: false)) }
        let frontier = engine.resolvedThrough
        XCTAssertGreaterThanOrEqual(frontier, quietStart + 10)
        XCTAssertEqual(last?.activity, .quiet)

        var after: [AutoCycleEvidence] = []
        let restart = quietStart + 11.02
        for i in 0...450 { after += engine.observe(sample(i, offset: restart)).cycles }
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { $0.start >= frontier - 1e-9 })
        XCTAssertTrue(Set(before.map(\.id)).isDisjoint(with: Set(after.map(\.id))))
    }

    func testDiscontinuityResetsPreparedStateAndAdvancesLogicalEpoch() {
        var engine = AutoPatternEngine(configuration: configuration())
        let first = engine.observe(sample(0, epoch: 0))
        XCTAssertEqual(first.sourceEpoch, 0)
        XCTAssertNotNil(engine.latestPreparedFrame)
        engine.discontinuity(at: 1)
        XCTAssertNil(engine.latestPreparedFrame)
        let next = engine.observe(sample(51, epoch: 0))
        XCTAssertEqual(next.sourceEpoch, 1)
        XCTAssertTrue(next.discontinuity)
    }

    func testHoldingAndUnmatchedFramesCannotFabricateProgress() throws {
        var pipeline = GenericFeaturePipeline()
        let frames = (0...100).compactMap { pipeline.observe(sample($0)) }
        let pattern = try XCTUnwrap(GenericPatternMath.pattern(frames, config: .init(), epoch: 0,
            frozenAt: 2, learnedFrom: [0, 2]))
        var tracker = GenericPatternTracker(pattern: pattern, config: .init())
        for frame in frames.prefix(35) { _ = tracker.observe(frame, departureAllowed: true) }
        let supported = try XCTUnwrap(tracker.progress)
        for i in 0...40 {
            let quietSample = sample(i, offset: 0.7, moving: false)
            let quietFrame = GenericMotionFrame(sample: quietSample, features: frames[34].features)
            _ = tracker.observe(quietFrame, departureAllowed: true)
        }
        XCTAssertEqual(tracker.progress, supported)

        for i in 0...20 {
            let t = 2 + Double(i) / 50
            let bad = ResampledMotionSample(sourceTimestamp: t, sessionTime: t, sensorSide: .right,
                userAcceleration: .init(x: 4, y: 4, z: 4), rotationRate: .init(x: 0, y: 0, z: 0),
                gravity: .init(x: 0, y: 0, z: -1), attitude: .init(w: 1, x: 0, y: 0, z: 0),
                interpolationStatus: .delivered, epoch: 0)
            _ = tracker.observe(.init(sample: bad, features: Array(repeating: 100, count: 9)), departureAllowed: true)
        }
        XCTAssertNil(tracker.progress)
    }
}

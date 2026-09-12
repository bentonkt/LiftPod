import XCTest
import simd
@testable import LiftPod

final class AutoWorkoutPresentationTests: XCTestCase {
    func testUnknownMovementNeverShowsInventedQualificationProgress() {
        var snapshot = AutoWorkoutSnapshot()
        snapshot.state = .running
        snapshot.status = "Finding movement"
        snapshot.candidateCount = 1
        XCTAssertEqual(AutoWorkoutPresentation.status(snapshot), "Finding movement")
        XCTAssertFalse(AutoWorkoutPresentation.status(snapshot).contains("/3"))
    }

    func testLifecycleOverridesStatusWhenCoverageIsUnavailableOrPaused() {
        var snapshot = AutoWorkoutSnapshot()
        snapshot.status = "Rest"
        snapshot.state = .suspended
        XCTAssertEqual(AutoWorkoutPresentation.status(snapshot), "Tracking unavailable")
        snapshot.state = .paused
        XCTAssertEqual(AutoWorkoutPresentation.status(snapshot), "Paused")
    }

    func testSuspendedAndRecoveredWorkoutsOfferResume() {
        XCTAssertEqual(AutoWorkoutPresentation.trackingControlTitle(.suspended), "Resume Tracking")
        XCTAssertTrue(AutoWorkoutPresentation.canControlTracking(.suspended))
        XCTAssertEqual(AutoWorkoutPresentation.trackingControlTitle(.paused), "Resume Tracking")
        XCTAssertTrue(AutoWorkoutPresentation.canControlTracking(.paused))
        XCTAssertEqual(AutoWorkoutPresentation.trackingControlTitle(.running), "Pause Tracking")
        XCTAssertFalse(AutoWorkoutPresentation.canControlTracking(.connecting))
        XCTAssertFalse(AutoWorkoutPresentation.canControlTracking(.finished))
    }

    func testTimelineLabelsPreserveUncertainty() {
        XCTAssertEqual(AutoWorkoutPresentation.intervalName(.recovery), "Recovery · estimated")
        XCTAssertEqual(AutoWorkoutPresentation.intervalName(.unclassified), "Movement unclear")
        XCTAssertEqual(AutoWorkoutPresentation.intervalName(.unavailable), "Tracking unavailable")
    }

    @MainActor
    func testModelPublishesCoordinatorSnapshotExportsAndErrors() {
        let model = AutoWorkoutModel()
        var snapshot = AutoWorkoutSnapshot()
        snapshot.state = .running
        snapshot.status = "Set 1 · 3 reps"
        model.apply(snapshot: snapshot)
        model.setExports([URL(fileURLWithPath: "/tmp/workout.json")])
        model.report(error: "Export failed")
        XCTAssertEqual(model.snapshot, snapshot)
        XCTAssertEqual(model.exportURLs.count, 1)
        XCTAssertEqual(model.error, "Export failed")
    }

    func testMetricsPublishPendingThenCreatePerSetBaseline() throws {
        var metrics = AutoWorkoutMetrics(configuration: .init())
        let cycles = (0..<3).map { cycle($0, template: "same") }
        let set = AutoSetRecord(id: "set-1", cycleIDs: cycles.map(\.id),
                                start: cycles[0].start, end: cycles[2].completion)
        for i in 0...500 { metrics.observe(frame(Double(i) / 50)) }
        let pending = metrics.update(cycles: cycles, sets: [set], at: cycles[2].completion)
        XCTAssertEqual(pending.last?.status, .pending)
        let resolved = metrics.update(cycles: cycles, sets: [set], at: 9.70)
        XCTAssertEqual(resolved.count, 3)
        XCTAssertTrue(resolved.allSatisfy { $0.status == .available }, "\(resolved.map(\.reason))")
        XCTAssertNotNil(metrics.baselines[set.id])
    }

    func testIncompatibleMergeHasNoCommonBaseline() {
        var metrics = AutoWorkoutMetrics(configuration: .init())
        let compatible = (0..<3).map { cycle($0, template: "same") }
        let incompatible = cycle(3, template: "other")
        for i in 0...650 { metrics.observe(frame(Double(i) / 50)) }
        let original = AutoSetRecord(id: "set-1", cycleIDs: compatible.map(\.id), start: 1, end: 9)
        _ = metrics.update(cycles: compatible + [incompatible], sets: [original], at: 13, force: true)
        XCTAssertNotNil(metrics.baselines[original.id])
        let merged = AutoSetRecord(id: original.id, cycleIDs: (compatible + [incompatible]).map(\.id),
                                   start: 1, end: incompatible.completion)
        _ = metrics.update(cycles: compatible + [incompatible], sets: [merged], at: 13, force: true)
        XCTAssertNil(metrics.baselines[merged.id])
    }

    func testBaselineTracksSplitDiscardAndCountCorrections() {
        var metrics = AutoWorkoutMetrics(configuration: .init())
        let cycles = (0..<3).map { cycle($0, template: "same") }
        for i in 0...500 { metrics.observe(frame(Double(i) / 50)) }
        var original = AutoSetRecord(id: "set-1", cycleIDs: cycles.map(\.id), start: 1, end: 9)
        _ = metrics.update(cycles: cycles, sets: [original], at: 10, force: true)
        let baseline = metrics.baselines[original.id]
        XCTAssertNotNil(baseline)

        original.correctedCount = 12
        _ = metrics.update(cycles: cycles, sets: [original], at: 10, force: true)
        XCTAssertEqual(metrics.baselines[original.id], baseline)

        let leading = AutoSetRecord(id: original.id, cycleIDs: Array(cycles.prefix(2)).map(\.id),
                                    start: cycles[0].start, end: cycles[1].completion)
        let trailing = AutoSetRecord(id: "set-2", cycleIDs: [cycles[2].id],
                                     start: cycles[2].start, end: cycles[2].completion)
        _ = metrics.update(cycles: cycles, sets: [leading, trailing], at: 10, force: true)
        XCTAssertNil(metrics.baselines[leading.id])
        XCTAssertNil(metrics.baselines[trailing.id])

        original.status = .discarded
        _ = metrics.update(cycles: cycles, sets: [original], at: 10, force: true)
        XCTAssertNil(metrics.baselines[original.id])
    }

    private func cycle(_ index: Int, template: String) -> AutoCycleEvidence {
        let start = 1.0 + Double(index) * 3.0
        return .init(id: "cycle-\(index)", sourceEpoch: 0, learningEpoch: 0,
                     templateHash: template, start: start, completion: start + 2,
                     detected: start + 2.1, authorized: start + 2.2, matchCost: 0.1)
    }

    private func frame(_ time: Double) -> GenericMotionFrame {
        let phase = (time - 1).truncatingRemainder(dividingBy: 3)
        let active = time >= 1 && phase >= 0 && phase < 2
        let acceleration = active ? SIMD3<Double>(0.3, 0, 0.8) * (.pi * cos(.pi * phase)) : .zero
        let sample = ResampledMotionSample(
            sourceTimestamp: time, sessionTime: time, sensorSide: .right,
            userAcceleration: DevicePathMath.record(acceleration / -9.80665),
            rotationRate: .init(x: 0, y: active ? 0.6 : 0, z: 0),
            gravity: .init(x: 0, y: 0, z: -1), attitude: .init(w: 1, x: 0, y: 0, z: 0),
            interpolationStatus: .delivered, epoch: 0
        )
        return .init(sample: sample,
                     features: [acceleration.x / -9.80665, acceleration.y / -9.80665,
                                acceleration.z / -9.80665, 0, active ? 0.6 : 0, 0, 0, 0, -1])
    }
}

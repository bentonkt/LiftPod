import Foundation

/// A passive consumer of accepted automatic cycles. Metric availability never
/// feeds back into cycle authorization or set membership.
struct AutoWorkoutMetrics: Sendable {
    let configuration: AutoWorkoutConfiguration
    private var frames: [GenericMotionFrame] = []
    private var results: [String: GenericCycleMetrics] = [:]
    private var resultOrder: [String] = []
    private(set) var baselines: [String: Double] = [:]

    init(configuration: AutoWorkoutConfiguration) {
        self.configuration = configuration
    }

    mutating func observe(_ frame: GenericMotionFrame) {
        guard frame.time.isFinite else { return }
        frames.append(frame)
        let cutoff = frame.time - configuration.contextDuration
        if let first = frames.firstIndex(where: { $0.time >= cutoff }) {
            if first > 0 { frames.removeFirst(first) }
        } else if frames.count > 1 {
            frames = Array(frames.suffix(1))
        }
    }

    mutating func update(
        cycles: [AutoCycleEvidence],
        sets: [AutoSetRecord],
        at time: Double,
        force: Bool = false
    ) -> [GenericCycleMetrics] {
        guard configuration.metricsEnabled else { return [] }
        let acceptedIDs = Set(sets.flatMap(\.cycleIDs))
        for cycle in cycles where acceptedIDs.contains(cycle.id) {
            if results[cycle.id] == nil {
                results[cycle.id] = .init(id: cycle.id, learningEpoch: cycle.learningEpoch)
                resultOrder.append(cycle.id)
            }
            guard results[cycle.id]?.status == .pending else { continue }
            guard force || time >= cycle.completion + 0.60 - 1e-9 else { continue }
            let event = makeEvent(cycle, cycles: cycles, sets: sets)
            var estimator = DevicePathMetrics(configuration: .cyclicDevicePath3D)
            for frame in frames where frame.time >= cycle.start - 0.50 &&
                frame.time <= min(time, cycle.completion + 0.60) &&
                frame.sample.epoch == cycle.sourceEpoch {
                estimator.observePreparedGeneric(frame)
            }
            results[cycle.id] = estimator.estimateGeneric(event, at: time)
        }
        resolveBaselines(cycles: cycles, sets: sets)
        return resultOrder.compactMap { results[$0] }
    }

    private func makeEvent(
        _ cycle: AutoCycleEvidence,
        cycles: [AutoCycleEvidence],
        sets: [AutoSetRecord]
    ) -> GenericCycleEvent {
        var event = GenericCycleEvent(
            id: cycle.id, setID: configuration.workoutID, sourceEpoch: cycle.sourceEpoch,
            learningEpoch: cycle.learningEpoch, templateHash: cycle.templateHash,
            startTimestamp: cycle.start, completionTimestamp: cycle.completion,
            detectionTimestamp: cycle.detected, authorizationTimestamp: cycle.authorized,
            matchCost: cycle.matchCost
        )
        let owned = frames.filter {
            $0.time >= cycle.start && $0.time <= cycle.completion && $0.sample.epoch == cycle.sourceEpoch
        }
        if let physical = GenericPhysicalPhases.identify(owned) {
            event.turnaroundTimestamp = physical.turnaround
            event.outwardEndTimestamp = physical.outwardEnd
            event.returnStartTimestamp = physical.returnStart
            event.turnaroundPauseDuration = physical.pause
        }
        if let set = sets.first(where: { $0.cycleIDs.contains(cycle.id) }),
           let index = set.cycleIDs.firstIndex(of: cycle.id), index > 0,
           let previous = cycles.first(where: { $0.id == set.cycleIDs[index - 1] }) {
            if previous.learningEpoch == cycle.learningEpoch,
               previous.templateHash == cycle.templateHash,
               previous.sourceEpoch == cycle.sourceEpoch {
                let gap = frames.filter { $0.time >= previous.completion && $0.time <= cycle.start }
                if gap.count > 1, gap.allSatisfy({ !$0.moving }),
                   let first = gap.first, let last = gap.last, last.time - first.time >= 0.20 {
                    event.precedingPauseDuration = last.time - first.time
                }
            }
        }
        return event
    }

    private mutating func resolveBaselines(cycles: [AutoCycleEvidence], sets: [AutoSetRecord]) {
        let cycleByID = Dictionary(uniqueKeysWithValues: cycles.map { ($0.id, $0) })
        var recalculated: [String: Double] = [:]
        for set in sets where set.status != .discarded {
            let evidence = set.cycleIDs.compactMap { cycleByID[$0] }
            guard evidence.count == set.cycleIDs.count, let first = evidence.first,
                  evidence.allSatisfy({ $0.templateHash == first.templateHash &&
                                        $0.sourceEpoch == first.sourceEpoch &&
                                        $0.learningEpoch == first.learningEpoch }) else { continue }
            let speeds = evidence.compactMap { results[$0.id] }
                .filter { $0.status == .available && $0.learningEpoch == first.learningEpoch }
                .compactMap(\.meanSpeed).filter { $0 >= 0.05 }.prefix(3)
            if speeds.count == 3 { recalculated[set.id] = speeds.reduce(0, +) / 3 }
        }
        baselines = recalculated
    }
}

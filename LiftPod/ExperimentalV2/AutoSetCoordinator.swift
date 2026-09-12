import Foundation

/// Pure event-time projection of detector evidence into automatic sets.
struct AutoSetCoordinator {
    let configuration: AutoWorkoutConfiguration
    private(set) var snapshot: AutoWorkoutSnapshot

    private var acceptedCycleIDs: Set<String> = []
    private var hardCutoff: Double?
    private var sealedThrough = -Double.infinity
    private var setCounter = 0
    private var intervalCounter = 0

    private var candidateCycles: [AutoCycleEvidence] = []
    private var candidateKey: BoutKey?
    private var candidateOwnedStart: Double?
    private var candidateExpiry: Double?

    private var currentSetIndex: Int?
    private var currentBoutKey: BoutKey?
    private var workEnd: Double?
    private var recoveryAnchor: Double?
    private var groupingBoundary: Double?
    private var pendingStart: Double?
    private var pendingExpiry: Double?
    private var pendingTraversalID: String?
    private var preparationStart: Double?

    private struct BoutKey: Equatable {
        let sourceEpoch: Int
        let learningEpoch: Int
        let templateHash: String

        init(_ cycle: AutoCycleEvidence) {
            sourceEpoch = cycle.sourceEpoch
            learningEpoch = cycle.learningEpoch
            templateHash = cycle.templateHash
        }
    }

    init(configuration: AutoWorkoutConfiguration) {
        self.configuration = configuration
        snapshot = AutoWorkoutSnapshot(state: .connecting, status: "Connecting")
    }

    mutating func consume(_ batch: AutoEvidenceBatch) {
        guard snapshot.state != .finished else { return }
        let previousTimestamp = snapshot.timestamp
        snapshot.timestamp = batch.timestamp

        if batch.activity == .unavailable {
            interrupt(at: batch.timestamp, reason: "Tracking unavailable", gapStart: previousTimestamp)
            return
        }
        if batch.discontinuity { reacquireAfterDiscontinuity(at: batch.timestamp, gapStart: previousTimestamp) }

        if snapshot.state == .connecting { snapshot.state = .running }
        guard snapshot.state == .running else { return }

        observePossibleWork(batch)
        for cycle in batch.cycles.sorted(by: cycleOrder) { accept(cycle, resolvedThrough: batch.resolvedThrough) }
        expireCandidateIfNeeded(at: batch.timestamp)
        projectActivity(batch)
        settleBoundary(resolvedThrough: batch.resolvedThrough, at: batch.timestamp)
        updateStatus(activity: batch.activity)
    }

    mutating func command(_ input: AutoWorkoutInput) throws {
        switch input.kind {
        case .pause:
            guard snapshot.state == .running || snapshot.state == .connecting else {
                throw V2Error.invalidLifecycle("pause requires active tracking")
            }
            let time = try commandTime(input)
            applyHardBoundary(at: time)
            snapshot.state = .paused
            snapshot.status = "Paused"
        case .resume:
            guard snapshot.state == .paused || snapshot.state == .suspended else {
                throw V2Error.invalidLifecycle("resume requires paused or suspended tracking")
            }
            let time = try commandTime(input)
            snapshot.timestamp = time
            hardCutoff = nil
            snapshot.state = .running
            snapshot.availabilityReason = nil
            if let index = snapshot.intervals.lastIndex(where: { $0.kind == .unavailable && $0.provisional }) {
                snapshot.intervals[index].end = max(snapshot.intervals[index].start, time)
                snapshot.intervals[index].provisional = false
            }
            preparationStart = time
            snapshot.status = "Ready — begin when ready"
        case .suspend:
            guard snapshot.state != .finished else { throw V2Error.invalidLifecycle("workout is finished") }
            let time = try commandTime(input)
            interrupt(at: time, reason: input.reason ?? "Tracking unavailable", gapStart: snapshot.timestamp)
        case .finish:
            guard snapshot.state != .finished else { throw V2Error.invalidLifecycle("workout is already finished") }
            let time = try commandTime(input)
            applyHardBoundary(at: time)
            snapshot.state = .finished
            snapshot.status = "Workout finished"
        case .endSet:
            guard snapshot.state == .running else { throw V2Error.invalidLifecycle("end set requires active tracking") }
            let time = try commandTime(input)
            snapshot.timestamp = time
            sealCurrent(at: time, frontier: time)
            clearCandidate(asUnclassifiedThrough: time)
            resetOpenBout()
            snapshot.status = "Ready — begin when ready"
        case .correction:
            guard let correction = input.correction else {
                throw V2Error.invalidLifecycle("correction command requires a correction")
            }
            let time = input.timestamp ?? snapshot.timestamp ?? 0
            guard time.isFinite, snapshot.timestamp.map({ time + 1e-9 >= $0 }) ?? true else {
                throw V2Error.invalidLifecycle("correction requires a current finite timestamp")
            }
            try apply(correction, at: time)
        case .sample, .clock:
            throw V2Error.invalidLifecycle("normalized evidence must be consumed as a batch")
        }
    }

    private mutating func observePossibleWork(_ batch: AutoEvidenceBatch) {
        var start: Double?
        if let progress = batch.progress, progress.meaningfulSections > 0,
           progress.start + 1e-9 >= sealedThrough {
            start = progress.start
            recoveryAnchor = max(recoveryAnchor ?? progress.observedAt, progress.observedAt)
            if pendingTraversalID == nil {
                pendingTraversalID = progress.traversalID
                pendingStart = progress.start
                pendingExpiry = progress.start + configuration.candidateLifetime
            } else if progress.replacement {
                // A replacement can refine the explanation, but inherits the original fixed deadline.
                pendingTraversalID = progress.traversalID
                pendingStart = min(pendingStart ?? progress.start, progress.start)
            } else if progress.traversalID == pendingTraversalID {
                pendingStart = min(pendingStart ?? progress.start, progress.start)
            }
        }
        if start == nil, batch.activity == .moving, let candidateStart = batch.candidateStart,
           candidateStart + 1e-9 >= sealedThrough,
           workEnd.map({ candidateStart > $0 + 1e-9 }) ?? true {
            start = candidateStart
        }
        if let start {
            pendingStart = min(pendingStart ?? start, start)
            pendingExpiry = pendingExpiry ?? (start + configuration.candidateLifetime)
        }
    }

    private mutating func accept(_ cycle: AutoCycleEvidence, resolvedThrough: Double) {
        guard cycle.start.isFinite, cycle.completion.isFinite, cycle.completion >= cycle.start,
              !acceptedCycleIDs.contains(cycle.id), cycle.start + 1e-9 >= sealedThrough,
              hardCutoff.map({ cycle.completion <= $0 + 1e-9 }) ?? true,
              !snapshot.cycles.contains(where: { overlaps($0, cycle) }) else { return }

        let key = BoutKey(cycle)
        if let index = currentSetIndex, snapshot.sets.indices.contains(index),
            snapshot.sets[index].status != .sealed, snapshot.sets[index].status != .discarded {
            if currentBoutKey == key, belongsToOpenSet(cycle) {
                let classifiesGap = pendingStart != nil || snapshot.restStartedAt != nil
                commit(cycle, to: index, classifiesGap: classifiesGap)
                return
            }
            if let boundary = groupingBoundary, cycle.start > boundary + 1e-9 {
                if resolvedThrough + 1e-9 >= boundary {
                    sealCurrent(at: max(boundary, cycle.detected))
                    resetOpenBout()
                }
            }
        }

        if candidateKey != key {
            clearCandidate(asUnclassifiedThrough: cycle.start)
            candidateKey = key
            candidateOwnedStart = max(cycle.start, sealedThrough.isFinite ? sealedThrough : cycle.start)
            candidateExpiry = candidateOwnedStart.map { $0 + configuration.candidateLifetime }
        }
        guard cycle.start + 1e-9 >= (candidateOwnedStart ?? cycle.start) else { return }
        if let previous = candidateCycles.last, cycle.start - previous.completion > configuration.groupingGrace + 1e-9 {
            clearCandidate(asUnclassifiedThrough: cycle.start)
            candidateKey = key
            candidateOwnedStart = cycle.start
            candidateExpiry = cycle.start + configuration.candidateLifetime
        }
        candidateCycles.append(cycle)
        acceptedCycleIDs.insert(cycle.id)
        snapshot.cycles.append(cycle)
        if let rest = snapshot.restStartedAt { closeRecovery(at: max(rest, cycle.start)) }
        snapshot.restStartedAt = nil
        recoveryAnchor = max(recoveryAnchor ?? cycle.completion, cycle.completion)
        addOrExtendInterval(.unclassified, from: candidateOwnedStart ?? cycle.start,
                            through: cycle.completion, provisional: true)
        snapshot.candidateCount = candidateCycles.count
        pendingStart = nil; pendingExpiry = nil; pendingTraversalID = nil

        if candidateCycles.count >= configuration.minimumCycles {
            if currentSetIndex == nil {
                qualifyCandidate()
            } else if currentBoutKey != candidateKey, let transition = candidateOwnedStart {
                sealCurrent(at: cycle.authorized, frontier: transition)
                resetOpenBout()
                qualifyCandidate()
            }
        }
    }

    private func belongsToOpenSet(_ cycle: AutoCycleEvidence) -> Bool {
        guard let boundary = groupingBoundary else { return true }
        let boutStart = pendingStart ?? cycle.start
        return boutStart <= boundary + 1e-9
    }

    private mutating func commit(_ cycle: AutoCycleEvidence, to index: Int, classifiesGap: Bool) {
        acceptedCycleIDs.insert(cycle.id)
        snapshot.cycles.append(cycle)
        let pauseStart = workEnd
        snapshot.sets[index].cycleIDs.append(cycle.id)
        snapshot.sets[index].end = max(snapshot.sets[index].end, cycle.completion)
        snapshot.sets[index].status = .open
        snapshot.sets[index].sealedAt = nil
        snapshot.intervals.removeAll {
            $0.kind == .unclassified && $0.provisional &&
                max($0.start, cycle.start) <= min($0.end, cycle.completion) + 1e-9
        }
        if classifiesGap, let pauseStart, cycle.start > pauseStart + 1e-9 {
            replaceRecovery(from: pauseStart, through: cycle.start, with: .intraSetPause)
        }
        workEnd = max(workEnd ?? cycle.completion, cycle.completion)
        recoveryAnchor = workEnd
        groupingBoundary = workEnd.map { $0 + configuration.groupingGrace }
        snapshot.restStartedAt = nil
        pendingStart = nil; pendingExpiry = nil; pendingTraversalID = nil
    }

    private mutating func qualifyCandidate() {
        guard let first = candidateCycles.first, let last = candidateCycles.last else { return }
        if let rest = snapshot.restStartedAt { closeRecovery(at: max(rest, first.start)) }
        setCounter += 1
        let record = AutoSetRecord(id: setID(setCounter), cycleIDs: candidateCycles.map(\.id),
                                   start: first.start, end: last.completion)
        snapshot.sets.append(record)
        snapshot.intervals.removeAll {
            $0.kind == .unclassified && $0.provisional &&
                max($0.start, first.start) <= min($0.end, last.completion) + 1e-9
        }
        currentSetIndex = snapshot.sets.count - 1
        currentBoutKey = candidateKey
        workEnd = last.completion
        recoveryAnchor = last.completion
        groupingBoundary = last.completion + configuration.groupingGrace
        candidateCycles = []; candidateKey = nil; candidateOwnedStart = nil; candidateExpiry = nil
        snapshot.candidateCount = 0
        snapshot.restStartedAt = nil
    }

    private mutating func settleBoundary(resolvedThrough: Double, at timestamp: Double) {
        guard let boundary = groupingBoundary, let index = currentSetIndex,
              snapshot.sets.indices.contains(index), snapshot.sets[index].status != .sealed else { return }
        if timestamp + 1e-9 >= boundary { snapshot.sets[index].status = .provisional }
        let unresolvedBeforeBoundary = pendingStart.map {
            $0 <= boundary + 1e-9 && resolvedThrough + 1e-9 < boundary &&
                timestamp < (pendingExpiry ?? .infinity)
        } ?? false
        if resolvedThrough + 1e-9 >= boundary && !unresolvedBeforeBoundary {
            sealCurrent(at: timestamp)
            resetOpenBout()
            if candidateCycles.count >= configuration.minimumCycles { qualifyCandidate() }
        }
    }

    private mutating func projectActivity(_ batch: AutoEvidenceBatch) {
        if let restStartedAt = snapshot.restStartedAt, batch.activity == .quiet {
            addOrExtendInterval(.recovery, from: restStartedAt, through: batch.timestamp,
                                provisional: currentSetIndex != nil)
            return
        }
        guard let workEnd else {
            if batch.activity == .moving {
                let start = projectedActivityStart(batch) ?? batch.timestamp
                if let rest = snapshot.restStartedAt { closeRecovery(at: max(rest, start)) }
                snapshot.restStartedAt = nil
                addOrExtendInterval(.unclassified, from: start, through: batch.timestamp, provisional: true)
            } else if snapshot.sets.isEmpty {
                preparationStart = preparationStart ?? batch.timestamp
                addOrExtendInterval(.preparation, from: preparationStart ?? batch.timestamp,
                                    through: batch.timestamp, provisional: false)
            }
            return
        }
        let recoveryStart = max(workEnd, recoveryAnchor ?? workEnd)
        if batch.activity == .quiet,
           batch.timestamp - recoveryStart + 1e-9 >= configuration.recoveryDelay {
            snapshot.restStartedAt = recoveryStart
            addOrExtendInterval(.recovery, from: recoveryStart, through: batch.timestamp,
                                provisional: currentSetIndex != nil)
        } else if batch.activity == .moving, batch.cycles.isEmpty {
            let proposed = projectedActivityStart(batch)
            let start = proposed.flatMap { $0 > workEnd + 1e-9 ? $0 : nil } ?? batch.timestamp
            if let rest = snapshot.restStartedAt { closeRecovery(at: max(rest, start)) }
            snapshot.restStartedAt = nil
            addOrExtendInterval(.unclassified, from: start, through: batch.timestamp, provisional: true)
            recoveryAnchor = max(recoveryAnchor ?? batch.timestamp, batch.timestamp)
        }
    }

    private func projectedActivityStart(_ batch: AutoEvidenceBatch) -> Double? {
        if let start = batch.progress?.start, start + 1e-9 >= sealedThrough { return start }
        if let start = batch.candidateStart, start + 1e-9 >= sealedThrough { return start }
        return nil
    }

    private mutating func expireCandidateIfNeeded(at timestamp: Double) {
        if let expiry = candidateExpiry, timestamp + 1e-9 >= expiry, candidateCycles.count < configuration.minimumCycles {
            clearCandidate(asUnclassifiedThrough: timestamp)
        }
        if let expiry = pendingExpiry, timestamp + 1e-9 >= expiry {
            if let start = pendingStart { addOrExtendInterval(.unclassified, from: start, through: timestamp, provisional: false) }
            pendingStart = nil; pendingExpiry = nil; pendingTraversalID = nil
        }
    }

    private mutating func updateStatus(activity: AutoActivity) {
        if !candidateCycles.isEmpty, let boundary = groupingBoundary,
           (candidateOwnedStart ?? .infinity) > boundary + 1e-9 {
            snapshot.status = "Finding your next set"
        } else if let index = currentSetIndex, snapshot.sets.indices.contains(index), snapshot.sets[index].status != .sealed {
            if snapshot.restStartedAt != nil { snapshot.status = "Rest · estimated" }
            else { snapshot.status = "Set \(index + 1) · \(snapshot.sets[index].count) reps" }
        } else if !candidateCycles.isEmpty {
            snapshot.status = candidateCycles.count >= 2 ? "Confirming movement" : "Finding movement"
        } else if pendingStart != nil {
            snapshot.status = snapshot.sets.isEmpty ? "Finding movement" : "Finding your next set"
        } else if snapshot.restStartedAt != nil {
            snapshot.status = "Rest · estimated"
        } else if activity == .moving {
            snapshot.status = "Movement unclear"
        } else {
            snapshot.status = "Ready — begin when ready"
        }
    }

    private mutating func interrupt(at time: Double, reason: String, gapStart: Double? = nil) {
        snapshot.timestamp = time
        sealCurrent(at: time, frontier: time)
        clearCandidate(asUnclassifiedThrough: time)
        finalizeRecoveryWithoutExtending()
        snapshot.restStartedAt = nil
        resetOpenBout()
        snapshot.state = .suspended
        snapshot.status = "Tracking unavailable"
        snapshot.availabilityReason = reason
        addOrExtendInterval(.unavailable, from: min(gapStart ?? time, time), through: time, provisional: true)
        hardCutoff = time
    }

    /// A usable new-epoch batch is also the first reacquired sample. Seal the
    /// old ownership and continue without requiring a user Resume command.
    private mutating func reacquireAfterDiscontinuity(at time: Double, gapStart: Double?) {
        sealCurrent(at: time, frontier: time)
        clearCandidate(asUnclassifiedThrough: time)
        finalizeRecoveryWithoutExtending()
        snapshot.restStartedAt = nil
        resetOpenBout()
        addOrExtendInterval(.unavailable, from: min(gapStart ?? time, time), through: time, provisional: false)
        hardCutoff = nil
        snapshot.state = .running
        snapshot.availabilityReason = nil
        preparationStart = time
    }

    private mutating func applyHardBoundary(at time: Double) {
        snapshot.timestamp = time
        hardCutoff = time
        sealCurrent(at: time, frontier: time)
        clearCandidate(asUnclassifiedThrough: time)
        resetOpenBout()
        if let rest = snapshot.restStartedAt { closeRecovery(at: max(rest, time)) }
        snapshot.restStartedAt = nil
    }

    private mutating func sealCurrent(at time: Double, frontier: Double? = nil) {
        guard let index = currentSetIndex, snapshot.sets.indices.contains(index),
              snapshot.sets[index].status != .sealed else { return }
        snapshot.sets[index].status = .sealed
        snapshot.sets[index].sealedAt = time
        sealedThrough = max(sealedThrough, frontier ?? groupingBoundary ?? snapshot.sets[index].end)
    }

    private mutating func resetOpenBout() {
        currentSetIndex = nil; currentBoutKey = nil; workEnd = nil; groupingBoundary = nil
        pendingStart = nil; pendingExpiry = nil; pendingTraversalID = nil
    }

    private mutating func clearCandidate(asUnclassifiedThrough end: Double) {
        if let start = candidateOwnedStart, !candidateCycles.isEmpty {
            let last = candidateCycles.map(\.completion).max() ?? end
            let intervalEnd = max(start, last)
            snapshot.intervals.removeAll {
                $0.kind == .unclassified && $0.provisional &&
                    max($0.start, start) <= min($0.end, intervalEnd) + 1e-9
            }
            addOrExtendInterval(.unclassified, from: start, through: intervalEnd, provisional: false)
        }
        candidateCycles = []; candidateKey = nil; candidateOwnedStart = nil; candidateExpiry = nil
        snapshot.candidateCount = 0
    }

    private mutating func apply(_ correction: AutoWorkoutCorrection, at time: Double) throws {
        guard let index = snapshot.sets.firstIndex(where: { $0.id == correction.setID }) else {
            throw V2Error.invalidLifecycle("correction references an unknown set")
        }
        switch correction.kind {
        case .discard:
            let wasActive = currentSetIndex == index
            snapshot.sets[index].status = .discarded
            snapshot.sets[index].sealedAt = time
            if wasActive {
                sealedThrough = max(sealedThrough, time)
                finalizeRecoveryWithoutExtending()
                snapshot.restStartedAt = nil
                resetOpenBout()
                snapshot.status = "Ready — begin when ready"
            }
        case .count:
            guard let count = correction.count, count >= 0 else {
                throw V2Error.invalidLifecycle("count correction requires a nonnegative count")
            }
            snapshot.sets[index].correctedCount = count
        case .split:
            guard let cycleID = correction.afterCycleID,
                  let split = snapshot.sets[index].cycleIDs.firstIndex(of: cycleID),
                  split < snapshot.sets[index].cycleIDs.count - 1 else {
                throw V2Error.invalidLifecycle("split requires a cycle with cycles after it")
            }
            let wasActive = currentSetIndex == index
            let originalStatus = snapshot.sets[index].status
            let trailing = Array(snapshot.sets[index].cycleIDs[(split + 1)...])
            snapshot.sets[index].cycleIDs.removeSubrange((split + 1)...)
            snapshot.sets[index].correctedCount = nil
            refreshBounds(at: index)
            if wasActive {
                snapshot.sets[index].status = .sealed
                snapshot.sets[index].sealedAt = time
            }
            setCounter += 1
            let newIndex = index + 1
            var newSet = AutoSetRecord(id: setID(setCounter), cycleIDs: trailing,
                                       start: cycle(trailing.first)?.start ?? snapshot.sets[index].end,
                                       end: cycle(trailing.last)?.completion ?? snapshot.sets[index].end,
                                       status: wasActive ? .open : originalStatus)
            newSet.sealedAt = wasActive ? nil : snapshot.sets[index].sealedAt
            snapshot.sets.insert(newSet, at: newIndex)
            if wasActive {
                currentSetIndex = newIndex
                sealedThrough = max(sealedThrough, newSet.start)
                workEnd = newSet.end
                recoveryAnchor = max(recoveryAnchor ?? newSet.end, newSet.end)
                groupingBoundary = newSet.end + configuration.groupingGrace
            } else if let currentSetIndex, currentSetIndex > index {
                self.currentSetIndex = currentSetIndex + 1
            }
        case .merge:
            guard let otherID = correction.otherSetID,
                  let other = snapshot.sets.firstIndex(where: { $0.id == otherID }), abs(other - index) == 1 else {
                throw V2Error.invalidLifecycle("merge requires an adjacent set")
            }
            let keep = min(index, other), remove = max(index, other)
            let activeWasMerged = currentSetIndex == keep || currentSetIndex == remove
            let activeKey = activeWasMerged ? currentBoutKey : nil
            let merged = (snapshot.sets[keep].cycleIDs + snapshot.sets[remove].cycleIDs).uniqued()
            snapshot.sets[keep].cycleIDs = merged.sorted { (cycle($0)?.start ?? 0) < (cycle($1)?.start ?? 0) }
            snapshot.sets[keep].correctedCount = nil
            snapshot.sets[keep].status = activeWasMerged ? .open :
                (snapshot.sets[remove].status == .open ? .open : snapshot.sets[keep].status)
            snapshot.sets[keep].sealedAt = activeWasMerged ? nil :
                max(snapshot.sets[keep].sealedAt ?? 0, snapshot.sets[remove].sealedAt ?? 0)
            refreshBounds(at: keep)
            snapshot.sets.remove(at: remove)
            if activeWasMerged {
                currentSetIndex = keep
                currentBoutKey = activeKey
                workEnd = snapshot.sets[keep].end
                recoveryAnchor = max(recoveryAnchor ?? snapshot.sets[keep].end, snapshot.sets[keep].end)
                groupingBoundary = snapshot.sets[keep].end + configuration.groupingGrace
            }
            else if let currentSetIndex, currentSetIndex > remove { self.currentSetIndex = currentSetIndex - 1 }
        }
    }

    private func commandTime(_ input: AutoWorkoutInput) throws -> Double {
        guard let time = input.timestamp, time.isFinite,
              snapshot.timestamp.map({ time + 1e-9 >= $0 }) ?? true else {
            throw V2Error.invalidLifecycle("command requires a current finite timestamp")
        }
        return time
    }

    private func cycle(_ id: String?) -> AutoCycleEvidence? {
        guard let id else { return nil }
        return snapshot.cycles.first { $0.id == id }
    }

    private mutating func refreshBounds(at index: Int) {
        let evidence = snapshot.sets[index].cycleIDs.compactMap { cycle($0) }
        if let start = evidence.map(\.start).min(), let end = evidence.map(\.completion).max() {
            snapshot.sets[index].start = start; snapshot.sets[index].end = end
        }
    }

    private mutating func addOrExtendInterval(_ kind: AutoIntervalKind, from start: Double, through end: Double,
                                               provisional: Bool) {
        guard start.isFinite, end.isFinite, end + 1e-9 >= start else { return }
        if let index = snapshot.intervals.indices.last,
           snapshot.intervals[index].kind == kind,
           start <= snapshot.intervals[index].end + 0.1 {
            snapshot.intervals[index].start = min(snapshot.intervals[index].start, start)
            snapshot.intervals[index].end = max(snapshot.intervals[index].end, end)
            snapshot.intervals[index].provisional = provisional
            return
        }
        intervalCounter += 1
        snapshot.intervals.append(.init(id: "interval-\(intervalCounter)", kind: kind,
                                        start: start, end: end, provisional: provisional))
    }

    private mutating func closeRecovery(at time: Double) {
        guard let index = snapshot.intervals.lastIndex(where: { $0.kind == .recovery && $0.provisional }) else { return }
        snapshot.intervals[index].end = max(snapshot.intervals[index].start, time)
        snapshot.intervals[index].provisional = false
    }

    private mutating func finalizeRecoveryWithoutExtending() {
        guard let index = snapshot.intervals.lastIndex(where: { $0.kind == .recovery && $0.provisional }) else { return }
        snapshot.intervals[index].provisional = false
    }

    private mutating func replaceRecovery(from start: Double, through end: Double, with kind: AutoIntervalKind) {
        if let index = snapshot.intervals.lastIndex(where: {
            $0.kind == .recovery && $0.start <= start + 1e-9 && $0.end + 1e-9 >= start
        }) {
            snapshot.intervals[index].kind = kind
            snapshot.intervals[index].end = end
            snapshot.intervals[index].provisional = false
        } else {
            addOrExtendInterval(kind, from: start, through: end, provisional: false)
        }
    }

    private func setID(_ ordinal: Int) -> String {
        "\(configuration.workoutID.uuidString.lowercased())-set-\(ordinal)"
    }

    private func overlaps(_ lhs: AutoCycleEvidence, _ rhs: AutoCycleEvidence) -> Bool {
        max(lhs.start, rhs.start) < min(lhs.completion, rhs.completion) - 1e-9
    }

    private func cycleOrder(_ lhs: AutoCycleEvidence, _ rhs: AutoCycleEvidence) -> Bool {
        lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

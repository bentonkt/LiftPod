import Foundation

/// Bounded evidence adapter for automatic workouts.
struct AutoPatternEngine: Sendable {
    let configuration: AutoWorkoutConfiguration
    private var features = GenericFeaturePipeline()
    private var detector: GenericCycleDetector
    private var frames: [GenericMotionFrame] = []
    private var sampleEpoch: Int?
    private var evidenceEpoch = 0
    private var ownershipStart: Double?
    private var boundarySequence = 0
    private var quietSince: Double?
    private var quietBoundaryApplied = false
    private var unavailable = false
    private var pendingDiscontinuity = false
    private var ownedCycleCount = 0
    private var lastAcceptedCompletion = -Double.infinity
    private var lastProgress: (id: String, sections: Int)?
    private(set) var latestPreparedFrame: GenericMotionFrame?
    private(set) var resolvedThrough = -Double.infinity

    init(configuration: AutoWorkoutConfiguration) {
        self.configuration = configuration
        detector = .init(setID: configuration.workoutID, configuration: configuration.detector)
    }

    mutating func observe(_ sample: ResampledMotionSample) -> AutoEvidenceBatch {
        if let sampleEpoch, sampleEpoch != sample.epoch { discontinuity(at: sample.sourceTimestamp) }
        sampleEpoch = sample.epoch
        let logicalSample = ResampledMotionSample(sourceTimestamp: sample.sourceTimestamp,
            sessionTime: sample.sessionTime, sensorSide: sample.sensorSide,
            userAcceleration: sample.userAcceleration, rotationRate: sample.rotationRate,
            gravity: sample.gravity, attitude: sample.attitude,
            interpolationStatus: sample.interpolationStatus, epoch: evidenceEpoch)
        guard let frame = features.observe(logicalSample) else {
            if !unavailable { discontinuity(at: sample.sourceTimestamp) }
            unavailable = true
            sampleEpoch = sample.epoch
            pendingDiscontinuity = false
            return makeBatch(at: sample.sourceTimestamp, activity: .unavailable, discontinuity: true)
        }
        unavailable = false
        let didDiscontinue = pendingDiscontinuity
        pendingDiscontinuity = false
        latestPreparedFrame = frame
        retain(frame)

        if frame.moving {
            quietSince = nil
            quietBoundaryApplied = false
            if ownershipStart == nil { ownershipStart = max(frame.time, resolvedThrough) }
        } else {
            quietSince = quietSince ?? frame.time
            if !quietBoundaryApplied, let quietSince,
               frame.time - quietSince >= configuration.groupingGrace - 1e-9 {
                boundary(at: frame.time)
                quietBoundaryApplied = true
            }
        }

        expireCandidate(at: frame.time)
        var cycles: [AutoCycleEvidence] = []
        if let traversal = detector.observe(frame, departureAllowed: frame.moving) {
            authorize(traversal, at: frame.time, into: &cycles)
        }
        var templates: [GenericPattern] = []
        if let pattern = detector.latestDecision?.pattern {
            templates.append(pattern)
            detector.beginBackfill()
            let start = max(ownershipStart ?? frame.time, resolvedThrough)
            for historical in frames where historical.time >= start - 1e-9 &&
                historical.time <= frame.time + 1e-9 && historical.sample.epoch == pattern.sourceEpoch {
                if let traversal = detector.backfill(historical, departureAllowed: true) {
                    authorize(traversal, at: frame.time, into: &cycles)
                }
            }
        }
        cycles.sort { $0.start < $1.start }

        let progress = progressEvidence()
        advanceFrontier(at: frame.time)
        return AutoEvidenceBatch(timestamp: frame.time, sourceEpoch: evidenceEpoch, cycles: cycles,
            progress: progress, activity: frame.moving ? .moving : .quiet,
            candidateStart: ownershipStart, resolvedThrough: resolvedThrough,
            discontinuity: didDiscontinue, templates: templates)
    }

    /// Ends ownership at a hard cutoff without discarding a compatible cached
    /// template. No unfinished traversal or later backfill can cross `time`.
    mutating func boundary(at time: Double) {
        boundarySequence += 1
        detector.boundary(at: time)
        frames.removeAll { $0.time < time }
        ownershipStart = nil
        ownedCycleCount = 0
        lastProgress = nil
        resolvedThrough = max(resolvedThrough, time)
    }

    /// Invalidates mounting-dependent preprocessing and cached patterns.
    mutating func discontinuity(at time: Double) {
        boundarySequence += 1
        evidenceEpoch += 1
        pendingDiscontinuity = true
        sampleEpoch = nil
        features.reset()
        detector.discontinuity(at: time)
        frames.removeAll()
        ownershipStart = nil
        ownedCycleCount = 0
        quietSince = nil
        quietBoundaryApplied = false
        lastProgress = nil
        latestPreparedFrame = nil
        lastAcceptedCompletion = max(lastAcceptedCompletion, time)
        resolvedThrough = max(resolvedThrough, time)
    }

    private mutating func retain(_ frame: GenericMotionFrame) {
        frames.append(frame)
        let cutoff = frame.time - configuration.contextDuration
        frames.removeAll { $0.time < cutoff }
    }

    private mutating func expireCandidate(at time: Double) {
        guard ownedCycleCount < configuration.minimumCycles, let start = ownershipStart,
              time - start >= configuration.candidateLifetime - 1e-9 else { return }
        boundary(at: time)
    }

    private mutating func advanceFrontier(at time: Double) {
        if let ownershipStart {
            if ownedCycleCount >= configuration.minimumCycles {
                let traversalLatency = configuration.detector.maximumCycleDuration + 0.4
                resolvedThrough = max(resolvedThrough, max(lastAcceptedCompletion, time - traversalLatency))
            } else {
                resolvedThrough = max(resolvedThrough, min(ownershipStart, time - configuration.candidateLifetime))
            }
        } else {
            resolvedThrough = max(resolvedThrough, time)
        }
    }

    private mutating func authorize(_ traversal: GenericTraversal, at authorization: Double,
                                    into output: inout [AutoCycleEvidence]) {
        guard let pattern = detector.pattern, evidenceEpoch == pattern.sourceEpoch,
              let ownershipStart, traversal.start >= max(ownershipStart, resolvedThrough) - 1e-9,
              traversal.completion > traversal.start,
              traversal.start >= lastAcceptedCompletion - 0.021 else { return }
        let id = "\(configuration.workoutID.uuidString)-\(evidenceEpoch)-\(boundarySequence)-\(traversal.start.bitPattern)-\(traversal.completion.bitPattern)"
        guard !output.contains(where: { overlaps($0.start, $0.completion, traversal.start, traversal.completion) }) else { return }
        output.append(.init(id: id, sourceEpoch: evidenceEpoch, learningEpoch: pattern.learningEpoch,
            templateHash: pattern.contentHash, start: traversal.start, completion: traversal.completion,
            detected: traversal.detected, authorized: authorization, matchCost: traversal.cost))
        lastAcceptedCompletion = max(lastAcceptedCompletion, traversal.completion)
        ownedCycleCount += 1
    }

    private func overlaps(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool {
        max(a0, b0) < min(a1, b1) - 0.021
    }

    private mutating func progressEvidence() -> AutoProgressEvidence? {
        guard let p = detector.progress, p.start >= max(ownershipStart ?? p.start, resolvedThrough) - 1e-9,
              let pattern = detector.pattern else {
            lastProgress = nil
            return nil
        }
        let id = "\(configuration.workoutID.uuidString)-\(evidenceEpoch)-\(boundarySequence)-\(p.lineage)-\(p.start.bitPattern)"
        let replacement = lastProgress.map { $0.id != id } ?? false
        guard replacement || lastProgress == nil || p.meaningfulSections > lastProgress!.sections else { return nil }
        lastProgress = (id, p.meaningfulSections)
        return .init(traversalID: id, start: p.start, observedAt: p.observedAt,
                     meaningfulSections: p.meaningfulSections, replacement: replacement)
    }

    private func makeBatch(at time: Double, activity: AutoActivity, discontinuity: Bool) -> AutoEvidenceBatch {
        .init(timestamp: time, sourceEpoch: evidenceEpoch, cycles: [], progress: nil,
              activity: activity, candidateStart: ownershipStart, resolvedThrough: resolvedThrough,
              discontinuity: discontinuity, templates: [])
    }
}

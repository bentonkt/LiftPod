import Foundation

/// Streaming arming and cycle-boundary layer for the deterministic full-cycle matcher.
struct V2TemplateCycleSegmenter: Sendable {
    let profile: V2DSPProfile
    let setDescriptor: V2SetDescriptor

    private(set) var phase: V2DetectorPhase = .waitingForBottom
    private(set) var detectorEpoch = 0
    private(set) var cycleSequence = 0
    private(set) var events: [V2CycleEvidence] = []

    private var preRoll: [ResampledMotionSample] = []
    private var cycle: [ResampledMotionSample] = []
    private var quietStart: Double?
    private var cycleQuietStart: Double?
    private var refractoryUntil = -Double.infinity
    private var lastEvaluationCount = 0

    init(profile: V2DSPProfile, setDescriptor: V2SetDescriptor) {
        self.profile = profile
        self.setDescriptor = setDescriptor
    }

    mutating func reset(discontinuity: Bool = false) {
        phase = .waitingForBottom
        preRoll = []
        cycle = []
        quietStart = nil
        cycleQuietStart = nil
        lastEvaluationCount = 0
        if discontinuity { detectorEpoch += 1 }
    }

    mutating func observe(_ sample: ResampledMotionSample, departureAllowed: Bool) -> [V2CycleEvidence] {
        let before = events.count
        let config = profile.identity.templateConfiguration
        let activity = max(sample.userAcceleration.magnitude, 0.1 * sample.rotationRate.magnitude)
        let preRollCount = max(1, Int((config.preRollDuration * profile.identity.sampleRate).rounded(.up)))

        if cycle.isEmpty {
            preRoll.append(sample)
            if preRoll.count > preRollCount { preRoll.removeFirst(preRoll.count - preRollCount) }
            if activity <= config.startActivityThreshold {
                quietStart = quietStart ?? sample.sourceTimestamp
                phase = .ready
            } else {
                let wasArmed = quietStart.map { sample.sourceTimestamp - $0 >= config.quietDuration } ?? false
                if wasArmed, departureAllowed, sample.sourceTimestamp >= refractoryUntil {
                    cycle = preRoll
                    lastEvaluationCount = 0
                    phase = .outbound
                }
                quietStart = nil
            }
            return Array(events.dropFirst(before))
        }

        cycle.append(sample)
        let duration = sample.sourceTimestamp - (cycle.first?.sourceTimestamp ?? sample.sourceTimestamp)
        phase = duration < profile.identity.timing.minimumCycleDuration / 2 ? .outbound : .returning
        cycleQuietStart = activity <= config.startActivityThreshold
            ? (cycleQuietStart ?? sample.sourceTimestamp) : nil

        if duration > profile.identity.timing.maximumCycleDuration {
            emit(match: nil, rejection: .ambiguousTemplate, detectionTime: sample.sourceTimestamp)
            resetCycle(at: sample.sourceTimestamp)
        } else if duration >= profile.identity.timing.minimumCycleDuration,
                  cycle.count - lastEvaluationCount >= config.evaluationStride {
            lastEvaluationCount = cycle.count
            let match = V2FullCycleTemplateMatcher(profile: profile).evaluate(samples: cycle)
            if match.accepted {
                emit(match: match, rejection: nil, detectionTime: sample.sourceTimestamp)
                refractoryUntil = sample.sourceTimestamp + profile.identity.timing.refractoryDuration
                resetCycle(at: sample.sourceTimestamp)
            } else if let cycleQuietStart,
                      sample.sourceTimestamp - cycleQuietStart >= config.quietDuration {
                emit(match: match, rejection: match.rejectionReason ?? .ambiguousTemplate,
                     detectionTime: sample.sourceTimestamp)
                resetCycle(at: sample.sourceTimestamp)
            }
        }
        return Array(events.dropFirst(before))
    }

    mutating func setCommitted(_ committed: Bool, forCandidateID id: String) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].committed = committed
    }

    private mutating func emit(match: V2TemplateMatch?, rejection: V2RejectionReason?, detectionTime: Double) {
        guard let first = cycle.first, let last = cycle.last else { return }
        let mapped = match?.mappedLandmarks ?? []
        let landmarks = mapped.count == 5 ? mapped : [0, 16, 32, 48, 63]
        func sampleIndex(_ frame: Int) -> Int {
            min(cycle.count - 1, max(0, Int((Double(frame) * Double(cycle.count - 1) / 63).rounded())))
        }
        let top = cycle[sampleIndex(landmarks[min(2, landmarks.count - 1)])]
        let startActivity = max(first.userAcceleration.magnitude, 0.1 * first.rotationRate.magnitude)
        let topActivity = max(top.userAcceleration.magnitude, 0.1 * top.rotationRate.magnitude)
        let returnActivity = max(last.userAcceleration.magnitude, 0.1 * last.rotationRate.magnitude)
        let id = "\(profile.contentHash)-\(detectorEpoch)-\(cycleSequence)"
        events.append(.init(id: id, setID: setDescriptor.setID, exercise: setDescriptor.exercise,
                            authorizationSource: setDescriptor.authorizationSource,
                            profileID: setDescriptor.profileID, dspContentHash: setDescriptor.dspContentHash,
                            detectorEpoch: detectorEpoch, cycleSequence: cycleSequence,
                            startTimestamp: first.sourceTimestamp, topTimestamp: top.sourceTimestamp,
                            completionTimestamp: last.sourceTimestamp, detectionTimestamp: detectionTime,
                            bottom: startActivity, top: topActivity, returned: returnActivity,
                            outboundArea: 0, returnArea: 0, committed: rejection == nil,
                            rejectionReason: rejection))
        cycleSequence += 1
    }

    private mutating func resetCycle(at timestamp: Double) {
        cycle = []
        preRoll = []
        quietStart = timestamp
        cycleQuietStart = nil
        lastEvaluationCount = 0
        phase = .waitingForBottom
    }
}

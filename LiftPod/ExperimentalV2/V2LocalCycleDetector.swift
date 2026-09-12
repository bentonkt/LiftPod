import Foundation

struct V2CycleLandmarks: Codable, Sendable, Equatable {
    var bottom: Double?
    var top: Double?
    var returned: Double?
    var startTimestamp: Double?
    var topTimestamp: Double?
    var returnTimestamp: Double?
}

struct V2CycleValidator: Sendable {
    let profile: V2DSPProfile

    func rejection(bottom: Double, top: Double, returned: Double,
                   start: Double, topTime: Double, returnTime: Double,
                   outboundArea: Double, returnArea: Double) -> V2RejectionReason? {
        let local = profile.identity.localCycle
        let timing = profile.identity.timing
        let values = [bottom, top, returned, start, topTime, returnTime, outboundArea, returnArea]
        guard values.allSatisfy(\.isFinite) else { return .nonFiniteEvidence }
        let duration = returnTime - start
        guard start < topTime, topTime <= returnTime else { return .invalidOrdering }
        guard duration >= timing.minimumCycleDuration, duration <= timing.maximumCycleDuration,
              topTime - start >= timing.minimumPhaseDuration,
              returnTime - topTime >= timing.minimumPhaseDuration else { return .invalidDuration }
        guard top - bottom >= local.minimumOutboundExcursion else { return .insufficientExcursion }
        let returnExcursion = top - returned
        guard returnExcursion >= local.minimumReturnExcursion,
              returnExcursion / max(top - bottom, 1e-9) >= local.minimumReturnFraction else {
            return .incompleteReturn
        }
        let reference = 0.0
        guard returned <= reference + local.trainedSpan * local.maximumPositiveBottomOffsetFraction else {
            return .returnTooHigh
        }
        guard returned >= reference - local.trainedSpan * local.maximumDeeperReturnFraction else {
            return .returnTooDeep
        }
        return nil
    }
}

struct V2LocalCycleSegmenter: Sendable {
    let profile: V2DSPProfile
    let setDescriptor: V2SetDescriptor
    private(set) var phase: V2DetectorPhase = .waitingForBottom
    private(set) var landmarks = V2CycleLandmarks()
    private(set) var detectorEpoch = 0
    private(set) var cycleSequence = 0
    private(set) var events: [V2CycleEvidence] = []

    private var persistence = 0
    private var refractoryUntil = -Double.infinity
    private var outboundArea = 0.0
    private var returnArea = 0.0
    private var lastTimestamp: Double?
    private var credibleReturn = false
    private var settlingStart: Double?

    init(profile: V2DSPProfile, setDescriptor: V2SetDescriptor) {
        self.profile = profile
        self.setDescriptor = setDescriptor
    }

    mutating func reset(discontinuity: Bool = false) {
        phase = .waitingForBottom; landmarks = .init(); persistence = 0
        outboundArea = 0; returnArea = 0; lastTimestamp = nil
        credibleReturn = false; settlingStart = nil
        if discontinuity { detectorEpoch += 1 }
    }

    mutating func observe(signal: Double, gyroscopeMagnitude: Double, timestamp: Double,
                          departureAllowed: Bool) -> [V2CycleEvidence] {
        let before = events.count
        let local = profile.identity.localCycle
        let timing = profile.identity.timing
        let dt = max(0, min(0.1, timestamp - (lastTimestamp ?? timestamp)))
        defer { lastTimestamp = timestamp }
        guard signal.isFinite, gyroscopeMagnitude.isFinite, timestamp.isFinite else {
            reject(.nonFiniteEvidence, at: timestamp); reset(discontinuity: true); return Array(events.dropFirst(before))
        }

        switch phase {
        case .waitingForBottom:
            persistence = signal >= local.startLower && signal <= local.startUpper ? persistence + 1 : 0
            if persistence >= timing.persistenceSamples {
                phase = .ready
                landmarks.bottom = signal; landmarks.returned = nil
                persistence = 0
            }
        case .ready:
            if signal >= local.startLower, signal <= local.startUpper {
                landmarks.bottom = min(landmarks.bottom ?? signal, signal)
            }
            let departed = signal - (landmarks.bottom ?? signal) >= local.leaveStart
            persistence = departureAllowed && timestamp >= refractoryUntil && departed ? persistence + 1 : 0
            if persistence >= timing.persistenceSamples {
                phase = .outbound
                landmarks.startTimestamp = timestamp - Double(timing.persistenceSamples - 1) / profile.identity.sampleRate
                landmarks.top = signal; landmarks.topTimestamp = timestamp
                outboundArea = 0; returnArea = 0; persistence = 0
            }
        case .outbound:
            outboundArea += max(0, signal - (landmarks.bottom ?? signal)) * dt
            if signal > (landmarks.top ?? signal) {
                landmarks.top = signal; landmarks.topTimestamp = timestamp; persistence = 0
            }
            guard let bottom = landmarks.bottom, let top = landmarks.top,
                  let start = landmarks.startTimestamp, let topTime = landmarks.topTimestamp else { break }
            if timestamp - start > timing.maximumCycleDuration { reject(.invalidDuration, at: timestamp); reset(); break }
            let excursion = top - bottom
            if signal <= local.startUpper, excursion < local.minimumOutboundExcursion {
                reject(.insufficientExcursion, at: timestamp); reset(); break
            }
            if excursion >= local.minimumOutboundExcursion, timestamp - topTime > timing.maximumTurnaroundPause {
                reject(.excessivePause, at: timestamp); reset(); break
            }
            let reversal = top - signal >= max(0.01, local.trainedSpan * local.reversalDisplacementFraction)
            persistence = reversal ? persistence + 1 : 0
            if persistence >= timing.persistenceSamples,
               excursion >= local.minimumOutboundExcursion,
               topTime - start >= timing.minimumPhaseDuration {
                phase = .returning; landmarks.returned = signal; landmarks.returnTimestamp = timestamp
                persistence = 0
            }
        case .returning:
            guard let bottom = landmarks.bottom, let top = landmarks.top,
                  let start = landmarks.startTimestamp, let topTime = landmarks.topTimestamp else { break }
            returnArea += max(0, top - signal) * dt
            if signal < (landmarks.returned ?? signal) {
                landmarks.returned = signal; landmarks.returnTimestamp = timestamp
                persistence = 0; settlingStart = nil
            }
            guard let returned = landmarks.returned, let returnTime = landmarks.returnTimestamp else { break }
            let validator = V2CycleValidator(profile: profile)
            let validationReason = validator.rejection(bottom: bottom, top: top, returned: returned,
                                                        start: start, topTime: topTime, returnTime: returnTime,
                                                        outboundArea: outboundArea, returnArea: returnArea)
            credibleReturn = validationReason == nil
            if credibleReturn {
                if gyroscopeMagnitude <= local.gyroscopeQuietThreshold {
                    settlingStart = settlingStart ?? timestamp
                    persistence += 1
                    if timestamp - (settlingStart ?? timestamp) >= local.returnSettlingDuration,
                       persistence >= timing.persistenceSamples {
                        complete(bottom: bottom, top: top, returned: returned, start: start,
                                 topTime: topTime, returnTime: returnTime, detectionTime: timestamp)
                        refractoryUntil = timestamp + timing.refractoryDuration
                        reset()
                    }
                } else { settlingStart = nil; persistence = 0 }
                if signal - returned >= local.leaveStart {
                    persistence += 1
                    if persistence >= timing.persistenceSamples {
                        complete(bottom: bottom, top: top, returned: returned, start: start,
                                 topTime: topTime, returnTime: returnTime, detectionTime: timestamp)
                        refractoryUntil = timestamp + timing.refractoryDuration
                        reset()
                    }
                }
            } else {
                if gyroscopeMagnitude <= local.gyroscopeQuietThreshold {
                    settlingStart = settlingStart ?? timestamp
                    if timestamp - (settlingStart ?? timestamp) >= local.returnSettlingDuration,
                       let validationReason {
                        reject(validationReason, at: timestamp); reset(); break
                    }
                } else { settlingStart = nil }
                let newDeparture = signal - returned >= local.leaveStart
                persistence = newDeparture ? persistence + 1 : 0
                if persistence >= timing.persistenceSamples {
                    reject(.incompleteReturn, at: returnTime)
                    phase = .outbound
                    landmarks = .init(bottom: returned, top: signal, returned: nil,
                                      startTimestamp: returnTime, topTimestamp: timestamp, returnTimestamp: nil)
                    outboundArea = 0; returnArea = 0; persistence = 0
                }
            }
            if timestamp - start > timing.maximumCycleDuration { reject(.invalidDuration, at: timestamp); reset() }
        }
        return Array(events.dropFirst(before))
    }

    mutating func setCommitted(_ committed: Bool, forCandidateID id: String) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].committed = committed
    }

    private mutating func complete(bottom: Double, top: Double, returned: Double, start: Double,
                                   topTime: Double, returnTime: Double, detectionTime: Double) {
        events.append(evidence(bottom: bottom, top: top, returned: returned, start: start,
                               topTime: topTime, returnTime: returnTime, detectionTime: detectionTime,
                               rejection: nil))
        cycleSequence += 1
    }

    private mutating func reject(_ reason: V2RejectionReason, at timestamp: Double) {
        guard let bottom = landmarks.bottom, let top = landmarks.top,
              let start = landmarks.startTimestamp, let topTime = landmarks.topTimestamp else { return }
        events.append(evidence(bottom: bottom, top: top, returned: landmarks.returned ?? bottom,
                               start: start, topTime: topTime,
                               returnTime: landmarks.returnTimestamp ?? timestamp,
                               detectionTime: timestamp, rejection: reason))
        cycleSequence += 1
    }

    private func evidence(bottom: Double, top: Double, returned: Double, start: Double,
                          topTime: Double, returnTime: Double, detectionTime: Double,
                          rejection: V2RejectionReason?) -> V2CycleEvidence {
        let id = "\(profile.contentHash)-\(detectorEpoch)-\(cycleSequence)"
        return V2CycleEvidence(id: id, setID: setDescriptor.setID, exercise: setDescriptor.exercise,
                               authorizationSource: setDescriptor.authorizationSource,
                               profileID: setDescriptor.profileID, dspContentHash: setDescriptor.dspContentHash,
                               detectorEpoch: detectorEpoch, cycleSequence: cycleSequence,
                               startTimestamp: start, topTimestamp: topTime, completionTimestamp: returnTime,
                               detectionTimestamp: detectionTime, bottom: bottom, top: top, returned: returned,
                               outboundArea: outboundArea, returnArea: returnArea,
                               committed: rejection == nil, rejectionReason: rejection)
    }
}

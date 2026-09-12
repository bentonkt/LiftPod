import Foundation

struct V6DetectorUpdate: Sendable {
    let filteredSignal: Double?
    let diagnostics: V6Diagnostics
}

/// Owns all algorithm-specific mutable state. A set freezes one profile and one
/// instance of this detector, so changing the UI selection cannot alter a set in flight.
struct V6CurlDetector: Sendable {
    let profile: V2DSPProfile
    let descriptor: V2SetDescriptor

    private var segmenter: V6QualifiedCycleSegmenter
    private var signalFilter: ScalarBiquadFilter
    private var rateFilter: ScalarBiquadFilter
    private var angle = V6ContinuousAngle()
    private var axisBuffer: [ResampledMotionSample] = []
    private var frozenAxis: ExperimentalVector3?
    private var previousEstimate: V6AxisEstimate?
    private var stableEstimateCount = 0
    private var recoveryStart: Double?
    private var unresolvedQuietStart: Double?
    private var unresolvedMotionSeen = false
    private var fixedAxisInvalid = false
    private var candidateSamples: [ResampledMotionSample] = []
    private var lastRejection: V2RejectionReason?
    private(set) var events: [V2CycleEvidence] = []

    init(profile: V2DSPProfile, descriptor: V2SetDescriptor) {
        self.profile = profile
        self.descriptor = descriptor
        segmenter = .init(profile: profile)
        signalFilter = .init(coefficients: profile.identity.filter)
        rateFilter = .init(coefficients: profile.identity.filter)
    }

    var phase: V2DetectorPhase {
        if recoveryStart != nil { return .recovering }
        if profile.identity.algorithm == .adaptiveAxis, frozenAxis == nil,
           segmenter.state == .seekingBottom { return .estimatingAxis }
        switch segmenter.state {
        case .seekingBottom: return .waitingForBottom
        case .ready: return .ready
        case .outbound: return .outbound
        case .returning: return .returning
        case .bottomPending: return .bottomPending
        }
    }

    var landmarks: V2CycleLandmarks {
        .init(bottom: segmenter.bottom?.value, top: segmenter.top?.value, returned: segmenter.returned?.value)
    }

    mutating func reset(discontinuity: Bool = false) {
        segmenter.reset(discontinuity: discontinuity)
        signalFilter.reset(); rateFilter.reset(); angle = .init()
        axisBuffer.removeAll(keepingCapacity: true); candidateSamples.removeAll(keepingCapacity: true)
        frozenAxis = nil; previousEstimate = nil; stableEstimateCount = 0; recoveryStart = nil
        unresolvedQuietStart = nil; unresolvedMotionSeen = false; fixedAxisInvalid = false
    }

    mutating func setCommitted(_ committed: Bool, forCandidateID id: String) {
        guard let index = events.lastIndex(where: { $0.id == id }) else { return }
        events[index].committed = committed
        if !committed, events[index].rejectionReason == nil { events[index].rejectionReason = .outsideActiveSet }
    }

    mutating func observe(_ sample: ResampledMotionSample, reference: V2ReferenceMeasurements,
                          departureAllowed: Bool) -> V6DetectorUpdate {
        switch profile.identity.algorithm {
        case .qualifiedLocalCycle:
            let source = profile.identity.signalSource == .gravity ? sample.gravity : sample.userAcceleration
            let scalar = profile.identity.polarity * source.value(on: profile.identity.projectionAxis) - reference.neutralSignal
            return consume(sample, signal: signalFilter.process(scalar), signedRate: nil,
                           axis: nil, energyFraction: nil, departureAllowed: departureAllowed)
        case .fixedAxisAngular:
            guard !fixedAxisInvalid else { return currentUpdate(filtered: nil, signedRate: nil, energyFraction: nil) }
            return observeAngular(sample, reference: reference, axis: V6ProfileConstants.fixedAngularAxis,
                                  energyFraction: nil, departureAllowed: departureAllowed)
        case .adaptiveAxis:
            return observeAdaptive(sample, reference: reference, departureAllowed: departureAllowed)
        }
    }

    private mutating func observeAngular(_ sample: ResampledMotionSample, reference: V2ReferenceMeasurements,
                                         axis: ExperimentalVector3, energyFraction: Double?,
                                         departureAllowed: Bool) -> V6DetectorUpdate {
        guard let angular = profile.identity.angular,
              V6VectorMath.planarMagnitude(reference.referenceGravity, axis: axis) >= angular.minimumPlanarMagnitude,
              V6VectorMath.planarMagnitude(sample.gravity, axis: axis) >= angular.minimumPlanarMagnitude,
              let wrapped = V6VectorMath.gravityPlaneAngle(from: reference.referenceGravity, to: sample.gravity, axis: axis),
              let continuous = angle.observe(wrapped, maximumDelta: angular.maximumSampleDelta) else {
            return fail(.angularReferenceAmbiguous, sample: sample)
        }
        let signal = signalFilter.process(profile.identity.polarity * continuous)
        let signedRate = rateFilter.process(-profile.identity.polarity * V6VectorMath.dot(sample.rotationRate, axis))
        return consume(sample, signal: signal, signedRate: signedRate, axis: axis,
                       energyFraction: energyFraction, departureAllowed: departureAllowed)
    }

    private mutating func observeAdaptive(_ sample: ResampledMotionSample, reference: V2ReferenceMeasurements,
                                          departureAllowed: Bool) -> V6DetectorUpdate {
        guard let configuration = profile.identity.adaptiveAxis else { return fail(.insufficientAxisEnergy, sample: sample) }
        if let recoveryStart {
            let near = V6VectorMath.angularDistance(sample.gravity, reference.referenceGravity) <= configuration.maximumReferenceDistance
            if near && sample.rotationRate.magnitude <= profile.identity.localCycle.gyroscopeQuietThreshold {
                if sample.sourceTimestamp - recoveryStart + 1e-9 >= configuration.recoveryDwell {
                    self.recoveryStart = nil; axisBuffer = [sample]
                }
            } else { self.recoveryStart = sample.sourceTimestamp }
            return currentUpdate(filtered: nil, signedRate: nil, energyFraction: nil)
        }

        if frozenAxis == nil {
            guard departureAllowed else { axisBuffer = [sample]; return currentUpdate(filtered: nil, signedRate: nil, energyFraction: nil) }
            axisBuffer.append(sample)
            axisBuffer.removeAll { sample.sourceTimestamp - $0.sourceTimestamp > configuration.maximumDuration }
            if sample.rotationRate.magnitude >= configuration.movementRate { unresolvedMotionSeen = true }
            if unresolvedMotionSeen, sample.rotationRate.magnitude < configuration.movementRate,
               V6VectorMath.angularDistance(sample.gravity, reference.referenceGravity) <= configuration.maximumReferenceDistance {
                unresolvedQuietStart = unresolvedQuietStart ?? sample.sourceTimestamp
                if sample.sourceTimestamp - unresolvedQuietStart! + 1e-9 >= configuration.recoveryDwell {
                    lastRejection = .insufficientExcursion
                    clearAdaptiveCandidate(); axisBuffer = [sample]
                    return currentUpdate(filtered: nil, signedRate: nil, energyFraction: nil)
                }
            } else { unresolvedQuietStart = nil }
            let moving = axisBuffer.filter { $0.rotationRate.magnitude >= configuration.movementRate }
            guard let first = moving.first else {
                axisBuffer.removeAll { sample.sourceTimestamp - $0.sourceTimestamp > 0.20 }
                return currentUpdate(filtered: nil, signedRate: nil, energyFraction: nil)
            }
            unresolvedQuietStart = nil
            let duration = sample.sourceTimestamp - first.sourceTimestamp
            guard duration >= configuration.minimumDuration,
                  V6VectorMath.angularDistance(first.gravity, reference.referenceGravity) <= configuration.maximumReferenceDistance,
                  let estimate = V6AxisEstimator.estimate(moving, sampleRate: profile.identity.sampleRate),
                  estimate.travel >= configuration.minimumTravel,
                  estimate.energyFraction >= configuration.minimumEnergyFraction,
                  estimate.coherence >= configuration.minimumDirectionCoherence else {
                previousEstimate = nil; stableEstimateCount = 0
                return currentUpdate(filtered: nil, signedRate: nil, energyFraction: nil)
            }
            if let previousEstimate,
               V6VectorMath.angularDistance(previousEstimate.axis, estimate.axis) <= configuration.maximumAxisChange {
                stableEstimateCount += 1
            } else { stableEstimateCount = 1 }
            previousEstimate = estimate
            guard stableEstimateCount >= 3,
                  let opening = V6VectorMath.gravityPlaneAngle(from: reference.referenceGravity,
                                                               to: sample.gravity, axis: estimate.axis),
                  -opening >= profile.identity.localCycle.leaveStart else {
                return currentUpdate(filtered: nil, signedRate: nil, energyFraction: estimate.energyFraction)
            }
            frozenAxis = estimate.axis; angle = .init(); signalFilter.reset(); rateFilter.reset()
            segmenter.reset(); candidateSamples = axisBuffer
            if let seedAngle = V6VectorMath.gravityPlaneAngle(from: reference.referenceGravity,
                                                              to: axisBuffer[0].gravity, axis: estimate.axis) {
                segmenter.seedQualifiedBottom(signal: -seedAngle, timestamp: axisBuffer[0].sourceTimestamp,
                                              gyro: axisBuffer[0].rotationRate.magnitude,
                                              interpolated: axisBuffer[0].interpolationStatus == .interpolated)
            }
            let replay = axisBuffer; axisBuffer.removeAll(keepingCapacity: true)
            var update = currentUpdate(filtered: nil, signedRate: nil, energyFraction: estimate.energyFraction)
            for frame in replay { update = observeAngular(frame, reference: reference, axis: estimate.axis,
                                                          energyFraction: estimate.energyFraction,
                                                          departureAllowed: departureAllowed) }
            return update
        }

        candidateSamples.append(sample)
        return observeAngular(sample, reference: reference, axis: frozenAxis!,
                              energyFraction: previousEstimate?.energyFraction, departureAllowed: departureAllowed)
    }

    private mutating func consume(_ sample: ResampledMotionSample, signal: Double, signedRate: Double?,
                                  axis: ExperimentalVector3?, energyFraction: Double?,
                                  departureAllowed: Bool) -> V6DetectorUpdate {
        let externalReversal: Bool
        if profile.identity.algorithm == .adaptiveAxis, segmenter.state == .bottomPending,
           let axis, let returnTime = segmenter.returned?.time,
           let returnFrame = candidateSamples.min(by: { abs($0.sourceTimestamp - returnTime) < abs($1.sourceTimestamp - returnTime) }) {
            let pendingBand = max(0.01, profile.identity.localCycle.trainedSpan * 0.02)
            externalReversal = V6VectorMath.angularDistance(returnFrame.gravity, sample.gravity) >= pendingBand &&
                sample.rotationRate.magnitude >= (profile.identity.adaptiveAxis?.movementRate ?? 0.45) &&
                V6VectorMath.dot(sample.rotationRate, axis) >= -0.15
        } else { externalReversal = false }
        let result = segmenter.observe(signal: signal, timestamp: sample.sourceTimestamp,
                                       gyroMagnitude: sample.rotationRate.magnitude,
                                       interpolated: sample.interpolationStatus == .interpolated,
                                       departureAllowed: departureAllowed, signedRotationRate: signedRate,
                                       allowCarryover: profile.identity.algorithm != .adaptiveAxis,
                                       externalBottomReversal: externalReversal)
        if let rejection = result.rejection?.1 {
            lastRejection = rejection
            if profile.identity.algorithm == .adaptiveAxis {
                enterRecovery(at: sample.sourceTimestamp)
                return currentUpdate(filtered: signal, signedRate: signedRate, energyFraction: energyFraction)
            }
        }
        if let cycle = result.cycle {
            var fraction = energyFraction
            if let axis, profile.identity.algorithm == .adaptiveAxis {
                let owned = candidateSamples.filter { $0.sourceTimestamp >= cycle.startTime && $0.sourceTimestamp <= cycle.completionTime }
                let energy = owned.reduce(into: (along: 0.0, total: 0.0)) { partial, frame in
                    let total = V6VectorMath.dot(frame.rotationRate, frame.rotationRate)
                    partial.total += total
                    partial.along += pow(V6VectorMath.dot(frame.rotationRate, axis), 2)
                }
                fraction = energy.total > 1e-9 ? energy.along / energy.total : 0
                if fraction! < (profile.identity.adaptiveAxis?.minimumCycleEnergyFraction ?? 0.65) {
                    lastRejection = .insufficientAxisEnergy; enterRecovery(at: sample.sourceTimestamp)
                    return currentUpdate(filtered: signal, signedRate: signedRate, energyFraction: fraction)
                }
            }
            events.append(.init(id: cycle.candidateID, setID: descriptor.setID, exercise: descriptor.exercise,
                                authorizationSource: descriptor.authorizationSource, profileID: descriptor.profileID,
                                dspContentHash: descriptor.dspContentHash, detectorEpoch: 0,
                                cycleSequence: events.count + 1, startTimestamp: cycle.startTime,
                                topTimestamp: cycle.topTime, completionTimestamp: cycle.completionTime,
                                detectionTimestamp: cycle.detectionTime, bottom: cycle.bottom, top: cycle.top,
                                returned: cycle.returned, outboundArea: cycle.outboundArea,
                                returnArea: cycle.returnArea, committed: false, rejectionReason: nil,
                                movementAxis: axis, axisEnergyFraction: fraction))
            lastRejection = nil
            if profile.identity.algorithm == .adaptiveAxis { clearAdaptiveCandidate() }
        }
        return currentUpdate(filtered: signal, signedRate: signedRate, energyFraction: energyFraction)
    }

    private mutating func fail(_ reason: V2RejectionReason, sample: ResampledMotionSample) -> V6DetectorUpdate {
        lastRejection = reason
        if profile.identity.algorithm == .adaptiveAxis { enterRecovery(at: sample.sourceTimestamp) }
        else {
            segmenter.reset(discontinuity: true); signalFilter.reset(); rateFilter.reset(); angle = .init()
            fixedAxisInvalid = true
        }
        return currentUpdate(filtered: nil, signedRate: nil, energyFraction: nil)
    }

    private mutating func enterRecovery(at timestamp: Double) {
        segmenter.reset(discontinuity: true); signalFilter.reset(); rateFilter.reset(); angle = .init()
        clearAdaptiveCandidate(); recoveryStart = timestamp
    }

    private mutating func clearAdaptiveCandidate() {
        frozenAxis = nil; previousEstimate = nil; stableEstimateCount = 0
        unresolvedQuietStart = nil; unresolvedMotionSeen = false
        axisBuffer.removeAll(keepingCapacity: true); candidateSamples.removeAll(keepingCapacity: true)
    }

    private func currentUpdate(filtered: Double?, signedRate: Double?, energyFraction: Double?) -> V6DetectorUpdate {
        .init(filteredSignal: filtered,
              diagnostics: .init(cycleState: phase.rawValue, candidateID: segmenter.candidateID,
                                 bottomQualified: segmenter.bottomQualified, estimatedAxis: frozenAxis,
                                 axisBufferDuration: axisBuffer.first.map { axisBuffer.last!.sourceTimestamp - $0.sourceTimestamp },
                                 axisEnergyFraction: energyFraction, unwrappedAngle: angle.previous == nil ? nil : angle.value,
                                 signedRotationRate: signedRate, rejectionReason: lastRejection))
    }
}

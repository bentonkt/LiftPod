import Foundation

struct NeutralReference: Codable, Sendable, Equatable {
    let initialScalar: Double
    var adaptedScalar: Double
    let attitude: ExperimentalQuaternion
    var adaptationUsed: Bool
}

struct DetectorRunResult: Sendable, Equatable {
    let candidates: [RepEvidence]
    let finalPhase: DetectorPhase
    let neutralReference: NeutralReference?
}

struct EndpointProgressDetector: Sendable {
    let profile: ExperimentalProfile
    let configuration: ExperimentalV1Configuration

    func run(samples: [ResampledMotionSample]) -> DetectorRunResult {
        var candidates: [RepEvidence] = []
        var filter = ScalarBiquadFilter(coefficients: configuration.filter)
        let extractor = ScalarSignalExtractor(profile: profile)
        var neutral = acquireNeutral(samples: samples, extractor: extractor)
        guard neutral != nil else {
            return DetectorRunResult(candidates: [], finalPhase: .unarmed, neutralReference: nil)
        }
        filter.reset()

        var phase: DetectorPhase = .unarmed
        var persistence = 0
        var startTime = 0.0
        var turnaround: Double?
        var lastEpoch = samples.first?.epoch ?? 0
        var accumulator = EvidenceAccumulator()
        var candidateSequence = 0
        var refractoryUntil = -Double.infinity

        for sample in samples {
            guard sample.sourceTimestamp >= (neutral?.acquiredAt ?? .infinity) else { continue }
            if sample.epoch != lastEpoch {
                if phase != .unarmed && phase != .startConfirmed {
                    candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                epoch: lastEpoch, accumulator: accumulator,
                                                completion: sample.sourceTimestamp, reason: .discontinuity))
                    candidateSequence += 1
                }
                filter.reset()
                phase = .unarmed
                persistence = 0
                accumulator = EvidenceAccumulator()
                lastEpoch = sample.epoch
            }
            guard sample.sensorSide == profile.sensorSide else { continue }
            let raw = extractor.value(for: sample, neutralReference: neutral?.adaptedScalar)
            let signal = filter.process(raw)

            if sample.sourceTimestamp < refractoryUntil {
                phase = .refractory
                continue
            } else if phase == .refractory {
                phase = .unarmed
            }

            switch phase {
            case .unarmed:
                if signal <= configuration.endpoint.startUpper {
                    persistence = max(0, persistence) + 1
                } else if signal >= configuration.endpoint.apexLower {
                    persistence = min(0, persistence) - 1
                    if -persistence >= configuration.transitionPersistenceSamples {
                        var invalid = EvidenceAccumulator(start: sample.sourceTimestamp - Double(-persistence - 1) * configuration.outputInterval)
                        invalid.observe(signal: signal, sample: sample)
                        candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                    epoch: sample.epoch, accumulator: invalid,
                                                    completion: sample.sourceTimestamp, reason: .invalidOrdering))
                        candidateSequence += 1
                        persistence = 0
                    }
                } else {
                    persistence = 0
                }
                if persistence >= configuration.transitionPersistenceSamples {
                    phase = .startConfirmed
                    startTime = sample.sourceTimestamp - Double(persistence - 1) * configuration.outputInterval
                    accumulator = EvidenceAccumulator(start: startTime)
                    accumulator.observe(signal: signal, sample: sample)
                    persistence = 0
                }
            case .startConfirmed:
                accumulator.observe(signal: signal, sample: sample)
                persistence = signal >= configuration.endpoint.leaveStart ? persistence + 1 : 0
                if persistence >= configuration.transitionPersistenceSamples,
                   sample.sourceTimestamp - startTime >= configuration.minimumPhaseDuration {
                    phase = .outbound
                    persistence = 0
                }
            case .outbound:
                accumulator.observe(signal: signal, sample: sample)
                if signal >= configuration.endpoint.apexLower {
                    persistence += 1
                    if persistence >= configuration.transitionPersistenceSamples,
                       accumulator.excursion >= configuration.endpoint.minimumExcursion,
                       sample.sourceTimestamp - startTime >= configuration.minimumPhaseDuration {
                        phase = .turnaroundConfirmed
                        turnaround = sample.sourceTimestamp
                        persistence = 0
                    }
                } else if signal <= configuration.endpoint.startUpper {
                    persistence += 1
                    if persistence >= configuration.transitionPersistenceSamples {
                        candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                    epoch: sample.epoch, accumulator: accumulator,
                                                    completion: sample.sourceTimestamp, reason: .insufficientExcursion))
                        candidateSequence += 1
                        phase = .unarmed
                        persistence = 0
                    }
                } else {
                    persistence = 0
                }
            case .turnaroundConfirmed:
                accumulator.observe(signal: signal, sample: sample)
                let pause = sample.sourceTimestamp - (turnaround ?? sample.sourceTimestamp)
                if pause > configuration.maximumTurnaroundPause {
                    candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                epoch: sample.epoch, accumulator: accumulator,
                                                completion: sample.sourceTimestamp, reason: .excessivePause,
                                                turnaround: turnaround))
                    candidateSequence += 1
                    phase = .unarmed
                } else {
                    persistence = signal <= configuration.endpoint.leaveApex ? persistence + 1 : 0
                    if persistence >= configuration.transitionPersistenceSamples,
                       pause >= configuration.minimumPhaseDuration {
                        phase = .returning
                        persistence = 0
                    }
                }
            case .returning:
                accumulator.observe(signal: signal, sample: sample)
                persistence = signal <= configuration.endpoint.startUpper ? persistence + 1 : 0
                if persistence >= configuration.transitionPersistenceSamples {
                    let duration = sample.sourceTimestamp - startTime
                    let reason: RepRejectionReason? = duration < configuration.minimumCycleDuration ? .insufficientDuration :
                        (duration > configuration.maximumCycleDuration ? .excessiveDuration : nil)
                    let evidence = makeEvidence(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                               epoch: sample.epoch, accumulator: accumulator,
                                               turnaround: turnaround, completion: sample.sourceTimestamp,
                                               disposition: reason == nil ? .provisional : .rejected, reason: reason,
                                               adaptedNeutral: neutral?.adaptationUsed == true)
                    candidates.append(evidence)
                    candidateSequence += 1
                    if reason == nil, var reference = neutral {
                        let span = max(1e-9, configuration.endpoint.apexLower - configuration.endpoint.startUpper)
                        let limit = span * configuration.neutral.adaptationLimitFraction
                        let proposed = reference.adaptedScalar + configuration.neutral.adaptationFraction *
                            (extractor.value(for: sample) - reference.adaptedScalar)
                        reference.adaptedScalar = min(reference.initialScalar + limit,
                                                      max(reference.initialScalar - limit, proposed))
                        reference.adaptationUsed = reference.adaptedScalar != reference.initialScalar
                        neutral = reference
                        refractoryUntil = sample.sourceTimestamp + configuration.refractoryInterval
                        phase = .refractory
                    } else {
                        phase = .unarmed
                    }
                    persistence = 0
                    turnaround = nil
                }
            default:
                break
            }
        }
        if let last = samples.last, phase == .outbound || phase == .turnaroundConfirmed || phase == .returning {
            candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                        epoch: last.epoch, accumulator: accumulator,
                                        completion: last.sourceTimestamp,
                                        reason: phase == .outbound ? .insufficientExcursion : .invalidOrdering,
                                        turnaround: turnaround))
        }
        return DetectorRunResult(candidates: candidates, finalPhase: phase, neutralReference: neutral.map(\.reference))
    }

    private func acquireNeutral(
        samples: [ResampledMotionSample],
        extractor: ScalarSignalExtractor
    ) -> AcquiredNeutral? {
        var accepted: [(Double, ExperimentalQuaternion)] = []
        var start: Double?
        var epoch: Int?
        for sample in samples where sample.sensorSide == profile.sensorSide {
            if epoch != sample.epoch { accepted.removeAll(); start = nil; epoch = sample.epoch }
            let signal = extractor.value(for: sample)
            let activity = max(sample.userAcceleration.magnitude, 0.1 * sample.rotationRate.magnitude)
            let valid = activity <= configuration.neutral.quietActivityThreshold &&
                signal >= configuration.neutral.permittedSignalMinimum &&
                signal <= configuration.neutral.permittedSignalMaximum
            if !valid { accepted.removeAll(); start = nil; continue }
            start = start ?? sample.sourceTimestamp
            accepted.append((signal, sample.attitude))
            if sample.sourceTimestamp - (start ?? sample.sourceTimestamp) >= configuration.neutral.requiredDwell {
                let sorted = accepted.map(\.0).sorted()
                let median = sorted.count.isMultiple(of: 2)
                    ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
                    : sorted[sorted.count / 2]
                let attitude = averageAttitudes(accepted.map(\.1))
                return AcquiredNeutral(reference: NeutralReference(initialScalar: median, adaptedScalar: median,
                                                                    attitude: attitude, adaptationUsed: false),
                                       acquiredAt: sample.sourceTimestamp)
            }
        }
        return nil
    }

    private func averageAttitudes(_ attitudes: [ExperimentalQuaternion]) -> ExperimentalQuaternion {
        guard let first = attitudes.first else { return .init(w: 1, x: 0, y: 0, z: 0) }
        var total = ExperimentalQuaternion(w: 0, x: 0, y: 0, z: 0)
        for attitude in attitudes {
            let aligned = first.dot(attitude) < 0 ? attitude.negated() : attitude
            total = .init(w: total.w + aligned.w, x: total.x + aligned.x,
                          y: total.y + aligned.y, z: total.z + aligned.z)
        }
        return total.normalized() ?? first
    }
}

private struct AcquiredNeutral {
    var reference: NeutralReference
    let acquiredAt: Double
    var initialScalar: Double { reference.initialScalar }
    var adaptedScalar: Double {
        get { reference.adaptedScalar }
        set { reference.adaptedScalar = newValue }
    }
    var adaptationUsed: Bool {
        get { reference.adaptationUsed }
        set { reference.adaptationUsed = newValue }
    }
}

struct BiphasicCycleDetector: Sendable {
    let profile: ExperimentalProfile
    let configuration: ExperimentalV1Configuration

    func run(samples: [ResampledMotionSample]) -> DetectorRunResult {
        let extractor = ScalarSignalExtractor(profile: profile)
        var filter = ScalarBiquadFilter(coefficients: configuration.filter)
        var candidates: [RepEvidence] = []
        var phase: DetectorPhase = .unarmed
        var persistence = 0
        var quietStart: Double?
        var startTime = 0.0
        var turnaround: Double?
        var accumulator = EvidenceAccumulator()
        var candidateSequence = 0
        var lastEpoch = samples.first?.epoch ?? 0
        var refractoryUntil = -Double.infinity

        for sample in samples {
            if sample.epoch != lastEpoch {
                if phase == .positiveLobe || phase == .negativeLobe {
                    candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                epoch: lastEpoch, accumulator: accumulator,
                                                completion: sample.sourceTimestamp, reason: .discontinuity,
                                                turnaround: turnaround))
                    candidateSequence += 1
                }
                filter.reset(); phase = .unarmed; persistence = 0; quietStart = nil
                accumulator = EvidenceAccumulator(); lastEpoch = sample.epoch
            }
            guard sample.sensorSide == profile.sensorSide else { continue }
            let rawSignal = extractor.value(for: sample)
            let signal = filter.process(rawSignal)
            if sample.sourceTimestamp < refractoryUntil { phase = .refractory; continue }
            if phase == .refractory { phase = .unarmed; quietStart = nil }

            switch phase {
            case .unarmed:
                guard signal >= configuration.biphasic.permittedInitialMinimum,
                      signal <= configuration.biphasic.permittedInitialMaximum else {
                    quietStart = nil
                    continue
                }
                if abs(signal) <= configuration.biphasic.quietBand {
                    quietStart = quietStart ?? sample.sourceTimestamp
                    persistence += 1
                    if persistence >= configuration.transitionPersistenceSamples,
                       sample.sourceTimestamp - (quietStart ?? sample.sourceTimestamp) >= configuration.biphasic.requiredQuietDuration {
                        phase = .quiet; persistence = 0
                    }
                } else { quietStart = nil; persistence = 0 }
            case .quiet:
                if signal >= configuration.biphasic.minimumProminence {
                    persistence += 1
                    if persistence >= configuration.transitionPersistenceSamples {
                        startTime = sample.sourceTimestamp - Double(persistence - 1) * configuration.outputInterval
                        accumulator = EvidenceAccumulator(start: startTime)
                        accumulator.observe(signal: signal, sample: sample)
                        phase = .positiveLobe; persistence = 0
                    }
                } else if signal <= -configuration.biphasic.minimumProminence {
                    persistence += 1
                    if persistence >= configuration.transitionPersistenceSamples {
                        accumulator = EvidenceAccumulator(start: sample.sourceTimestamp - Double(persistence - 1) * configuration.outputInterval)
                        accumulator.observe(signal: signal, sample: sample)
                        candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                    epoch: sample.epoch, accumulator: accumulator,
                                                    completion: sample.sourceTimestamp, reason: .invalidOrdering))
                        candidateSequence += 1; phase = .unarmed; persistence = 0; quietStart = nil
                    }
                } else { persistence = 0 }
            case .positiveLobe:
                accumulator.observe(signal: signal, sample: sample)
                let duration = sample.sourceTimestamp - startTime
                if duration > configuration.biphasic.maximumLobeDuration {
                    candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                epoch: sample.epoch, accumulator: accumulator,
                                                completion: sample.sourceTimestamp, reason: .sameSignOnly))
                    candidateSequence += 1; phase = .unarmed; persistence = 0; quietStart = nil
                } else if signal <= -configuration.biphasic.minimumProminence {
                    persistence += 1
                    if persistence >= configuration.transitionPersistenceSamples {
                        if duration < configuration.biphasic.minimumLobeDuration {
                            candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                        epoch: sample.epoch, accumulator: accumulator,
                                                        completion: sample.sourceTimestamp, reason: .insufficientDuration))
                            candidateSequence += 1; phase = .unarmed
                        } else if accumulator.positiveArea < configuration.biphasic.minimumLobeArea {
                            candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                        epoch: sample.epoch, accumulator: accumulator,
                                                        completion: sample.sourceTimestamp, reason: .insufficientArea))
                            candidateSequence += 1; phase = .unarmed
                        } else {
                            turnaround = sample.sourceTimestamp
                            phase = .negativeLobe
                        }
                        persistence = 0
                    }
                } else if abs(signal) <= configuration.biphasic.quietBand {
                    persistence += 1
                    if persistence >= configuration.transitionPersistenceSamples {
                        candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                    epoch: sample.epoch, accumulator: accumulator,
                                                    completion: sample.sourceTimestamp, reason: .invalidOrdering))
                        candidateSequence += 1; phase = .unarmed; persistence = 0
                    }
                } else { persistence = 0 }
            case .negativeLobe:
                accumulator.observe(signal: signal, sample: sample)
                let lobeDuration = sample.sourceTimestamp - (turnaround ?? sample.sourceTimestamp)
                if lobeDuration > configuration.biphasic.maximumLobeDuration {
                    candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                epoch: sample.epoch, accumulator: accumulator,
                                                completion: sample.sourceTimestamp, reason: .excessiveDuration,
                                                turnaround: turnaround))
                    candidateSequence += 1; phase = .unarmed; persistence = 0
                } else if abs(rawSignal) <= configuration.biphasic.quietBand {
                    quietStart = quietStart ?? sample.sourceTimestamp
                    persistence += 1
                    if persistence >= configuration.transitionPersistenceSamples,
                       sample.sourceTimestamp - (quietStart ?? sample.sourceTimestamp) >= configuration.biphasic.requiredQuietDuration {
                        let totalDuration = sample.sourceTimestamp - startTime
                        let reason: RepRejectionReason? = lobeDuration < configuration.biphasic.minimumLobeDuration ? .insufficientDuration :
                            (accumulator.negativeArea < configuration.biphasic.minimumLobeArea ? .insufficientArea :
                                (totalDuration < configuration.minimumCycleDuration ? .insufficientDuration :
                                    (totalDuration > configuration.maximumCycleDuration ? .excessiveDuration : nil)))
                        candidates.append(makeEvidence(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                                       epoch: sample.epoch, accumulator: accumulator,
                                                       turnaround: turnaround, completion: sample.sourceTimestamp,
                                                       disposition: reason == nil ? .provisional : .rejected, reason: reason))
                        candidateSequence += 1; persistence = 0; quietStart = nil
                        if reason == nil {
                            refractoryUntil = sample.sourceTimestamp + configuration.refractoryInterval
                            phase = .refractory
                        } else { phase = .unarmed }
                    }
                } else { persistence = 0; quietStart = nil }
            default: break
            }
        }
        if let last = samples.last, phase == .positiveLobe || phase == .negativeLobe {
            candidates.append(rejection(profile: profile, side: profile.sensorSide, sequence: candidateSequence,
                                        epoch: last.epoch, accumulator: accumulator,
                                        completion: last.sourceTimestamp,
                                        reason: phase == .positiveLobe ? .sameSignOnly : .invalidOrdering,
                                        turnaround: turnaround))
        }
        return DetectorRunResult(candidates: candidates, finalPhase: phase, neutralReference: nil)
    }
}

private struct EvidenceAccumulator {
    var start = 0.0
    var minimumSignal = Double.infinity
    var maximumSignal = -Double.infinity
    var positiveArea = 0.0
    var negativeArea = 0.0
    var interpolatedCount = 0
    var previousTime: Double?

    init(start: Double = 0) { self.start = start }
    mutating func observe(signal: Double, sample: ResampledMotionSample) {
        minimumSignal = min(minimumSignal, signal)
        maximumSignal = max(maximumSignal, signal)
        if let previousTime {
            let dt = max(0, sample.sourceTimestamp - previousTime)
            positiveArea += max(0, signal) * dt
            negativeArea += max(0, -signal) * dt
        }
        previousTime = sample.sourceTimestamp
        if sample.interpolationStatus == .interpolated { interpolatedCount += 1 }
    }
    var excursion: Double { maximumSignal - minimumSignal }
}

private func makeEvidence(
    profile: ExperimentalProfile,
    side: ExperimentalSensorSide,
    sequence: Int,
    epoch: Int,
    accumulator: EvidenceAccumulator,
    turnaround: Double?,
    completion: Double,
    disposition: CandidateDisposition,
    reason: RepRejectionReason?,
    adaptedNeutral: Bool = false
) -> RepEvidence {
    let minimum = accumulator.minimumSignal.isFinite ? accumulator.minimumSignal : 0
    let maximum = accumulator.maximumSignal.isFinite ? accumulator.maximumSignal : 0
    var flags: [RepQualityFlag] = []
    if accumulator.interpolatedCount > 0 { flags.append(.containsInterpolation) }
    if adaptedNeutral { flags.append(.adaptedNeutralUsed) }
    return RepEvidence(
        id: "\(profile.exercise.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-e\(epoch)-c\(sequence)",
        detectorVersion: ExperimentalAnalysisResult.detectorVersion,
        exercise: profile.exercise,
        sensorSide: side,
        startSourceTimestamp: accumulator.start,
        turnaroundTimestamp: turnaround,
        completionTimestamp: completion,
        detectionTimestamp: completion,
        duration: completion - accumulator.start,
        minimumSignal: minimum,
        maximumSignal: maximum,
        excursion: maximum - minimum,
        positiveArea: accumulator.positiveArea,
        negativeArea: accumulator.negativeArea,
        peakMagnitude: max(abs(minimum), abs(maximum)),
        interpolatedSampleCount: accumulator.interpolatedCount,
        detectorEpoch: epoch,
        qualityFlags: flags,
        disposition: disposition,
        rejectionReason: reason
    )
}

private func rejection(
    profile: ExperimentalProfile,
    side: ExperimentalSensorSide,
    sequence: Int,
    epoch: Int,
    accumulator: EvidenceAccumulator,
    completion: Double,
    reason: RepRejectionReason,
    turnaround: Double? = nil
) -> RepEvidence {
    makeEvidence(profile: profile, side: side, sequence: sequence, epoch: epoch, accumulator: accumulator,
                 turnaround: turnaround, completion: completion, disposition: .rejected, reason: reason)
}

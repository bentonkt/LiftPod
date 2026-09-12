import Foundation

struct V6CycleResult: Sendable, Equatable {
    let candidateID: String
    let bottom: Double
    let top: Double
    let returned: Double
    let startTime: Double
    let topTime: Double
    let completionTime: Double
    let detectionTime: Double
    let outboundArea: Double
    let returnArea: Double
    let interpolatedCount: Int
    let completionKind: V2BoundaryKind
}

struct V6SegmenterUpdate: Sendable {
    let cycle: V6CycleResult?
    let rejection: (String?, V2RejectionReason)?
}

struct V6QualifiedCycleSegmenter: Sendable {
    enum State: String, Sendable { case seekingBottom, ready, outbound, returning, bottomPending }
    private struct Point: Sendable {
        let time: Double
        let signal: Double
        let gyro: Double
        let interpolated: Bool
    }

    let profile: V2DSPProfile
    private var configuration: V2LocalCycleConfiguration { profile.identity.localCycle }
    private var timing: V2TimingConfiguration { profile.identity.timing }
    private var reversal: Double { max(0.01, configuration.trainedSpan * configuration.reversalDisplacementFraction) }
    private var pendingBand: Double { max(0.01, configuration.trainedSpan * 0.02) }

    private(set) var state: State = .seekingBottom
    private(set) var bottomQualified = false
    private(set) var recovering = false
    private(set) var candidateID: String?
    private(set) var bottom: (value: Double, time: Double)?
    private(set) var top: (value: Double, time: Double)?
    private(set) var returned: (value: Double, time: Double)?
    private var epoch = 0
    private var sequence = 0
    private var departure = 0.0
    private var cycle: [Point] = []
    private var preDeparture: [Point] = []
    private var evidenceRuns: [String: Int] = [:]
    private var quietSince: Double?
    private var quietValues: [Double] = []
    private var topQuietSince: Double?
    private var last: Point?
    private var previouslyAdmitted = false
    private var recoveryBottom: Point?
    private var recoveryTail: [Point] = []
    private var recoverySawReturn = false

    init(profile: V2DSPProfile) {
        self.profile = profile
    }

    mutating func reset(discontinuity: Bool = false) {
        if discontinuity { epoch += 1 }
        seek()
        recovering = false
        last = nil
        previouslyAdmitted = false
    }

    mutating func seedQualifiedBottom(signal: Double, timestamp: Double, gyro: Double, interpolated: Bool) {
        guard state == .seekingBottom, compatible(signal) else { return }
        bottom = (signal, timestamp)
        last = Point(time: timestamp, signal: signal, gyro: gyro, interpolated: interpolated)
        bottomQualified = true
        recovering = false
        state = .ready
    }

    mutating func observe(
        signal: Double,
        timestamp: Double,
        gyroMagnitude: Double,
        interpolated: Bool,
        departureAllowed: Bool,
        signedRotationRate: Double? = nil,
        allowCarryover: Bool = true,
        externalBottomReversal: Bool = false
    ) -> V6SegmenterUpdate {
        guard [signal, timestamp, gyroMagnitude].allSatisfy(\.isFinite) else {
            return reject(.nonFiniteEvidence)
        }
        let point = Point(time: timestamp, signal: signal, gyro: gyroMagnitude, interpolated: interpolated)
        let previous = last
        last = point
        let previousWasAdmitted = previouslyAdmitted
        previouslyAdmitted = departureAllowed

        let atBottom = evidence(state == .seekingBottom && compatible(signal) &&
            abs(signal - (previous?.signal ?? signal)) <= reversal, key: "bottom")
        let outwardDirection = profile.identity.angular.map { (signedRotationRate ?? 0) >= $0.minimumDirectionalRate } ?? true
        let returnDirection = profile.identity.angular.map { (signedRotationRate ?? 0) <= -$0.minimumDirectionalRate } ?? true
        let leaving = evidence(state == .ready && departureAllowed && bottomQualified && outwardDirection &&
            signal - (bottom?.value ?? signal) >= configuration.leaveStart, key: "departure")
        let turning = evidence(state == .outbound && returnDirection &&
            (top?.value ?? signal) - signal >= reversal, key: "top")
        let bouncing = evidence((state == .returning || state == .bottomPending) &&
            signal - (returned?.value ?? signal) >= configuration.leaveStart, key: "ambiguous")
        let nextLeg = evidence(state == .bottomPending &&
            ((outwardDirection && signal - (returned?.value ?? signal) >= reversal) || externalBottomReversal),
            key: "nextLeg")

        if candidateID != nil {
            cycle.append(point)
            if timestamp - departure > timing.maximumCycleDuration { return reject(.invalidDuration) }
        }

        switch state {
        case .seekingBottom:
            if atBottom {
                bottom = (signal, timestamp)
                bottomQualified = true
                recovering = false
                state = .ready
                evidenceRuns.removeAll()
                recoveryBottom = nil; recoveryTail.removeAll(); recoverySawReturn = false
            } else if profile.identity.algorithm == .gravityTilt {
                // A quick returned valley need not contain three still samples.
                // Qualify it from observed return plus a persistent new departure,
                // retaining the valley samples rather than stitching the rejected top.
                if compatible(signal), departureAllowed {
                    if let bottom = recoveryBottom, timestamp - bottom.time > timing.maximumCycleDuration {
                        recoveryBottom = nil; recoveryTail.removeAll(); recoverySawReturn = false
                        evidenceRuns["recoveryDeparture"] = 0
                    }
                    if let previous, signal < previous.signal { recoverySawReturn = true }
                    if recoveryBottom == nil || signal < recoveryBottom!.signal {
                        recoveryBottom = point; recoveryTail = [point]
                    } else { recoveryTail.append(point) }
                    if let bottom = recoveryBottom,
                       evidence(recoverySawReturn && signal - bottom.signal >= configuration.leaveStart,
                                key: "recoveryDeparture") {
                        self.bottom = (bottom.signal, bottom.time)
                        bottomQualified = true; recovering = false
                        let tail = recoveryTail
                        recoveryBottom = nil; recoveryTail.removeAll(); recoverySawReturn = false
                        begin(tail)
                    }
                } else {
                    recoveryBottom = nil; recoveryTail.removeAll(); recoverySawReturn = false
                    evidenceRuns["recoveryDeparture"] = 0
                }
            }
        case .ready:
            if signal < -configuration.trainedSpan * configuration.maximumDeeperReturnFraction { seek(); break }
            if let current = bottom, compatible(signal), signal <= current.value {
                bottom = (signal, timestamp)
                preDeparture.removeAll()
            }
            if !departureAllowed {
                preDeparture.removeAll(); evidenceRuns["departure"] = 0; break
            }
            if let bottom, signal - bottom.value > reversal {
                if preDeparture.isEmpty, previousWasAdmitted, let previous { preDeparture.append(previous) }
                preDeparture.append(point)
                let maximumDuration = timing.maximumCycleDuration
                preDeparture.removeAll { timestamp - $0.time > maximumDuration }
            } else {
                preDeparture.removeAll()
            }
            if leaving { begin(preDeparture.isEmpty ? [point] : preDeparture) }
        case .outbound:
            if top == nil || signal > top!.value { top = (signal, timestamp) }
            guard let bottom, let top else { break }
            let enough = top.value - bottom.value >= configuration.minimumOutboundExcursion
            if profile.identity.algorithm == .gravityTilt, !enough, turning {
                return reject(.insufficientExcursion)
            }
            let lowMotion = enough && gyroMagnitude <= configuration.gyroscopeQuietThreshold &&
                abs(signal - (previous?.signal ?? signal)) <= reversal && top.value - signal <= reversal
            if lowMotion { topQuietSince = topQuietSince ?? timestamp } else { topQuietSince = nil }
            if let topQuietSince, timestamp - topQuietSince > timing.maximumTurnaroundPause {
                return reject(.excessivePause)
            }
            if enough && turning && top.time - departure >= timing.minimumPhaseDuration {
                returned = (signal, timestamp)
                state = .returning
                evidenceRuns.removeAll()
            } else if evidence(top.value - bottom.value >= configuration.leaveStart &&
                signal <= bottom.value + configuration.startUpper &&
                timestamp - departure >= timing.minimumPhaseDuration, key: "partial") {
                return reject(.insufficientExcursion)
            }
        case .returning, .bottomPending:
            if returned == nil || signal < returned!.value { returned = (signal, timestamp) }
            guard let bottom, let top, let returned else { break }
            let credible = V6QualifiedCycleSegmenter.credibleReturn(
                bottom: bottom.value, top: top.value, returned: returned.value, configuration: configuration
            )
            if !credible {
                quietSince = nil; quietValues.removeAll(); state = .returning
                if bouncing { return reject(.ambiguousReversal) }
                break
            }
            if state == .returning { state = .bottomPending; evidenceRuns["nextLeg"] = 0 }
            let near = compatible(signal) && abs(signal - returned.value) <= pendingBand
            if near && gyroMagnitude <= configuration.gyroscopeQuietThreshold {
                quietValues.append(signal)
                if (quietValues.max() ?? signal) - (quietValues.min() ?? signal) > pendingBand {
                    quietValues = [signal]; quietSince = timestamp
                } else {
                    quietSince = quietSince ?? timestamp
                }
            } else {
                quietSince = nil; quietValues.removeAll()
            }
            let settled = quietSince.map { timestamp - $0 + 1e-9 >= configuration.returnSettlingDuration } ?? false
            if settled || nextLeg {
                return complete(at: timestamp, carry: nextLeg && departureAllowed && allowCarryover,
                                kind: nextLeg ? .continuousReversal : .stationary)
            }
            if !near && signal - returned.value < reversal {
                state = .returning; quietSince = nil; quietValues.removeAll()
            }
        }
        return .init(cycle: nil, rejection: nil)
    }

    static func credibleReturn(bottom: Double, top: Double, returned: Double,
                               configuration: V2LocalCycleConfiguration) -> Bool {
        let outbound = top - bottom
        let inward = top - returned
        guard outbound > 0 else { return false }
        return inward >= configuration.minimumReturnExcursion &&
            inward / outbound >= configuration.minimumReturnFraction &&
            returned <= configuration.trainedSpan * configuration.maximumPositiveBottomOffsetFraction &&
            returned >= -configuration.trainedSpan * configuration.maximumDeeperReturnFraction
    }

    private func compatible(_ value: Double) -> Bool {
        value <= configuration.trainedSpan * configuration.maximumPositiveBottomOffsetFraction &&
            value >= -configuration.trainedSpan * configuration.maximumDeeperReturnFraction
    }

    private mutating func evidence(_ condition: Bool, key: String) -> Bool {
        evidenceRuns[key] = condition ? (evidenceRuns[key] ?? 0) + 1 : 0
        return (evidenceRuns[key] ?? 0) >= timing.persistenceSamples
    }

    private mutating func begin(_ points: [Point]) {
        sequence += 1
        candidateID = "\(profile.contentHash)-\(epoch)-\(sequence)"
        departure = points[0].time
        cycle = points
        var maximum = points[0]
        for point in points.dropFirst() where point.signal > maximum.signal { maximum = point }
        top = (maximum.signal, maximum.time)
        returned = nil
        topQuietSince = nil
        state = .outbound
        evidenceRuns.removeAll(); preDeparture.removeAll(); quietSince = nil; quietValues.removeAll()
    }

    private mutating func seek() {
        state = .seekingBottom; recovering = true; bottomQualified = false; candidateID = nil
        bottom = nil; top = nil; returned = nil; cycle.removeAll(keepingCapacity: true)
        preDeparture.removeAll(keepingCapacity: true); evidenceRuns.removeAll()
        quietSince = nil; quietValues.removeAll(); topQuietSince = nil
        recoveryBottom = nil; recoveryTail.removeAll(); recoverySawReturn = false
    }

    private mutating func reject(_ reason: V2RejectionReason) -> V6SegmenterUpdate {
        let rejectedID = candidateID
        seek()
        return .init(cycle: nil, rejection: (rejectedID, reason))
    }

    private mutating func complete(at detectionTime: Double, carry: Bool,
                                   kind: V2BoundaryKind) -> V6SegmenterUpdate {
        guard let candidateID, let bottom, let top, let returned else { return reject(.invalidOrdering) }
        let owned = cycle.filter { $0.time <= returned.time }
        var outboundArea = 0.0, returnArea = 0.0
        for (left, right) in zip(owned, owned.dropFirst()) {
            let dt = right.time - left.time
            if right.time <= top.time { outboundArea += max(0, right.signal - bottom.value) * dt }
            else { returnArea += max(0, top.value - right.signal) * dt }
        }
        let result = V6CycleResult(
            candidateID: candidateID, bottom: bottom.value, top: top.value, returned: returned.value,
            startTime: departure, topTime: top.time, completionTime: returned.time, detectionTime: detectionTime,
            outboundArea: outboundArea, returnArea: returnArea,
            interpolatedCount: owned.filter(\.interpolated).count, completionKind: kind
        )
        if let reason = validate(result) { return reject(reason) }
        let successor = cycle.filter { $0.time >= returned.time }
        seek(); recovering = false; self.bottom = (returned.value, returned.time); bottomQualified = true; state = .ready
        if carry, successor.count > 1 {
            if profile.identity.algorithm == .gravityTilt {
                // A confirmed bottom reversal is not yet a qualified departure.
                // Retain its samples, but require the usual hysteresis before
                // creating a successor. Small settling bumps must not own a top.
                preDeparture = successor
            } else { begin(successor) }
        }
        return .init(cycle: result, rejection: nil)
    }

    private func validate(_ cycle: V6CycleResult) -> V2RejectionReason? {
        let duration = cycle.completionTime - cycle.startTime
        guard cycle.startTime < cycle.topTime, cycle.topTime <= cycle.completionTime else { return .invalidOrdering }
        guard duration >= timing.minimumCycleDuration, duration <= timing.maximumCycleDuration,
              cycle.topTime - cycle.startTime >= timing.minimumPhaseDuration,
              cycle.completionTime - cycle.topTime >= timing.minimumPhaseDuration else { return .invalidDuration }
        guard cycle.top - cycle.bottom >= configuration.minimumOutboundExcursion else { return .insufficientExcursion }
        guard Self.credibleReturn(bottom: cycle.bottom, top: cycle.top, returned: cycle.returned,
                                  configuration: configuration) else { return .incompleteReturn }
        return nil
    }
}

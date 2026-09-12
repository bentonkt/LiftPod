import CryptoKit
import Foundation

/// Independent of detector profiles and candidate identity. No values flow back into counting.
struct RepMetricsConfiguration: Codable, Sendable, Equatable {
    var version = "vertical-metrics-v1"
    var accelerationSign = -1.0
    var standardGravity = 9.80665
    var filter = BiquadConfiguration.v2Fixed4Hz
    var sampleRate = 50.0
    var maximumUniformInterval = 0.021
    var minimumGravityMagnitude = 0.8
    var maximumGravityMagnitude = 1.2
    var maximumCycleDuration = 8.0
    var historyDuration = 12.0
    var quietDuration = 0.20
    var quietAccelerationG = 0.05
    var quietGyro = 0.35
    var quietGravityVariationG = 0.04
    var startLookback = 1.0
    var endLookback = 0.35
    var endLookahead = 2.0
    var filterSettling = 0.08
    var maximumVelocityCorrection = 1.2
    var maximumEquivalentBias = 0.35
    var maximumVerticalClosure = 0.25
    var maximumQuietSpeed = 0.15
    var movementSpeed = 0.04
    var pauseSpeed = 0.08
    var minimumPauseDuration = 0.08
    var minimumLegDuration = 0.20
    var turnaroundTolerance = 0.40
    var maximumOppositeTravelFraction = 0.20
    var minimumBaselineSpeed = 0.10
    var peakWindowSamples = 3

    // V2-only values remain optional so synthesized Codable omits them for V1. This is
    // intentional: the shipped V1 JSON and content hash must remain byte-for-byte stable.
    var initialVelocityStandardDeviation: Double?
    var minimumInitialBiasStandardDeviation: Double?
    var accelerationNoiseStandardDeviation: Double?
    var biasRandomWalkStandardDeviation: Double?
    var stationaryVelocityObservationStandardDeviation: Double?
    var reversalVelocityObservationBaseStandardDeviation: Double?
    var reversalAccelerationStandardDeviationScale: Double?
    var maximumReversalVelocityInnovation: Double?
    var maximumReversalNormalizedInnovationSquared: Double?
    var reversalSearchTolerance: Double?
    var reversalConfirmationLookahead: Double?
    var finalizationDeadline: Double?
    var maximumVelocityStandardDeviation: Double?
    var maximumAnchorAge: Double?
    var boundaryPerturbation: Double?
    var maximumBoundaryPerturbationSpeed: Double?
    var maximumBoundaryPerturbationFraction: Double?
    var movementInterruptionMergeDuration: Double?
    /// Nil preserves the original V2 boundary resolver for archived configurations.
    var boundaryHandoff: RepBoundaryHandoffConfiguration?
    var devicePath: DevicePathMetricsConfiguration?

    static var devicePath3D: Self {
        var value = continuousV2
        value.version = "device-path-metrics-v1"
        value.boundaryHandoff = nil
        value.devicePath = .init()
        return value
    }

    static var cyclicDevicePath3D: Self {
        var value = devicePath3D
        value.version = "device-path-metrics-v2"
        value.devicePath?.cyclic = .init()
        return value
    }

    static var continuousV2: Self {
        var value = Self()
        value.version = "vertical-metrics-v2"
        value.initialVelocityStandardDeviation = 0.02
        value.minimumInitialBiasStandardDeviation = 0.03
        value.accelerationNoiseStandardDeviation = 0.5
        value.biasRandomWalkStandardDeviation = 0.02
        value.stationaryVelocityObservationStandardDeviation = 0.02
        value.reversalVelocityObservationBaseStandardDeviation = 0.08
        value.reversalAccelerationStandardDeviationScale = 0.04
        value.maximumReversalVelocityInnovation = 0.20
        value.maximumReversalNormalizedInnovationSquared = 9
        value.reversalSearchTolerance = 0.25
        value.reversalConfirmationLookahead = 0.20
        value.finalizationDeadline = 0.60
        value.maximumVelocityStandardDeviation = 0.15
        value.maximumAnchorAge = 8
        value.boundaryPerturbation = 0.04
        value.maximumBoundaryPerturbationSpeed = 0.10
        value.maximumBoundaryPerturbationFraction = 0.15
        value.movementInterruptionMergeDuration = 0.08
        value.boundaryHandoff = .init()
        return value
    }

    var contentHash: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validated() throws -> Self {
        let positive = [standardGravity, sampleRate, maximumUniformInterval, minimumGravityMagnitude,
                        maximumGravityMagnitude, maximumCycleDuration, minimumPauseDuration,
                        historyDuration, quietDuration, quietAccelerationG, quietGyro,
                        quietGravityVariationG, startLookback, endLookback, endLookahead,
                        filterSettling, maximumVelocityCorrection, maximumEquivalentBias,
                        maximumVerticalClosure, maximumQuietSpeed, movementSpeed, pauseSpeed,
                        minimumLegDuration, turnaroundTolerance, minimumBaselineSpeed]
        guard ["vertical-metrics-v1", "vertical-metrics-v2", "device-path-metrics-v1", "device-path-metrics-v2"].contains(version), [-1.0, 1.0].contains(accelerationSign),
              positive.allSatisfy({ $0.isFinite && $0 > 0 }), (12...60).contains(historyDuration),
              sampleRate == 50, (0.02...0.021).contains(maximumUniformInterval),
              minimumGravityMagnitude < maximumGravityMagnitude, maximumCycleDuration <= 8,
              endLookahead <= 2, startLookback <= 1, peakWindowSamples >= 3, peakWindowSamples <= 25,
              maximumOppositeTravelFraction.isFinite, (0...0.5).contains(maximumOppositeTravelFraction),
              filter == .v2Fixed4Hz else { throw V2Error.invalidLifecycle("invalid metrics configuration") }
        if version != "vertical-metrics-v1" {
            if version == "device-path-metrics-v1" || version == "device-path-metrics-v2" {
                guard let devicePath, boundaryHandoff == nil, peakWindowSamples % 2 == 1 else { throw V2Error.invalidLifecycle("missing or invalid 3D metrics configuration") }
                try devicePath.validate()
                guard (version == "device-path-metrics-v2") == (devicePath.cyclic != nil) else {
                    throw V2Error.invalidLifecycle("cyclic path version mismatch")
                }
            } else if devicePath != nil { throw V2Error.invalidLifecycle("unexpected 3D configuration") }
            if let handoff = boundaryHandoff { try handoff.validate() }
            let required = [initialVelocityStandardDeviation, minimumInitialBiasStandardDeviation,
                            accelerationNoiseStandardDeviation, biasRandomWalkStandardDeviation,
                            stationaryVelocityObservationStandardDeviation,
                            reversalVelocityObservationBaseStandardDeviation,
                            reversalAccelerationStandardDeviationScale, maximumReversalVelocityInnovation,
                            maximumReversalNormalizedInnovationSquared, reversalSearchTolerance,
                            reversalConfirmationLookahead, finalizationDeadline,
                            maximumVelocityStandardDeviation, maximumAnchorAge, boundaryPerturbation,
                            maximumBoundaryPerturbationSpeed, maximumBoundaryPerturbationFraction,
                            movementInterruptionMergeDuration]
            guard required.allSatisfy({ ($0 ?? -.infinity).isFinite && ($0 ?? 0) > 0 }),
                  finalizationDeadline! <= 0.60, reversalConfirmationLookahead! <= 0.20,
                  reversalSearchTolerance! <= 0.25, maximumAnchorAge! <= 8,
                  boundaryPerturbation! == 0.04,
                  maximumReversalVelocityInnovation! <= 0.20,
                  maximumReversalNormalizedInnovationSquared! <= 9,
                  maximumVelocityStandardDeviation! <= 0.15,
                  maximumBoundaryPerturbationSpeed! <= 0.10,
                  maximumEquivalentBias <= 0.35,
                  maximumBoundaryPerturbationFraction! <= 0.15,
                  movementInterruptionMergeDuration! <= 0.08 else {
                throw V2Error.invalidLifecycle("invalid continuous metrics configuration")
            }
        } else {
            let v2Values = [initialVelocityStandardDeviation, minimumInitialBiasStandardDeviation,
                            accelerationNoiseStandardDeviation, biasRandomWalkStandardDeviation,
                            stationaryVelocityObservationStandardDeviation,
                            reversalVelocityObservationBaseStandardDeviation,
                            reversalAccelerationStandardDeviationScale, maximumReversalVelocityInnovation,
                            maximumReversalNormalizedInnovationSquared, reversalSearchTolerance,
                            reversalConfirmationLookahead, finalizationDeadline,
                            maximumVelocityStandardDeviation, maximumAnchorAge, boundaryPerturbation,
                            maximumBoundaryPerturbationSpeed, maximumBoundaryPerturbationFraction,
                            movementInterruptionMergeDuration]
            guard v2Values.allSatisfy({ $0 == nil }), boundaryHandoff == nil, devicePath == nil else {
                throw V2Error.invalidLifecycle("V1 metrics cannot contain V2 parameters")
            }
        }
        return self
    }
}

struct RepBoundaryHandoffConfiguration: Codable, Sendable, Equatable {
    var version = "settling-reversal-v1"
    var minimumAngularDisplacement = 0.048
    var minimumDirectionalRate = 0.15
    var persistenceSamples = 3

    func validate() throws {
        guard version == "settling-reversal-v1", minimumAngularDisplacement.isFinite,
              minimumAngularDisplacement >= 0.048, minimumDirectionalRate.isFinite,
              minimumDirectionalRate >= 0.15, (3...10).contains(persistenceSamples) else {
            throw V2Error.invalidLifecycle("invalid boundary handoff configuration")
        }
    }
}

enum RepMetricsStatus: String, Codable, Sendable { case pending, available, unavailable }
enum RepTimingSource: String, Codable, Sendable { case detectorLandmarks, verticalMotion, devicePathMotion }
enum RepMetricsReason: String, Codable, Sendable {
    case waitingForEndpoint, missingStartHold, missingEndHold, invalidInterval, invalidLandmarks
    case excessiveEndpointCorrection, excessiveVerticalClosure, ambiguousDirection, interrupted
    case ambiguousBoundary, missingInitialAnchor, excessiveUncertainty, staleAnchor, unsupportedExercise
    case invalidOrientation
}

enum RepBoundaryDecisionReason: String, Codable, Sendable {
    case accepted, missingInitialAnchor, excessiveInnovation, excessiveUncertainty
    case incompatibleMotion, invalidEvidence, unsupportedExercise, missedDeadline
}

struct RepBoundaryMetricDecision: Codable, Sendable, Equatable, Identifiable {
    var id: String { boundaryID }
    let boundaryID: String
    let sourceSegmentID: String
    let kind: V2BoundaryKind
    let observedTimestamp: Double
    let resolvedTimestamp: Double
    let associatedCandidateIDs: [String]
    let accepted: Bool
    let reason: RepBoundaryDecisionReason
    let estimatedVelocity: Double?
    let velocityStandardDeviation: Double?
    let innovation: Double?
    let normalizedInnovationSquared: Double?
    let observationStandardDeviation: Double?
}

struct RepMotionMetrics: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let setID: UUID
    var revision = 0
    var status: RepMetricsStatus = .pending
    var reason: RepMetricsReason? = .waitingForEndpoint
    var updatedAt: Double
    var timingSource: RepTimingSource = .detectorLandmarks
    var integrationStart: Double?
    var integrationEnd: Double?
    var movementStart: Double?
    var liftEnd: Double?
    var loweringStart: Double?
    var movementEnd: Double?
    var liftingDuration: Double?
    var loweringDuration: Double?
    var topPauseDuration: Double?
    var bottomPauseDuration: Double?
    var meanLiftingSpeed: Double?
    var peakLiftingSpeed: Double?
    var meanLoweringSpeed: Double?
    var peakLoweringSpeed: Double?
    var endpointVelocityResidual: Double?
    var equivalentAccelerationBias: Double?
    var pathClosure3D: ExperimentalVector3?
    var maximumBoundarySpeedChange: Double?
    var verticalClosure: Double?
    var boundaryIDs: [String]?
    var estimatorVersion: String?
    var maximumVelocityStandardDeviation: Double?
    var finalizedAt: Double?
    var boundaryKind: V2BoundaryKind?
    var startBoundaryKind: V2BoundaryKind?
    var boundaryVelocity: Double?
    var boundaryVelocityStandardDeviation: Double?
    var normalizedInnovationSquared: Double?
    var measurementKind: String?
    var meanVerticalLiftingSpeed: Double?
    var peakVerticalLiftingSpeed: Double?
    var meanVerticalLoweringSpeed: Double?
    var peakVerticalLoweringSpeed: Double?
    var endpointVelocity3D: ExperimentalVector3?
    var accelerationBias3D: ExperimentalVector3?
}

struct RepMetricsSnapshot: Codable, Sendable, Equatable {
    let configuration: RepMetricsConfiguration
    let configurationHash: String
    let reps: [RepMotionMetrics]
    var boundaryDecisions: [RepBoundaryMetricDecision]? = nil

    var baselineMeanLiftingSpeed: Double? {
        let eligible = reps.filter { $0.status == .available }
            .compactMap(\.meanLiftingSpeed).filter { $0 >= configuration.minimumBaselineSpeed }.prefix(3)
        return eligible.count == 3 ? eligible.reduce(0, +) / 3 : nil
    }

    func slowdownPercent(for rep: RepMotionMetrics) -> Double? {
        guard let baseline = baselineMeanLiftingSpeed, let speed = rep.meanLiftingSpeed else { return nil }
        return 100 * (1 - speed / baseline)
    }
}

/// Observes uniform samples and immutable, already committed events. Never calls a detector.
struct PassiveRepMetrics: Sendable {
    private var devicePathEstimator: DevicePathMetrics?
    private struct Frame: Sendable {
        let time: Double
        let acceleration: Double
        let accelerationG: Double
        let gyro: Double
        let rotationRate: ExperimentalVector3
        let gravity: ExperimentalVector3
        let epoch: Int
    }
    private struct KalmanState: Sendable {
        var velocity: Double
        var bias: Double
        var p00: Double
        var p01: Double
        var p10: Double
        var p11: Double
    }
    private struct Estimate: Sendable {
        let time: Double
        let velocity: Double
        let bias: Double
        let velocityVariance: Double
        let filtered: KalmanState
    }
    private struct VelocityAnchor: Sendable {
        var id: String
        let time: Double
        let kind: V2BoundaryKind
        let standardDeviation: Double
        let endpointStart: Double
        let endpointEnd: Double
        var associatedCandidateIDs: [String]
        let initialBias: Double?
        let initialBiasStandardDeviation: Double?
    }
    private struct EstimatorSeed: Sendable {
        let time: Double
        let acceleration: Double
        let state: KalmanState
    }
    let configuration: RepMetricsConfiguration
    private var filter: ScalarBiquadFilter
    private var frames: [Frame] = []
    private var events: [V2CycleEvidence] = []
    private var results: [RepMotionMetrics] = []
    private var previousSample: ResampledMotionSample?
    private var velocityAnchors: [VelocityAnchor] = []
    private var boundaryEvidence: [V2BoundaryEvidence] = []
    private var processedBoundaryIDs: Set<String> = []
    private var boundaryDecisions: [RepBoundaryMetricDecision] = []
    private var lastStationaryWindowEnd: Double?
    private var estimatorSeed: EstimatorSeed?

    init(configuration: RepMetricsConfiguration = .init()) {
        self.configuration = configuration
        filter = ScalarBiquadFilter(coefficients: configuration.filter)
        if configuration.devicePath != nil {
            devicePathEstimator = DevicePathMetrics(configuration: configuration)
        }
    }

    var snapshot: RepMetricsSnapshot {
        if let devicePathEstimator { return devicePathEstimator.snapshot }
        return .init(configuration: configuration, configurationHash: configuration.contentHash, reps: results,
              boundaryDecisions: configuration.version == "vertical-metrics-v2" ? boundaryDecisions : nil)
    }

    /// The last source-time deadline among unfinished V2 reps. V1 deliberately
    /// returns nil so its existing 400 ms engine drain remains unchanged.
    var pendingDeadline: Double? {
        if let devicePathEstimator { return devicePathEstimator.pendingDeadline }
        guard configuration.version == "vertical-metrics-v2", let deadline = configuration.finalizationDeadline else { return nil }
        return events.enumerated().compactMap { index, event in
            results.indices.contains(index) && results[index].status == .pending ? event.completionTimestamp + deadline : nil
        }.max()
    }

    static func verticalAcceleration(_ sample: ResampledMotionSample,
                                     configuration: RepMetricsConfiguration) -> Double? {
        let g = sample.gravity.magnitude
        let a = sample.userAcceleration
        guard g.isFinite, (configuration.minimumGravityMagnitude...configuration.maximumGravityMagnitude).contains(g),
              [a.x, a.y, a.z].allSatisfy(\.isFinite) else { return nil }
        // userAcceleration already excludes gravity. Both vectors are in the same device frame.
        return configuration.accelerationSign * configuration.standardGravity *
            -(a.x * sample.gravity.x + a.y * sample.gravity.y + a.z * sample.gravity.z) / g
    }

    mutating func observe(_ sample: ResampledMotionSample) {
        if devicePathEstimator != nil { devicePathEstimator?.observe(sample); return }
        let time = sample.sourceTimestamp
        let validInterval = previousSample.map {
            sample.epoch == $0.epoch && sample.sensorSide == $0.sensorSide &&
            time > $0.sourceTimestamp && time - $0.sourceTimestamp <= configuration.maximumUniformInterval + 1e-9
        } ?? true
        guard validInterval, time.isFinite, sample.sensorSide != nil,
              sample.rotationRate.magnitude.isFinite,
              let acceleration = Self.verticalAcceleration(sample, configuration: configuration) else {
            invalidate(at: time.isFinite ? time : (frames.last?.time ?? 0), reason: .invalidInterval)
            previousSample = nil
            return
        }
        previousSample = sample
        frames.append(.init(time: time, acceleration: filter.process(acceleration),
                            accelerationG: sample.userAcceleration.magnitude,
                            gyro: sample.rotationRate.magnitude, rotationRate: sample.rotationRate,
                            gravity: sample.gravity, epoch: sample.epoch))
        if configuration.version == "vertical-metrics-v2" {
            detectStationaryObservation()
            trimV2History(before: time - configuration.historyDuration)
        } else {
            frames.removeAll { $0.time < time - configuration.historyDuration }
            resolve(at: time, final: false)
        }
    }

    mutating func observeBoundaryEvidence(_ evidence: [V2BoundaryEvidence], at time: Double) {
        if devicePathEstimator != nil { devicePathEstimator?.observeBoundaryEvidence(evidence, at: time); return }
        guard configuration.version == "vertical-metrics-v2" else { return }
        for item in evidence {
            if let index = boundaryEvidence.firstIndex(where: { $0.boundaryID == item.boundaryID }) {
                let additions = item.associatedCandidateIDs.filter {
                    !boundaryEvidence[index].associatedCandidateIDs.contains($0)
                }
                boundaryEvidence[index].associatedCandidateIDs.append(contentsOf: additions)
                if !additions.isEmpty {
                    if let anchor = velocityAnchors.firstIndex(where: { $0.id == item.boundaryID }) {
                        velocityAnchors[anchor].associatedCandidateIDs.append(contentsOf: additions.filter {
                            !velocityAnchors[anchor].associatedCandidateIDs.contains($0)
                        })
                    }
                    if let prior = boundaryDecisions.firstIndex(where: { $0.boundaryID == item.boundaryID }) {
                        let old = boundaryDecisions[prior]
                        boundaryDecisions[prior] = .init(
                            boundaryID: old.boundaryID, sourceSegmentID: old.sourceSegmentID,
                            kind: old.kind, observedTimestamp: old.observedTimestamp,
                            resolvedTimestamp: old.resolvedTimestamp,
                            associatedCandidateIDs: old.associatedCandidateIDs + additions,
                            accepted: old.accepted, reason: old.reason,
                            estimatedVelocity: old.estimatedVelocity,
                            velocityStandardDeviation: old.velocityStandardDeviation,
                            innovation: old.innovation,
                            normalizedInnovationSquared: old.normalizedInnovationSquared,
                            observationStandardDeviation: old.observationStandardDeviation)
                    }
                }
            } else {
                boundaryEvidence.append(item)
            }
        }
        resolveBoundaryEvidence(at: time)
    }

    mutating func observeCommitted(_ committed: [V2CycleEvidence], at time: Double) {
        if devicePathEstimator != nil { devicePathEstimator?.observeCommitted(committed, at: time); return }
        for event in committed where event.committed && event.rejectionReason == nil {
            guard !events.contains(where: { $0.id == event.id && $0.setID == event.setID }) else { continue }
            events.append(event)
            results.append(.init(id: event.id, setID: event.setID, updatedAt: time))
        }
        if configuration.version == "vertical-metrics-v2" { resolveBoundaryEvidence(at: time) }
        resolve(at: time, final: false)
    }

    mutating func finish(at time: Double, interrupted: Bool) {
        if devicePathEstimator != nil { devicePathEstimator?.finish(at: time, interrupted: interrupted); return }
        if interrupted { invalidate(at: time, reason: .interrupted) }
        else { resolve(at: time, final: true) }
    }

    mutating func sourceDiscontinuity(at time: Double) {
        if devicePathEstimator != nil { devicePathEstimator?.invalidate(at: time, reason: .invalidInterval); return }
        invalidate(at: time, reason: .invalidInterval)
    }

    private mutating func invalidate(at time: Double, reason: RepMetricsReason) {
        for index in results.indices where results[index].status == .pending {
            results[index].status = .unavailable; results[index].reason = reason
            results[index].updatedAt = time; results[index].revision += 1
            if configuration.version == "vertical-metrics-v2" { results[index].finalizedAt = time }
        }
        frames.removeAll(); filter.reset(); previousSample = nil
        velocityAnchors.removeAll(); boundaryEvidence.removeAll(); processedBoundaryIDs.removeAll()
        lastStationaryWindowEnd = nil; estimatorSeed = nil
    }

    private mutating func resolve(at time: Double, final: Bool) {
        for index in results.indices where results[index].status == .pending {
            let event = events[index]
            let wait = configuration.version == "vertical-metrics-v2"
                ? configuration.finalizationDeadline! : configuration.endLookahead
            let expired = final || time >= event.completionTimestamp + wait - 1e-9
            var result = configuration.version == "vertical-metrics-v2"
                ? calculateV2(event, at: time, final: expired)
                : calculateV1(event, at: time, final: expired)
            guard result.status != .pending else { continue }
            if configuration.version == "vertical-metrics-v1", index > 0,
               let start = result.movementStart, let priorEnd = results[index - 1].movementEnd {
                result.bottomPauseDuration = max(0, start - priorEnd)
            } else if configuration.version == "vertical-metrics-v2", index > 0,
                      result.status != .pending, let start = result.movementStart,
                      let startID = result.boundaryIDs?.first,
                      let startAnchor = velocityAnchors.first(where: { $0.id == startID }) {
                if startAnchor.kind == .continuousReversal,
                   startAnchor.associatedCandidateIDs.contains(event.id) {
                    result.bottomPauseDuration = 0
                } else if startAnchor.kind == .stationary,
                          let priorEnd = results[index - 1].movementEnd {
                    result.bottomPauseDuration = stationaryPauseDuration(after: priorEnd, before: start)
                }
            }
            result.revision = results[index].revision + 1
            results[index] = result
        }
    }

    // MARK: - Continuous estimator (vertical-metrics-v2)

    private mutating func detectStationaryObservation() {
        guard let end = frames.indices.last, quiet(end) else { return }
        let endTime = frames[end].time
        guard let start = frames.firstIndex(where: {
            $0.time >= endTime - configuration.quietDuration - 1e-9
        }), endTime - frames[start].time >= configuration.quietDuration - 1e-9 else { return }
        if let prior = lastStationaryWindowEnd, frames[start].time < prior - 1e-9 { return }
        let window = Array(frames[start...end])
        let mean = window.map(\.acceleration).reduce(0, +) / Double(window.count)
        let variance = window.count > 1
            ? window.map { ($0.acceleration - mean) * ($0.acceleration - mean) }.reduce(0, +) / Double(window.count - 1)
            : 0
        let biasSD = max(configuration.minimumInitialBiasStandardDeviation!, sqrt(max(0, variance)))
        let id = "stationary-\(window.last!.epoch)-\(Int64((endTime * 1_000_000).rounded()))"
        velocityAnchors.append(.init(id: id, time: endTime, kind: .stationary,
                                     standardDeviation: configuration.stationaryVelocityObservationStandardDeviation!,
                                     endpointStart: window.first!.time, endpointEnd: endTime,
                                     associatedCandidateIDs: [], initialBias: mean,
                                     initialBiasStandardDeviation: biasSD))
        lastStationaryWindowEnd = endTime
    }

    private mutating func trimV2History(before cutoff: Double) {
        guard let lastRemoved = frames.lastIndex(where: { $0.time < cutoff }) else { return }
        let estimates = buildEstimates()
        if let estimate = estimates.last(where: { $0.time <= frames[lastRemoved].time }) {
            estimatorSeed = .init(time: estimate.time, acceleration: frames[lastRemoved].acceleration,
                                  state: estimate.filtered)
        }
        let removedTime = frames[lastRemoved].time
        frames.removeFirst(lastRemoved + 1)
        velocityAnchors.removeAll { $0.time <= removedTime + 1e-9 }
        boundaryEvidence.removeAll { $0.confirmedTimestamp < cutoff }
        if frames.isEmpty { estimatorSeed = nil }
    }

    private mutating func resolveBoundaryEvidence(at time: Double) {
        if configuration.boundaryHandoff != nil { resolveSettlingHandoffs(at: time) }
        for evidence in boundaryEvidence where !processedBoundaryIDs.contains(evidence.boundaryID) {
            let matching = events.filter { evidence.associatedCandidateIDs.contains($0.id) }
            guard !matching.isEmpty else { continue }
            let deadline = matching.map { $0.completionTimestamp + configuration.finalizationDeadline! }.min()!
            guard time + 1e-9 >= evidence.confirmedTimestamp || time + 1e-9 >= deadline else { continue }
            let boundaryTime = evidence.returnedTimestamp ?? evidence.observedTimestamp
            // Keep the hypothesis pending through its permitted confirmation
            // window. This lets later source-time samples improve both direction
            // compatibility and smoothed uncertainty without exceeding 600 ms.
            if evidence.kind == .continuousReversal,
               time + 1e-9 < min(deadline, boundaryTime + configuration.reversalConfirmationLookahead!) {
                continue
            }
            if evidence.kind == .stationary,
               !velocityAnchors.contains(where: {
                   $0.kind == .stationary &&
                       $0.endpointStart <= evidence.endpointEndTimestamp + 1e-9 &&
                       $0.endpointEnd >= evidence.endpointStartTimestamp - 1e-9
               }), time + 1e-9 < deadline {
                continue
            }
            let decision = evaluateBoundary(evidence, matching: matching, estimates: buildEstimates(),
                                            at: time, missedDeadline: time + 1e-9 < evidence.confirmedTimestamp)
            boundaryDecisions.append(decision)
            if boundaryDecisions.count > 64 { boundaryDecisions.removeFirst(boundaryDecisions.count - 64) }
            processedBoundaryIDs.insert(evidence.boundaryID)
        }
    }

    /// A committed bottom may have satisfied counting's shorter settle without
    /// satisfying a physical stationary observation. Select a reversal from
    /// orientation and signed gyro first; the normal velocity gates still apply.
    /// This observer never changes detector state, admission, or committed events.
    private mutating func resolveSettlingHandoffs(at time: Double) {
        guard let handoff = configuration.boundaryHandoff else { return }
        for (eventIndex, event) in events.enumerated() where results[eventIndex].status == .pending {
            guard event.exercise == .bicepsCurl, let axis = event.movementAxis,
                  time <= event.completionTimestamp + configuration.finalizationDeadline! + 1e-9 else { continue }
            let existingIndex = boundaryEvidence.firstIndex {
                $0.associatedCandidateIDs.contains(event.id) &&
                    abs(($0.returnedTimestamp ?? $0.observedTimestamp) - event.completionTimestamp)
                        <= configuration.reversalSearchTolerance! + 1e-9
            }
            if let existingIndex {
                let prior = boundaryEvidence[existingIndex]
                guard prior.kind == .stationary, !processedBoundaryIDs.contains(prior.boundaryID) else { continue }
                if velocityAnchors.contains(where: {
                    $0.kind == .stationary && $0.endpointStart <= prior.endpointEndTimestamp + 1e-9 &&
                    $0.endpointEnd >= prior.endpointStartTimestamp - 1e-9
                }) { continue }
            }
            let tolerance = configuration.reversalSearchTolerance!
            let window = frames.filter {
                $0.time >= event.completionTimestamp - tolerance - 1e-9 &&
                $0.time <= min(time, event.completionTimestamp + tolerance) + 1e-9
            }
            guard let base = window.first, window.count >= handoff.persistenceSamples * 2 else { continue }
            let progress = window.map { frame in
                V6VectorMath.gravityPlaneAngle(from: base.gravity, to: frame.gravity, axis: axis).map { -$0 }
            }
            guard progress.allSatisfy({ $0 != nil }),
                  let bottomIndex = progress.indices.min(by: { progress[$0]! < progress[$1]! }) else { continue }
            let bottom = window[bottomIndex]
            // Do not choose a velocity zero crossing to manufacture its own evidence.
            var loweringRun = 0
            var loweringConfirmed = false
            for frame in window[..<bottomIndex] {
                loweringRun = V6VectorMath.dot(frame.rotationRate, axis) < -handoff.minimumDirectionalRate
                    ? loweringRun + 1 : 0
                if loweringRun >= handoff.persistenceSamples { loweringConfirmed = true }
            }
            guard loweringConfirmed else { continue }
            let after = frames.filter {
                $0.epoch == bottom.epoch && $0.time > bottom.time &&
                $0.time <= min(time, bottom.time + configuration.reversalConfirmationLookahead!) + 1e-9
            }
            var run = 0
            var confirmation: Double?
            for frame in after {
                let displacement = V6VectorMath.gravityPlaneAngle(from: bottom.gravity, to: frame.gravity, axis: axis).map { -$0 }
                if let displacement, displacement >= handoff.minimumAngularDisplacement,
                   V6VectorMath.dot(frame.rotationRate, axis) >= handoff.minimumDirectionalRate {
                    run += 1
                    if run >= handoff.persistenceSamples { confirmation = frame.time; break }
                } else { run = 0 }
            }
            guard let confirmation else { continue }
            let prior = existingIndex.map { boundaryEvidence[$0] }
            let evidence = V2BoundaryEvidence(
                boundaryID: prior?.boundaryID ?? "passive-bottom-\(event.id)",
                sourceSegmentID: prior?.sourceSegmentID ?? "\(event.setID.uuidString.lowercased())-metrics-source-\(bottom.epoch)",
                observedTimestamp: bottom.time, confirmedTimestamp: confirmation,
                kind: .continuousReversal, associatedCandidateIDs: prior?.associatedCandidateIDs ?? [event.id],
                endpointStartTimestamp: base.time, endpointEndTimestamp: confirmation,
                returnedTimestamp: bottom.time, direction: .loweringToLifting)
            if let existingIndex { boundaryEvidence[existingIndex] = evidence }
            else { boundaryEvidence.append(evidence) }
        }
    }

    private mutating func evaluateBoundary(_ evidence: V2BoundaryEvidence, matching: [V2CycleEvidence],
                                           estimates: [Estimate], at time: Double,
                                           missedDeadline: Bool) -> RepBoundaryMetricDecision {
        func decision(_ accepted: Bool, _ reason: RepBoundaryDecisionReason,
                      estimate: Estimate? = nil, innovation: Double? = nil,
                      nis: Double? = nil, observationSD: Double? = nil) -> RepBoundaryMetricDecision {
            .init(boundaryID: evidence.boundaryID, sourceSegmentID: evidence.sourceSegmentID,
                  kind: evidence.kind, observedTimestamp: evidence.observedTimestamp,
                  resolvedTimestamp: time, associatedCandidateIDs: evidence.associatedCandidateIDs,
                  accepted: accepted, reason: reason, estimatedVelocity: estimate?.velocity,
                  velocityStandardDeviation: estimate.map { sqrt(max(0, $0.velocityVariance)) },
                  innovation: innovation, normalizedInnovationSquared: nis,
                  observationStandardDeviation: observationSD)
        }
        let values = [evidence.observedTimestamp, evidence.confirmedTimestamp,
                      evidence.endpointStartTimestamp, evidence.endpointEndTimestamp]
        guard values.allSatisfy(\.isFinite), evidence.observedTimestamp <= evidence.confirmedTimestamp,
              evidence.endpointStartTimestamp <= evidence.endpointEndTimestamp,
              !evidence.boundaryID.isEmpty, !evidence.sourceSegmentID.isEmpty else {
            return decision(false, .invalidEvidence)
        }
        if missedDeadline { return decision(false, .missedDeadline) }
        guard matching.allSatisfy({ $0.exercise == .bicepsCurl }) else {
            return decision(false, .unsupportedExercise)
        }
        let boundaryTime = evidence.returnedTimestamp ?? evidence.observedTimestamp
        guard boundaryTime.isFinite,
              matching.contains(where: { abs(boundaryTime - $0.completionTimestamp) <= configuration.reversalSearchTolerance! + 1e-9 }),
              evidence.endpointStartTimestamp - 1e-9 <= boundaryTime,
              boundaryTime <= evidence.endpointEndTimestamp + 1e-9,
              let estimate = nearestEstimate(to: boundaryTime, in: estimates) else {
            return decision(false, estimates.isEmpty ? .missingInitialAnchor : .invalidEvidence)
        }
        let observationSD: Double
        switch evidence.kind {
        case .stationary:
            // Detector settling is not a strong zero-velocity measurement. It is
            // accepted only when the independent 200 ms physical quiet predicate
            // produced an overlapping metrics anchor.
            guard evidence.direction == .stationary,
                  let strongIndex = velocityAnchors.lastIndex(where: {
                      $0.kind == .stationary &&
                          $0.endpointStart <= evidence.endpointEndTimestamp + 1e-9 &&
                          $0.endpointEnd >= evidence.endpointStartTimestamp - 1e-9
                  }) else { return decision(false, .incompatibleMotion, estimate: estimate) }
            // Alias the independently proven quiet anchor to the recorded detector
            // boundary. Do not append a second zero observation.
            velocityAnchors[strongIndex].id = evidence.boundaryID
            velocityAnchors[strongIndex].associatedCandidateIDs = evidence.associatedCandidateIDs
            let strong = velocityAnchors[strongIndex]
            return decision(true, .accepted, estimate: nearestEstimate(to: strong.time, in: estimates),
                            innovation: -estimate.velocity, nis: nil,
                            observationSD: strong.standardDeviation)
        case .continuousReversal:
            guard evidence.direction == .loweringToLifting,
                  evidence.confirmedTimestamp - boundaryTime <= configuration.reversalConfirmationLookahead! + 1e-9,
                  compatibleReversal(at: boundaryTime, estimates: estimates) else {
                return decision(false, .incompatibleMotion, estimate: estimate)
            }
            let acceleration = nearestFrame(to: boundaryTime)?.acceleration ?? 0
            observationSD = sqrt(pow(configuration.reversalVelocityObservationBaseStandardDeviation!, 2) +
                                 pow(abs(acceleration) * configuration.reversalAccelerationStandardDeviationScale!, 2))
        }
        let innovation = -estimate.velocity
        let innovationVariance = estimate.velocityVariance + observationSD * observationSD
        let nis = innovation * innovation / max(innovationVariance, 1e-12)
        guard abs(innovation) <= configuration.maximumReversalVelocityInnovation! + 1e-12,
              nis <= configuration.maximumReversalNormalizedInnovationSquared! + 1e-12 else {
            return decision(false, .excessiveInnovation, estimate: estimate, innovation: innovation,
                            nis: nis, observationSD: observationSD)
        }
        velocityAnchors.append(.init(id: evidence.boundaryID, time: boundaryTime, kind: evidence.kind,
                                     standardDeviation: observationSD,
                                     endpointStart: evidence.endpointStartTimestamp,
                                     endpointEnd: evidence.endpointEndTimestamp,
                                     associatedCandidateIDs: evidence.associatedCandidateIDs,
                                     initialBias: nil, initialBiasStandardDeviation: nil))
        return decision(true, .accepted, estimate: estimate, innovation: innovation,
                        nis: nis, observationSD: observationSD)
    }

    private func compatibleReversal(at time: Double, estimates: [Estimate]) -> Bool {
        let before = estimates.filter { $0.time >= time - configuration.reversalSearchTolerance! && $0.time < time }
        let after = estimates.filter { $0.time > time && $0.time <= time + configuration.reversalConfirmationLookahead! }
        guard before.count >= 2, after.count >= 2 else { return false }
        return before.contains { $0.velocity < -configuration.movementSpeed } &&
            after.contains { $0.velocity > configuration.movementSpeed }
    }

    private func nearestFrame(to time: Double) -> Frame? {
        frames.min { abs($0.time - time) < abs($1.time - time) }
    }

    private func nearestEstimate(to time: Double, in estimates: [Estimate]) -> Estimate? {
        guard let value = estimates.min(by: { abs($0.time - time) < abs($1.time - time) }),
              abs(value.time - time) <= configuration.maximumUniformInterval + 1e-9 else { return nil }
        return value
    }

    private struct Matrix2 {
        var a: Double, b: Double, c: Double, d: Double
        static func * (lhs: Self, rhs: Self) -> Self {
            .init(a: lhs.a * rhs.a + lhs.b * rhs.c, b: lhs.a * rhs.b + lhs.b * rhs.d,
                  c: lhs.c * rhs.a + lhs.d * rhs.c, d: lhs.c * rhs.b + lhs.d * rhs.d)
        }
        static func + (lhs: Self, rhs: Self) -> Self {
            .init(a: lhs.a + rhs.a, b: lhs.b + rhs.b, c: lhs.c + rhs.c, d: lhs.d + rhs.d)
        }
        static func - (lhs: Self, rhs: Self) -> Self {
            .init(a: lhs.a - rhs.a, b: lhs.b - rhs.b, c: lhs.c - rhs.c, d: lhs.d - rhs.d)
        }
        var transposed: Self { .init(a: a, b: c, c: b, d: d) }
        var inverse: Self? {
            let determinant = a * d - b * c
            guard determinant.isFinite, abs(determinant) > 1e-18 else { return nil }
            return .init(a: d / determinant, b: -b / determinant,
                         c: -c / determinant, d: a / determinant)
        }
    }

    private func matrix(_ state: KalmanState) -> Matrix2 {
        .init(a: state.p00, b: state.p01, c: state.p10, d: state.p11)
    }

    private func replacingCovariance(_ state: KalmanState, _ value: Matrix2) -> KalmanState {
        var copy = state
        copy.p00 = max(0, value.a); copy.p01 = (value.b + value.c) * 0.5
        copy.p10 = copy.p01; copy.p11 = max(0, value.d)
        return copy
    }

    private func predict(_ state: KalmanState, fromAcceleration: Double,
                         toAcceleration: Double, dt: Double) -> KalmanState {
        let f = Matrix2(a: 1, b: -dt, c: 0, d: 1)
        let accelerationVariance = pow(configuration.accelerationNoiseStandardDeviation! * dt, 2)
        let biasVariance = pow(configuration.biasRandomWalkStandardDeviation!, 2) * dt
        let q = Matrix2(a: accelerationVariance, b: 0, c: 0, d: biasVariance)
        let covariance = f * matrix(state) * f.transposed + q
        var result = replacingCovariance(state, covariance)
        result.velocity += ((fromAcceleration + toAcceleration) * 0.5 - state.bias) * dt
        return result
    }

    private func update(_ state: KalmanState, standardDeviation: Double) -> KalmanState {
        let variance = standardDeviation * standardDeviation
        let s = max(state.p00 + variance, 1e-18)
        let k0 = state.p00 / s, k1 = state.p10 / s
        var result = state
        result.velocity -= k0 * state.velocity
        result.bias -= k1 * state.velocity
        let p00 = state.p00, p01 = state.p01, p10 = state.p10, p11 = state.p11
        result.p00 = max(0, (1 - k0) * p00)
        result.p01 = (1 - k0) * p01
        result.p10 = p10 - k1 * p00
        result.p11 = max(0, p11 - k1 * p01)
        let cross = (result.p01 + result.p10) * 0.5
        result.p01 = cross; result.p10 = cross
        return result
    }

    /// Replays delayed observations in source-time order, then applies a bounded
    /// Rauch–Tung–Striebel pass. The causal acceleration filter itself is never reset
    /// at a rep boundary; only source discontinuities reset it.
    private func buildEstimates(anchors suppliedAnchors: [VelocityAnchor]? = nil) -> [Estimate] {
        guard !frames.isEmpty else { return [] }
        let anchors = (suppliedAnchors ?? velocityAnchors).sorted {
            $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time
        }
        var firstFrameIndex = 0
        var initializationAnchorID: String?
        var state: KalmanState
        var previousTime: Double
        var previousAcceleration: Double
        if let seed = estimatorSeed, seed.time < frames[0].time {
            state = seed.state; previousTime = seed.time; previousAcceleration = seed.acceleration
        } else {
            guard let initializer = anchors.first(where: { $0.kind == .stationary && $0.initialBias != nil }),
                  let index = frames.indices.min(by: {
                      abs(frames[$0].time - initializer.time) < abs(frames[$1].time - initializer.time)
                  }), abs(frames[index].time - initializer.time) <= configuration.maximumUniformInterval + 1e-9 else { return [] }
            firstFrameIndex = index
            initializationAnchorID = initializer.id
            let velocitySD = configuration.initialVelocityStandardDeviation!
            let biasSD = max(configuration.minimumInitialBiasStandardDeviation!,
                             initializer.initialBiasStandardDeviation ?? 0)
            state = .init(velocity: 0, bias: initializer.initialBias ?? frames[index].acceleration,
                          p00: velocitySD * velocitySD, p01: 0, p10: 0, p11: biasSD * biasSD)
            previousTime = frames[index].time; previousAcceleration = frames[index].acceleration
        }
        let activeFrames = Array(frames[firstFrameIndex...])
        var filtered: [KalmanState] = [], predicted: [KalmanState] = [], transitions: [Matrix2] = []
        var anchorCursor = 0
        while anchorCursor < anchors.count && anchors[anchorCursor].time < previousTime - configuration.maximumUniformInterval {
            anchorCursor += 1
        }
        for (offset, frame) in activeFrames.enumerated() {
            if offset > 0 || frame.time > previousTime + 1e-12 {
                let dt = frame.time - previousTime
                state = predict(state, fromAcceleration: previousAcceleration,
                                toAcceleration: frame.acceleration, dt: dt)
                if offset > 0 { transitions.append(.init(a: 1, b: -dt, c: 0, d: 1)) }
            }
            predicted.append(state)
            while anchorCursor < anchors.count,
                  anchors[anchorCursor].time <= frame.time + configuration.maximumUniformInterval * 0.5 + 1e-9 {
                if anchors[anchorCursor].time >= frame.time - configuration.maximumUniformInterval * 0.5 - 1e-9 {
                    if anchors[anchorCursor].id != initializationAnchorID {
                        state = update(state, standardDeviation: anchors[anchorCursor].standardDeviation)
                    }
                }
                anchorCursor += 1
            }
            filtered.append(state)
            previousTime = frame.time; previousAcceleration = frame.acceleration
        }
        guard filtered.count > 1 else {
            return zip(activeFrames, filtered).map {
                .init(time: $0.0.time, velocity: $0.1.velocity, bias: $0.1.bias,
                      velocityVariance: $0.1.p00, filtered: $0.1)
            }
        }
        var smoothed = filtered
        for index in stride(from: filtered.count - 2, through: 0, by: -1) {
            let f = transitions[index]
            guard let inverse = matrix(predicted[index + 1]).inverse else { continue }
            let gain = matrix(filtered[index]) * f.transposed * inverse
            let dv = smoothed[index + 1].velocity - predicted[index + 1].velocity
            let db = smoothed[index + 1].bias - predicted[index + 1].bias
            smoothed[index].velocity = filtered[index].velocity + gain.a * dv + gain.b * db
            smoothed[index].bias = filtered[index].bias + gain.c * dv + gain.d * db
            let covariance = matrix(filtered[index]) +
                gain * (matrix(smoothed[index + 1]) - matrix(predicted[index + 1])) * gain.transposed
            smoothed[index] = replacingCovariance(smoothed[index], covariance)
        }
        return activeFrames.indices.map {
            .init(time: activeFrames[$0].time, velocity: smoothed[$0].velocity, bias: smoothed[$0].bias,
                  velocityVariance: smoothed[$0].p00, filtered: filtered[$0])
        }
    }

    private func quiet(_ end: Int) -> Bool {
        let endFrame = frames[end]
        let start = frames.firstIndex { $0.time >= endFrame.time - configuration.quietDuration - 1e-9 } ?? end
        guard endFrame.time - frames[start].time >= configuration.quietDuration - 1e-9 else { return false }
        let base = frames[start].gravity
        return frames[start...end].allSatisfy {
            let dx = $0.gravity.x - base.x, dy = $0.gravity.y - base.y, dz = $0.gravity.z - base.z
            return $0.accelerationG <= configuration.quietAccelerationG && $0.gyro <= configuration.quietGyro &&
                sqrt(dx * dx + dy * dy + dz * dz) <= configuration.quietGravityVariationG
        }
    }

    private struct ExtractedMotion {
        let integrationStart: Double
        let integrationEnd: Double
        let movementStart: Double
        let liftEnd: Double
        let loweringStart: Double
        let movementEnd: Double
        let liftingDuration: Double
        let loweringDuration: Double
        let topPauseDuration: Double?
        let meanLiftingSpeed: Double
        let peakLiftingSpeed: Double
        let meanLoweringSpeed: Double
        let peakLoweringSpeed: Double
        let verticalClosure: Double
        let endpointResidual: Double
        let maximumVelocitySD: Double
        let maximumAbsoluteBias: Double
    }

    private func calculateV2(_ event: V2CycleEvidence, at time: Double, final: Bool) -> RepMotionMetrics {
        var result = RepMotionMetrics(id: event.id, setID: event.setID, updatedAt: time)
        result.estimatorVersion = configuration.version
        result.liftingDuration = event.topTimestamp - event.startTimestamp
        result.loweringDuration = event.completionTimestamp - event.topTimestamp
        func failure(_ reason: RepMetricsReason) -> RepMotionMetrics {
            var failed = result
            failed.status = .unavailable; failed.reason = reason; failed.finalizedAt = time
            return failed
        }
        guard event.exercise == .bicepsCurl else { return failure(.unsupportedExercise) }
        guard event.startTimestamp.isFinite, event.topTimestamp.isFinite, event.completionTimestamp.isFinite,
              event.startTimestamp < event.topTimestamp, event.topTimestamp < event.completionTimestamp,
              event.completionTimestamp - event.startTimestamp <= configuration.maximumCycleDuration else {
            return failure(.invalidLandmarks)
        }
        let estimates = buildEstimates()
        guard !estimates.isEmpty else { return failure(.missingInitialAnchor) }
        let tolerance = configuration.reversalSearchTolerance!
        let eligibleStarts = velocityAnchors.filter { anchor in
            anchor.time <= event.startTimestamp + tolerance + 1e-9 &&
                event.startTimestamp - anchor.time <= configuration.maximumAnchorAge! + 1e-9
        }.sorted { $0.time < $1.time }
        guard let startAnchor = eligibleStarts.last else { return failure(.staleAnchor) }
        let endAnchors = velocityAnchors.filter { anchor in
            if anchor.kind == .continuousReversal {
                return anchor.associatedCandidateIDs.contains(event.id) &&
                    abs(anchor.time - event.completionTimestamp) <= tolerance + 1e-9
            }
            return anchor.endpointStart <= event.completionTimestamp + configuration.finalizationDeadline! + 1e-9 &&
                anchor.endpointEnd >= event.completionTimestamp - configuration.endLookback - 1e-9 &&
                anchor.endpointEnd >= event.completionTimestamp - configuration.maximumUniformInterval - 1e-9 &&
                anchor.time >= event.completionTimestamp - tolerance - 1e-9
        }.sorted { $0.time < $1.time }
        guard let endAnchor = endAnchors.first else {
            return final ? failure(.ambiguousBoundary) : result
        }
        guard endAnchor.time - startAnchor.time > 0,
              let extraction = extractMotion(event: event, startAnchor: startAnchor,
                                             endAnchor: endAnchor, estimates: estimates) else {
            return final ? failure(.ambiguousDirection) : result
        }
        result.integrationStart = extraction.integrationStart
        result.integrationEnd = extraction.integrationEnd
        result.movementStart = extraction.movementStart
        result.liftEnd = extraction.liftEnd
        result.loweringStart = extraction.loweringStart
        result.movementEnd = extraction.movementEnd
        result.liftingDuration = extraction.liftingDuration
        result.loweringDuration = extraction.loweringDuration
        result.topPauseDuration = extraction.topPauseDuration
        // Preserves the existing metric meaning: bottom pause precedes this rep.
        // It is resolved above only when a prior arrival and this departure are
        // both known; the first rep therefore remains unavailable.
        result.bottomPauseDuration = nil
        result.endpointVelocityResidual = extraction.endpointResidual
        result.equivalentAccelerationBias = extraction.maximumAbsoluteBias
        result.verticalClosure = extraction.verticalClosure
        result.maximumVelocityStandardDeviation = extraction.maximumVelocitySD
        result.boundaryIDs = [startAnchor.id, endAnchor.id]
        result.boundaryKind = endAnchor.kind
        result.startBoundaryKind = startAnchor.kind
        if let estimate = nearestEstimate(to: endAnchor.time, in: estimates) {
            result.boundaryVelocity = estimate.velocity
            result.boundaryVelocityStandardDeviation = sqrt(max(0, estimate.velocityVariance))
        }
        if let decision = boundaryDecisions.last(where: { $0.boundaryID == endAnchor.id }) {
            result.normalizedInnovationSquared = decision.normalizedInnovationSquared
        }
        guard extraction.maximumAbsoluteBias <= configuration.maximumEquivalentBias + 1e-12 else {
            return failure(.excessiveEndpointCorrection)
        }
        guard abs(extraction.endpointResidual) <= configuration.maximumVelocityCorrection + 1e-12 else {
            return failure(.excessiveEndpointCorrection)
        }
        guard extraction.maximumVelocitySD <= configuration.maximumVelocityStandardDeviation! + 1e-12 else {
            return failure(.excessiveUncertainty)
        }
        guard abs(extraction.verticalClosure) <= configuration.maximumVerticalClosure else {
            return failure(.excessiveVerticalClosure)
        }
        guard velocityAnchors.contains(where: {
            $0.time <= extraction.movementEnd + 1e-9 &&
                extraction.movementEnd - $0.time <= configuration.maximumAnchorAge! + 1e-9
        }) else { return failure(.staleAnchor) }
        if endAnchor.kind == .continuousReversal,
           !boundaryPerturbationIsStable(event: event, startAnchor: startAnchor,
                                         endAnchor: endAnchor, baseline: extraction) {
            return failure(.ambiguousBoundary)
        }
        result.meanLiftingSpeed = extraction.meanLiftingSpeed
        result.peakLiftingSpeed = extraction.peakLiftingSpeed
        result.meanLoweringSpeed = extraction.meanLoweringSpeed
        result.peakLoweringSpeed = extraction.peakLoweringSpeed
        result.status = .available; result.reason = nil; result.finalizedAt = time
        return result
    }

    private func stationaryPauseDuration(after arrivalSearchStart: Double,
                                         before departureSearchEnd: Double) -> Double? {
        let candidates = frames.filter {
            $0.time >= arrivalSearchStart - 1e-9 && $0.time <= departureSearchEnd + 1e-9
        }
        guard candidates.count > 1 else { return nil }
        var groups: [[Frame]] = [], current: [Frame] = []
        for frame in candidates {
            let intervalValid = current.last.map {
                frame.time - $0.time <= configuration.maximumUniformInterval + 1e-9
            } ?? true
            let base = current.first?.gravity ?? frame.gravity
            let dx = frame.gravity.x - base.x, dy = frame.gravity.y - base.y, dz = frame.gravity.z - base.z
            let rawQuiet = frame.accelerationG <= configuration.quietAccelerationG &&
                frame.gyro <= configuration.quietGyro
            let physicalQuiet = rawQuiet &&
                sqrt(dx * dx + dy * dy + dz * dz) <= configuration.quietGravityVariationG
            if intervalValid && physicalQuiet {
                current.append(frame)
            } else {
                if !current.isEmpty { groups.append(current) }
                current = rawQuiet ? [frame] : []
            }
        }
        if !current.isEmpty { groups.append(current) }
        // Up to the existing 80 ms phase-gap allowance may sit between the last
        // physically quiet sample and the velocity-threshold departure edge.
        guard let group = groups.last(where: {
            guard let first = $0.first, let last = $0.last else { return false }
            return last.time - first.time >= configuration.minimumPauseDuration - 1e-9 &&
                departureSearchEnd - last.time <= configuration.movementInterruptionMergeDuration! + 1e-9
        }), let first = group.first, let last = group.last else { return nil }
        return last.time - first.time
    }

    private func extractMotion(event: V2CycleEvidence, startAnchor: VelocityAnchor,
                               endAnchor: VelocityAnchor, estimates: [Estimate]) -> ExtractedMotion? {
        let integration = estimates.filter {
            $0.time >= startAnchor.time - 1e-9 && $0.time <= endAnchor.time + 1e-9
        }
        guard integration.count >= configuration.peakWindowSamples else { return nil }
        let endLimit = endAnchor.kind == .stationary ? endAnchor.endpointStart : endAnchor.time
        let liftCandidates = integration.indices.filter {
            integration[$0].time >= event.startTimestamp - configuration.reversalSearchTolerance! - 1e-9 &&
                integration[$0].time <= event.topTimestamp + configuration.turnaroundTolerance &&
                integration[$0].velocity > configuration.movementSpeed
        }
        let lowerCandidates = integration.indices.filter {
            integration[$0].time >= event.topTimestamp - configuration.turnaroundTolerance &&
                integration[$0].time <= event.completionTimestamp + configuration.reversalSearchTolerance! + 1e-9 &&
                integration[$0].time <= endLimit + 1e-9 &&
                integration[$0].velocity < -configuration.movementSpeed
        }
        guard let lift = dominantRegion(liftCandidates, estimates: integration, positive: true),
              let lower = dominantRegion(lowerCandidates, estimates: integration, positive: false),
              lift.upperBound < lower.lowerBound else { return nil }
        let liftTimes = Array(integration[lift].map(\.time))
        let lowerTimes = Array(integration[lower].map(\.time))
        let liftDuration = liftTimes.last! - liftTimes.first!
        let lowerDuration = lowerTimes.last! - lowerTimes.first!
        guard liftDuration >= configuration.minimumLegDuration,
              lowerDuration >= configuration.minimumLegDuration else { return nil }
        let liftVelocity = integration[lift].map(\.velocity)
        let lowerVelocity = integration[lower].map(\.velocity)
        let liftTravel = integrate(liftVelocity.map { max(0, $0) }, liftTimes)
        let lowerTravel = integrate(lowerVelocity.map { max(0, -$0) }, lowerTimes)
        let liftWrong = integrate(liftVelocity.map { max(0, -$0) }, liftTimes)
        let lowerWrong = integrate(lowerVelocity.map { max(0, $0) }, lowerTimes)
        guard liftTravel > 0, lowerTravel > 0,
              liftWrong / liftTravel <= configuration.maximumOppositeTravelFraction,
              lowerWrong / lowerTravel <= configuration.maximumOppositeTravelFraction else { return nil }
        let pauseSlice = lower.lowerBound > lift.upperBound + 1
            ? Array(integration[(lift.upperBound + 1)..<lower.lowerBound]) : []
        let topPause: Double?
        if pauseSlice.isEmpty {
            topPause = 0
        } else if pauseSlice.allSatisfy({ abs($0.velocity) <= configuration.pauseSpeed }) {
            let duration = pauseSlice.last!.time - pauseSlice.first!.time + 1 / configuration.sampleRate
            topPause = duration >= configuration.minimumPauseDuration ? duration : 0
        } else {
            topPause = nil
        }
        let integrationTimes = integration.map(\.time)
        let integrationVelocity = integration.map(\.velocity)
        // Quality closure belongs only to this detector-owned cycle. The retained
        // estimator anchor may precede the detector departure landmark, but never
        // allow older motion to cancel a bad current-cycle closure.
        let owned = integration.filter {
            $0.time >= event.startTimestamp - configuration.reversalSearchTolerance! - 1e-9 &&
                $0.time <= endAnchor.time + 1e-9
        }
        guard owned.count > 1 else { return nil }
        let peakLift = peak(liftVelocity)
        let peakLower = peak(lowerVelocity.map { -$0 })
        let ownedClosure = integrate(owned.map(\.velocity), owned.map(\.time))
        let movementEstimates = Array(integration[lift]) + Array(integration[lower])
        let maximumVelocitySD = movementEstimates.map {
            sqrt(max(0, $0.velocityVariance))
        }.max() ?? .infinity
        let maximumAbsoluteBias = movementEstimates.map { abs($0.bias) }.max() ?? .infinity
        return .init(integrationStart: integrationTimes.first!, integrationEnd: integrationTimes.last!,
                     movementStart: liftTimes.first!, liftEnd: liftTimes.last!,
                     loweringStart: lowerTimes.first!, movementEnd: lowerTimes.last!,
                     liftingDuration: liftDuration, loweringDuration: lowerDuration,
                     topPauseDuration: topPause,
                     meanLiftingSpeed: liftTravel / liftDuration,
                     peakLiftingSpeed: peakLift,
                     meanLoweringSpeed: lowerTravel / lowerDuration,
                     peakLoweringSpeed: peakLower,
                     verticalClosure: ownedClosure,
                     endpointResidual: integrationVelocity.last!,
                     maximumVelocitySD: maximumVelocitySD,
                     maximumAbsoluteBias: maximumAbsoluteBias)
    }

    /// Chooses the highest-travel ordered region. Active samples separated by at
    /// most 80 ms remain one phase, preserving double peaks and short interruptions.
    private func dominantRegion(_ candidates: [Int], estimates: [Estimate], positive: Bool) -> ClosedRange<Int>? {
        guard let first = candidates.first else { return nil }
        var ranges: [ClosedRange<Int>] = []
        var start = first, previous = first
        for index in candidates.dropFirst() {
            let inactiveDuration = estimates[index].time - estimates[previous].time - 1 / configuration.sampleRate
            if inactiveDuration > configuration.movementInterruptionMergeDuration! + 1e-9 {
                ranges.append(start...previous); start = index
            }
            previous = index
        }
        ranges.append(start...previous)
        return ranges.max { lhs, rhs in
            let leftTimes = Array(estimates[lhs].map(\.time)), rightTimes = Array(estimates[rhs].map(\.time))
            let left = integrate(estimates[lhs].map { positive ? max(0, $0.velocity) : max(0, -$0.velocity) }, leftTimes)
            let right = integrate(estimates[rhs].map { positive ? max(0, $0.velocity) : max(0, -$0.velocity) }, rightTimes)
            return left < right
        }
    }

    private func boundaryPerturbationIsStable(event: V2CycleEvidence, startAnchor: VelocityAnchor,
                                              endAnchor: VelocityAnchor, baseline: ExtractedMotion) -> Bool {
        let delta = configuration.boundaryPerturbation!
        let perturbed = [-delta, delta].compactMap { shift -> ExtractedMotion? in
            let replacement = VelocityAnchor(id: endAnchor.id, time: endAnchor.time + shift,
                                             kind: endAnchor.kind, standardDeviation: endAnchor.standardDeviation,
                                             endpointStart: endAnchor.endpointStart + shift,
                                             endpointEnd: endAnchor.endpointEnd + shift,
                                             associatedCandidateIDs: endAnchor.associatedCandidateIDs,
                                             initialBias: nil, initialBiasStandardDeviation: nil)
            var anchors = velocityAnchors.filter { $0.id != endAnchor.id }
            anchors.append(replacement)
            return extractMotion(event: event, startAnchor: startAnchor, endAnchor: replacement,
                                 estimates: buildEstimates(anchors: anchors))
        }
        guard perturbed.count == 2 else { return false }
        let baselineValues = [baseline.meanLiftingSpeed, baseline.peakLiftingSpeed,
                              baseline.meanLoweringSpeed, baseline.peakLoweringSpeed]
        for value in perturbed {
            let values = [value.meanLiftingSpeed, value.peakLiftingSpeed,
                          value.meanLoweringSpeed, value.peakLoweringSpeed]
            for (candidate, original) in zip(values, baselineValues) {
                let allowed = max(configuration.maximumBoundaryPerturbationSpeed!,
                                  abs(original) * configuration.maximumBoundaryPerturbationFraction!)
                if abs(candidate - original) > allowed + 1e-12 { return false }
            }
        }
        return true
    }

    private func calculateV1(_ event: V2CycleEvidence, at time: Double, final: Bool) -> RepMotionMetrics {
        var result = RepMotionMetrics(id: event.id, setID: event.setID, updatedAt: time)
        func failure(_ reason: RepMetricsReason) -> RepMotionMetrics {
            var failed = result; failed.status = .unavailable; failed.reason = reason; return failed
        }
        guard event.startTimestamp.isFinite, event.topTimestamp.isFinite, event.completionTimestamp.isFinite,
              event.startTimestamp < event.topTimestamp, event.topTimestamp < event.completionTimestamp,
              event.completionTimestamp - event.startTimestamp <= configuration.maximumCycleDuration else { return failure(.invalidLandmarks) }
        // A labeled fallback, not an assertion that the detector landmark is a biomechanical boundary.
        result.liftingDuration = event.topTimestamp - event.startTimestamp
        result.loweringDuration = event.completionTimestamp - event.topTimestamp
        guard let start = frames.indices.last(where: {
            frames[$0].time <= event.startTimestamp && frames[$0].time >= event.startTimestamp - configuration.startLookback && quiet($0)
        }) else { return failure(.missingStartHold) }
        guard let end = frames.indices.first(where: {
            frames[$0].time >= event.completionTimestamp + configuration.filterSettling &&
            frames[$0].time <= event.completionTimestamp + configuration.endLookahead &&
            frames[$0].time - configuration.quietDuration >= event.completionTimestamp - configuration.endLookback && quiet($0)
        }) else { return final ? failure(.missingEndHold) : result }
        let window = Array(frames[start...end])
        let times = window.map(\.time)
        let duration = times.last! - times[0]
        guard duration > 0, window.count >= configuration.peakWindowSamples else { return failure(.invalidInterval) }
        var velocity = Array(repeating: 0.0, count: window.count)
        for i in 1..<window.count {
            velocity[i] = velocity[i - 1] + (window[i - 1].acceleration + window[i].acceleration) * 0.5 * (times[i] - times[i - 1])
        }
        let residual = velocity.last!
        result.integrationStart = times[0]; result.integrationEnd = times.last
        result.endpointVelocityResidual = residual; result.equivalentAccelerationBias = residual / duration
        guard abs(residual) <= configuration.maximumVelocityCorrection,
              abs(residual / duration) <= configuration.maximumEquivalentBias else { return failure(.excessiveEndpointCorrection) }
        for i in velocity.indices { velocity[i] -= residual * (times[i] - times[0]) / duration }
        let closure = integrate(velocity, times)
        result.verticalClosure = closure
        // Landmarks constrain the search; they do not impose a zero velocity at the top.
        func verticalQuiet(_ index: Int) -> Bool {
            abs(velocity[index]) <= configuration.pauseSpeed &&
                abs(window[index].acceleration) <= configuration.quietAccelerationG * configuration.standardGravity
        }
        let liftIndices = velocity.indices.filter {
            times[$0] <= event.topTimestamp + configuration.turnaroundTolerance &&
                velocity[$0] > configuration.movementSpeed
        }
        let lowerIndices = velocity.indices.filter {
            times[$0] >= event.topTimestamp - configuration.turnaroundTolerance &&
                velocity[$0] < -configuration.movementSpeed
        }
        guard let liftStart = liftIndices.first, let liftEnd = liftIndices.last,
              let lowerStart = lowerIndices.first, let lowerEnd = lowerIndices.last,
              liftEnd < lowerStart, times[liftEnd] - times[liftStart] >= configuration.minimumLegDuration,
              times[lowerEnd] - times[lowerStart] >= configuration.minimumLegDuration,
              event.topTimestamp >= times[liftEnd] - configuration.turnaroundTolerance,
              event.topTimestamp <= times[lowerStart] + configuration.turnaroundTolerance else { return failure(.ambiguousDirection) }
        let liftRange = liftStart...liftEnd, lowerRange = lowerStart...lowerEnd
        let liftTravel = integrate(velocity[liftRange].map { max(0, $0) }, Array(times[liftRange]))
        let lowerTravel = integrate(velocity[lowerRange].map { max(0, -$0) }, Array(times[lowerRange]))
        let liftWrong = integrate(velocity[liftRange].map { max(0, -$0) }, Array(times[liftRange]))
        let lowerWrong = integrate(velocity[lowerRange].map { max(0, $0) }, Array(times[lowerRange]))
        guard liftTravel > 0, lowerTravel > 0,
              liftWrong / liftTravel <= configuration.maximumOppositeTravelFraction,
              lowerWrong / lowerTravel <= configuration.maximumOppositeTravelFraction else { return failure(.ambiguousDirection) }
        result.movementStart = times[liftStart]; result.liftEnd = times[liftEnd]
        result.timingSource = .verticalMotion
        result.loweringStart = times[lowerStart]; result.movementEnd = times[lowerEnd]
        result.liftingDuration = times[liftEnd] - times[liftStart]
        result.loweringDuration = times[lowerEnd] - times[lowerStart]
        let pauseRange = (liftEnd + 1)..<lowerStart
        var pauseStart: Double?, longestPause = 0.0
        for index in pauseRange {
            if verticalQuiet(index) {
                pauseStart = pauseStart ?? times[index]
                longestPause = max(longestPause, times[index] - pauseStart! + 1 / configuration.sampleRate)
            } else { pauseStart = nil }
        }
        result.topPauseDuration = longestPause >= configuration.minimumPauseDuration ? longestPause : 0
        // Timing survives a final speed-quality failure. Never force height closure or rescale distance.
        guard abs(closure) <= configuration.maximumVerticalClosure else { return failure(.excessiveVerticalClosure) }
        let endQuietStart = times.last! - configuration.quietDuration
        guard velocity.indices.filter({ times[$0] >= endQuietStart }).allSatisfy({ abs(velocity[$0]) <= configuration.maximumQuietSpeed })
        else { return failure(.excessiveEndpointCorrection) }
        result.meanLiftingSpeed = liftTravel / result.liftingDuration!
        result.meanLoweringSpeed = lowerTravel / result.loweringDuration!
        result.peakLiftingSpeed = peak(Array(velocity[liftRange]))
        result.peakLoweringSpeed = peak(velocity[lowerRange].map { -$0 })
        result.status = .available; result.reason = nil
        return result
    }

    private func integrate(_ values: [Double], _ times: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        var area = 0.0
        for index in 1..<values.count {
            let average = (values[index - 1] + values[index]) * 0.5
            area += average * (times[index] - times[index - 1])
        }
        return area
    }

    private func peak(_ values: [Double]) -> Double {
        let count = configuration.peakWindowSamples
        guard values.count >= count else { return 0 }
        return (count...values.count).map { values[($0 - count)..<$0].reduce(0, +) / Double(count) }.max() ?? 0
    }
}

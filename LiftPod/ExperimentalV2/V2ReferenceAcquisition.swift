import Foundation

struct V2UniformSourceResampler: Sendable {
    func resample(_ samples: [RawMotionSample], profile: V2DSPProfile) throws -> MotionResamplingResult {
        _ = try profile.validated()
        var configuration = MotionResamplingConfiguration()
        configuration.outputRate = profile.identity.sampleRate
        configuration.outputInterval = 1 / profile.identity.sampleRate
        return try MotionResampler(configuration: configuration).resample(samples)
    }
}

struct V2ReferenceSample: Sendable, Equatable {
    let signal: Double
    let attitude: ExperimentalQuaternion
    let gravity: ExperimentalVector3
    let accelerationMagnitude: Double
    let gyroscopeMagnitude: Double
    let timestamp: Double
}

struct V2ReferenceAcquirer: Sendable {
    private(set) var measurements: V2ReferenceMeasurements?
    private var window: [V2ReferenceSample] = []

    mutating func reset() {
        window = []
        measurements = nil
    }

    mutating func observe(_ sample: ResampledMotionSample, profile: V2DSPProfile) -> V2ReferenceMeasurements? {
        guard measurements == nil else { return measurements }
        let identity = profile.identity
        let raw = identity.polarity * vector(sample, source: identity.signalSource).value(on: identity.projectionAxis)
        let item = V2ReferenceSample(signal: raw, attitude: sample.attitude, gravity: sample.gravity,
                                     accelerationMagnitude: sample.userAcceleration.magnitude,
                                     gyroscopeMagnitude: sample.rotationRate.magnitude,
                                     timestamp: sample.sourceTimestamp)
        window.append(item)
        let lowerTime = sample.sourceTimestamp - identity.reference.maximumWindow
        window.removeAll { $0.timestamp < lowerTime }
        guard window.count >= identity.reference.minimumSamples,
              let first = window.first,
              sample.sourceTimestamp - first.timestamp >= identity.reference.dwell else { return nil }

        let activities = window.map { max($0.accelerationMagnitude, 0.1 * $0.gyroscopeMagnitude) }
        let signals = window.map(\.signal)
        let acceleration = window.map(\.accelerationMagnitude)
        let gyroscope = window.map(\.gyroscopeMagnitude)
        let quarter = max(1, window.count / 4)
        let activityMedian = Self.percentile(activities, 0.5)
        let activityP90 = Self.percentile(activities, 0.9)
        let signalP05 = Self.percentile(signals, 0.05)
        let signalP95 = Self.percentile(signals, 0.95)
        let signalMedian = Self.percentile(signals, 0.5)
        let signalMAD = Self.mad(signals)
        let drift = abs(Self.percentile(Array(signals.prefix(quarter)), 0.5) -
                        Self.percentile(Array(signals.suffix(quarter)), 0.5))
        let span = identity.localCycle.trainedSpan
        guard activityMedian <= identity.reference.quietActivityThreshold * 1.25,
              activityP90 <= identity.reference.quietActivityThreshold * 3,
              signalP95 - signalP05 <= span * 0.12,
              signalMAD <= max(0.015, span * 0.03),
              drift <= span * 0.08,
              signals.allSatisfy({ $0 >= identity.reference.rawLower && $0 <= identity.reference.rawUpper }) else {
            return nil
        }
        let result = V2ReferenceMeasurements(
            neutralSignal: signalMedian,
            referenceAttitude: Self.quaternionMedoid(window.map(\.attitude)),
            referenceGravity: .init(x: Self.percentile(window.map(\.gravity.x), 0.5),
                                    y: Self.percentile(window.map(\.gravity.y), 0.5),
                                    z: Self.percentile(window.map(\.gravity.z), 0.5)),
            activityMedian: activityMedian, activityP90: activityP90,
            signalP05: signalP05, signalP95: signalP95, signalMAD: signalMAD,
            earlyLateDrift: drift, accelerationNoiseMAD: Self.mad(acceleration), gyroNoiseMAD: Self.mad(gyroscope),
            observedSampleRate: Double(window.count - 1) / max(1e-9, sample.sourceTimestamp - first.timestamp),
            sampleCount: window.count, startTimestamp: first.timestamp, endTimestamp: sample.sourceTimestamp
        )
        measurements = result
        return result
    }

    private func vector(_ sample: ResampledMotionSample, source: ExperimentalSignalSource) -> ExperimentalVector3 {
        source == .gravity ? sample.gravity : sample.userAcceleration
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = min(1, max(0, fraction)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)); let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    static func mad(_ values: [Double]) -> Double {
        let center = percentile(values, 0.5)
        return percentile(values.map { abs($0 - center) }, 0.5)
    }

    static func quaternionMedoid(_ values: [ExperimentalQuaternion]) -> ExperimentalQuaternion {
        let normalized = values.compactMap { $0.normalized() }
        guard let first = normalized.first else { return .init(w: 1, x: 0, y: 0, z: 0) }
        let aligned = normalized.map { first.dot($0) < 0 ? $0.negated() : $0 }
        return aligned.enumerated().min { left, right in
            let leftCost = aligned.reduce(0) { $0 + 2 * acos(min(1, abs(left.element.dot($1)))) }
            let rightCost = aligned.reduce(0) { $0 + 2 * acos(min(1, abs(right.element.dot($1)))) }
            return leftCost == rightCost ? left.offset < right.offset : leftCost < rightCost
        }?.element.normalized() ?? first
    }
}

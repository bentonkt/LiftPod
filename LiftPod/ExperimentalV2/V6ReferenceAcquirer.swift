import Foundation

struct V6ReferenceAcquirer: Sendable {
    private(set) var measurements: V2ReferenceMeasurements?
    private var samples: [V2ReferenceSample] = []

    mutating func reset() {
        measurements = nil
        samples.removeAll(keepingCapacity: true)
    }

    mutating func observe(_ sample: ResampledMotionSample, profile: V2DSPProfile) -> V2ReferenceMeasurements? {
        guard measurements == nil else { return measurements }
        let adaptive = profile.identity.algorithm == .adaptiveAxis
        let axis = V6ProfileConstants.fixedAngularAxis
        let raw = adaptive ? sample.gravity.magnitude :
            (profile.identity.algorithm == .fixedAxisAngular ? V6VectorMath.dot(sample.gravity, axis) :
                profile.identity.polarity * sample.gravity.value(on: profile.identity.projectionAxis))
        samples.append(.init(signal: raw, attitude: sample.attitude, gravity: sample.gravity,
                             accelerationMagnitude: sample.userAcceleration.magnitude,
                             gyroscopeMagnitude: sample.rotationRate.magnitude,
                             timestamp: sample.sourceTimestamp))
        let cutoff = sample.sourceTimestamp - profile.identity.reference.maximumWindow
        samples.removeAll { $0.timestamp < cutoff }
        guard samples.count >= profile.identity.reference.minimumSamples,
              let first = samples.first,
              sample.sourceTimestamp - first.timestamp >= profile.identity.reference.dwell else { return nil }

        let signals = samples.map(\.signal)
        guard signals.allSatisfy({ $0 >= profile.identity.reference.rawLower && $0 <= profile.identity.reference.rawUpper }) else {
            return nil
        }
        let activities = samples.map { max($0.accelerationMagnitude, 0.1 * $0.gyroscopeMagnitude) }.sorted()
        let sortedSignals = signals.sorted()
        let quarter = max(1, signals.count / 4)
        let activityMedian = Self.median(activities)
        let activityP90 = Self.quantile(activities, 0.90)
        let p05 = Self.quantile(sortedSignals, 0.05), p95 = Self.quantile(sortedSignals, 0.95)
        let signalMAD = Self.mad(signals)
        let drift = abs(Self.median(Array(signals.prefix(quarter)).sorted()) -
                        Self.median(Array(signals.suffix(quarter)).sorted()))
        let span = profile.identity.localCycle.trainedSpan
        guard activityMedian <= profile.identity.reference.quietActivityThreshold * 1.25,
              activityP90 <= profile.identity.reference.quietActivityThreshold * 3,
              p95 - p05 <= span * 0.12,
              signalMAD <= max(0.015, span * 0.03),
              drift <= span * 0.08 else { return nil }

        let gravityValues = samples.map(\.gravity)
        let gravity: ExperimentalVector3
        if let adaptiveConfiguration = profile.identity.adaptiveAxis {
            let center = V6VectorMath.mean(gravityValues)
            let deviations = gravityValues.map { V6VectorMath.angularDistance($0, center) }.sorted()
            guard Self.quantile(deviations, 0.95) <= adaptiveConfiguration.maximumPreparationVariation,
                  let normalized = V6VectorMath.unit(center) else { return nil }
            gravity = normalized
        } else {
            gravity = .init(x: Self.median(gravityValues.map(\.x).sorted()),
                            y: Self.median(gravityValues.map(\.y).sorted()),
                            z: Self.median(gravityValues.map(\.z).sorted()))
        }
        let result = V2ReferenceMeasurements(
            neutralSignal: Self.median(sortedSignals),
            referenceAttitude: Self.quaternionMedoid(samples.map(\.attitude)), referenceGravity: gravity,
            activityMedian: activityMedian, activityP90: activityP90, signalP05: p05, signalP95: p95,
            signalMAD: signalMAD, earlyLateDrift: drift,
            accelerationNoiseMAD: Self.mad(samples.map(\.accelerationMagnitude)),
            gyroNoiseMAD: Self.mad(samples.map(\.gyroscopeMagnitude)),
            observedSampleRate: Double(samples.count - 1) / max(1e-9, sample.sourceTimestamp - first.timestamp),
            sampleCount: samples.count, startTimestamp: first.timestamp, endTimestamp: sample.sourceTimestamp
        )
        measurements = result
        return result
    }

    static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func quantile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    static func mad(_ values: [Double]) -> Double {
        let center = median(values.sorted())
        return median(values.map { abs($0 - center) }.sorted())
    }

    static func quaternionMedoid(_ values: [ExperimentalQuaternion]) -> ExperimentalQuaternion {
        let normalized = values.compactMap { $0.normalized() }
        guard var selected = normalized.first else { return .init(w: 1, x: 0, y: 0, z: 0) }
        func cost(_ value: ExperimentalQuaternion) -> Double {
            normalized.reduce(0) { $0 + 2 * acos(min(1, max(0, abs(value.dot($1))))) }
        }
        var best = cost(selected)
        for value in normalized.dropFirst() {
            let candidate = cost(value)
            if candidate < best { best = candidate; selected = value }
        }
        return selected
    }
}

enum V6ProfileConstants {
    static let fixedAngularAxis = ExperimentalVector3(
        x: 0.6107710031427952, y: -0.41711251936049715, z: 0.6730348638166395
    )
}

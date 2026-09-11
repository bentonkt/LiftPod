import Foundation

struct MotionPreprocessingEngine: Sendable {
    private struct Projection: Sendable {
        let gravityMagnitude: Double
        let gyroscopeMagnitude: Double
        let verticalAcceleration: Double
    }

    func process(
        samples: [RawMotionSample],
        configuration: PreprocessingConfiguration = PreprocessingConfiguration()
    ) throws -> PreprocessingResult {
        let configuration = try configuration.validated()
        let maximumGap = try validate(samples: samples, configuration: configuration)
        let projections = try samples.map {
            try Self.projection(for: $0, configuration: configuration)
        }
        let calibrationEndIndex = calibrationEndIndex(
            samples: samples,
            duration: configuration.calibrationDuration
        )
        let calibration = calibrationResult(
            samples: samples,
            projections: projections,
            endIndex: calibrationEndIndex,
            configuration: configuration
        )
        guard calibration.passed else { throw PreprocessingError.calibrationFailed(calibration) }

        let corrected = projections.map { $0.verticalAcceleration - calibration.verticalBias }
        let timestamps = samples.map(\.sourceTimestamp)
        let filtered = try Self.lowPassFilter(
            values: corrected,
            timestamps: timestamps,
            cutoffFrequency: configuration.lowPassCutoffFrequency,
            maximumGap: configuration.maximumSourceGap,
            indices: samples.map(\.index)
        )

        let frames = samples.indices.map { index in
            ProcessedMotionFrame(
                index: samples[index].index,
                sourceTimestamp: samples[index].sourceTimestamp,
                deltaTime: index == 0 ? 0 : timestamps[index] - timestamps[index - 1],
                sensorLocation: samples[index].sensorLocation,
                gravityMagnitudeG: projections[index].gravityMagnitude,
                gyroscopeMagnitudeRadiansPerSecond: projections[index].gyroscopeMagnitude,
                verticalAccelerationRawMetersPerSecondSquared: projections[index].verticalAcceleration,
                verticalAccelerationCorrectedMetersPerSecondSquared: corrected[index],
                verticalAccelerationFilteredMetersPerSecondSquared: filtered[index],
                isCalibrationSample: index <= calibrationEndIndex
            )
        }

        let duration = timestamps[timestamps.count - 1] - timestamps[0]
        return PreprocessingResult(
            configuration: configuration,
            calibration: calibration,
            frames: frames,
            totalSourceDuration: duration,
            effectiveSampleRate: Double(samples.count - 1) / duration,
            maximumSourceTimeGap: maximumGap
        )
    }

    func validate(
        samples: [RawMotionSample],
        configuration: PreprocessingConfiguration = PreprocessingConfiguration()
    ) throws -> Double {
        let configuration = try configuration.validated()
        guard !samples.isEmpty else { throw PreprocessingError.emptySamples }
        guard samples.count >= 2 else { throw PreprocessingError.insufficientSamples(actual: samples.count) }

        var maximumGap = 0.0
        for index in samples.indices {
            let sample = samples[index]
            try Self.requireFinite(sample.gravityX, sample.gravityY, sample.gravityZ, field: "gravity", index: sample.index)
            try Self.requireFinite(sample.userAccelerationX, sample.userAccelerationY, sample.userAccelerationZ, field: "user acceleration", index: sample.index)
            try Self.requireFinite(sample.rotationRateX, sample.rotationRateY, sample.rotationRateZ, field: "rotation rate", index: sample.index)
            _ = try Self.projection(for: sample, configuration: configuration)

            guard sample.sourceTimestamp.isFinite else {
                throw PreprocessingError.invalidTimestamp(index: sample.index, reason: "value is not finite")
            }
            guard index > 0 else { continue }
            let previous = samples[index - 1]
            guard sample.index > previous.index else {
                throw PreprocessingError.nonIncreasingIndex(
                    position: index + 1,
                    previous: previous.index,
                    current: sample.index
                )
            }
            let gap = sample.sourceTimestamp - previous.sourceTimestamp
            guard gap.isFinite, gap > 0 else {
                throw PreprocessingError.invalidTimestamp(
                    index: sample.index,
                    reason: "timestamps must be strictly increasing"
                )
            }
            guard gap <= configuration.maximumSourceGap else {
                throw PreprocessingError.excessiveSourceGap(
                    index: sample.index,
                    gap: gap,
                    maximum: configuration.maximumSourceGap
                )
            }
            maximumGap = max(maximumGap, gap)
        }
        return maximumGap
    }

    static func verticalAcceleration(
        for sample: RawMotionSample,
        configuration: PreprocessingConfiguration = PreprocessingConfiguration()
    ) throws -> Double {
        try projection(for: sample, configuration: configuration.validated()).verticalAcceleration
    }

    static func lowPassFilter(
        values: [Double],
        timestamps: [Double],
        cutoffFrequency: Double,
        maximumGap: Double,
        indices: [UInt64]? = nil
    ) throws -> [Double] {
        guard values.count == timestamps.count else {
            throw PreprocessingError.invalidConfiguration(["filter values and timestamps must have equal counts"])
        }
        guard cutoffFrequency.isFinite, cutoffFrequency > 0,
              maximumGap.isFinite, maximumGap > 0 else {
            throw PreprocessingError.invalidConfiguration(["filter cutoff and maximum gap must be finite and greater than zero"])
        }
        guard !values.isEmpty else { return [] }
        guard values[0].isFinite else {
            throw PreprocessingError.nonFiniteFilterOutput(index: indices?[0] ?? 0)
        }

        var output = [values[0]]
        output.reserveCapacity(values.count)
        for index in 1..<values.count {
            let callbackIndex = indices?[index] ?? UInt64(index)
            let deltaTime = timestamps[index] - timestamps[index - 1]
            guard deltaTime.isFinite, deltaTime > 0 else {
                throw PreprocessingError.invalidTimestamp(index: callbackIndex, reason: "filter interval must be finite and positive")
            }
            guard deltaTime <= maximumGap else {
                throw PreprocessingError.excessiveSourceGap(index: callbackIndex, gap: deltaTime, maximum: maximumGap)
            }
            let alpha = 1 - exp(-2 * Double.pi * cutoffFrequency * deltaTime)
            let filtered = output[index - 1] + alpha * (values[index] - output[index - 1])
            guard filtered.isFinite else {
                throw PreprocessingError.nonFiniteFilterOutput(index: callbackIndex)
            }
            output.append(filtered)
        }
        return output
    }

    private func calibrationEndIndex(samples: [RawMotionSample], duration: Double) -> Int {
        let target = samples[0].sourceTimestamp + duration
        return samples.firstIndex(where: { $0.sourceTimestamp >= target }) ?? samples.count - 1
    }

    private func calibrationResult(
        samples: [RawMotionSample],
        projections: [Projection],
        endIndex: Int,
        configuration: PreprocessingConfiguration
    ) -> CalibrationResult {
        var accelerationStatistics = RunningStatistics()
        var gravityStatistics = RunningStatistics()
        var gyroscopeMeanSquare = RunningMean()
        for index in 0...endIndex {
            accelerationStatistics.add(projections[index].verticalAcceleration)
            gravityStatistics.add(projections[index].gravityMagnitude)
            gyroscopeMeanSquare.add(projections[index].gyroscopeMagnitude * projections[index].gyroscopeMagnitude)
        }

        let duration = samples[endIndex].sourceTimestamp - samples[0].sourceTimestamp
        let accelerationDeviation = sqrt(accelerationStatistics.populationVariance)
        let gyroscopeRMS = sqrt(gyroscopeMeanSquare.mean)
        var failures: [CalibrationFailureReason] = []
        if duration < configuration.calibrationDuration {
            failures.append(.insufficientDuration(required: configuration.calibrationDuration, actual: duration))
        }
        if accelerationStatistics.count < configuration.minimumCalibrationSampleCount {
            failures.append(.insufficientSamples(
                required: configuration.minimumCalibrationSampleCount,
                actual: accelerationStatistics.count
            ))
        }
        if accelerationDeviation > configuration.maximumCalibrationAccelerationStandardDeviation {
            failures.append(.accelerationVariation(
                limit: configuration.maximumCalibrationAccelerationStandardDeviation,
                actual: accelerationDeviation
            ))
        }
        if gyroscopeRMS > configuration.maximumCalibrationGyroscopeRMS {
            failures.append(.gyroscopeMotion(
                limit: configuration.maximumCalibrationGyroscopeRMS,
                actual: gyroscopeRMS
            ))
        }

        return CalibrationResult(
            startSourceTimestamp: samples[0].sourceTimestamp,
            endSourceTimestamp: samples[endIndex].sourceTimestamp,
            duration: duration,
            sampleCount: accelerationStatistics.count,
            meanGravityMagnitude: gravityStatistics.mean,
            verticalBias: accelerationStatistics.mean,
            verticalAccelerationStandardDeviation: accelerationDeviation,
            gyroscopeRMSMagnitude: gyroscopeRMS,
            failureReasons: failures
        )
    }

    private static func projection(
        for sample: RawMotionSample,
        configuration: PreprocessingConfiguration
    ) throws -> Projection {
        let gravitySquared = sample.gravityX * sample.gravityX
            + sample.gravityY * sample.gravityY
            + sample.gravityZ * sample.gravityZ
        let gravityMagnitude = sqrt(gravitySquared)
        guard gravityMagnitude.isFinite,
              gravityMagnitude >= configuration.minimumGravityMagnitude,
              gravityMagnitude <= configuration.maximumGravityMagnitude else {
            throw PreprocessingError.invalidGravity(index: sample.index, magnitude: gravityMagnitude)
        }
        let inverseMagnitude = 1 / gravityMagnitude
        let upX = -sample.gravityX * inverseMagnitude
        let upY = -sample.gravityY * inverseMagnitude
        let upZ = -sample.gravityZ * inverseMagnitude
        let verticalAccelerationG = sample.userAccelerationX * upX
            + sample.userAccelerationY * upY
            + sample.userAccelerationZ * upZ
        let verticalAcceleration = verticalAccelerationG * configuration.standardGravity
        let gyroscopeMagnitude = sqrt(
            sample.rotationRateX * sample.rotationRateX
                + sample.rotationRateY * sample.rotationRateY
                + sample.rotationRateZ * sample.rotationRateZ
        )
        guard verticalAcceleration.isFinite else {
            throw PreprocessingError.nonFiniteComponent(index: sample.index, field: "projected acceleration")
        }
        guard gyroscopeMagnitude.isFinite else {
            throw PreprocessingError.nonFiniteComponent(index: sample.index, field: "gyroscope magnitude")
        }
        return Projection(
            gravityMagnitude: gravityMagnitude,
            gyroscopeMagnitude: gyroscopeMagnitude,
            verticalAcceleration: verticalAcceleration
        )
    }

    private static func requireFinite(
        _ x: Double,
        _ y: Double,
        _ z: Double,
        field: String,
        index: UInt64
    ) throws {
        guard x.isFinite, y.isFinite, z.isFinite else {
            throw PreprocessingError.nonFiniteComponent(index: index, field: field)
        }
    }
}

private struct RunningStatistics {
    private(set) var count = 0
    private(set) var mean = 0.0
    private var sumOfSquaredDifferences = 0.0

    mutating func add(_ value: Double) {
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        let secondDelta = value - mean
        sumOfSquaredDifferences += delta * secondDelta
    }

    var populationVariance: Double {
        count == 0 ? 0 : max(0, sumOfSquaredDifferences / Double(count))
    }
}

private struct RunningMean {
    private(set) var count = 0
    private(set) var mean = 0.0

    mutating func add(_ value: Double) {
        count += 1
        mean += (value - mean) / Double(count)
    }
}

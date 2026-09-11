import Foundation

struct MotionResamplingResult: Sendable, Equatable {
    let samples: [ResampledMotionSample]
    let qualityTransitions: [QualityTransition]
    let discontinuityEpochs: Set<Int>
}

struct MotionResampler: Sendable {
    let configuration: ExperimentalV1Configuration

    init(configuration: ExperimentalV1Configuration = ExperimentalV1Configuration()) {
        self.configuration = configuration
    }

    func resample(_ input: [RawMotionSample]) throws -> MotionResamplingResult {
        let configuration = try configuration.validated()
        guard !input.isEmpty else { throw ExperimentalV1Error.emptyInput }

        var output: [ResampledMotionSample] = []
        var transitions: [QualityTransition] = []
        var discontinuities = Set<Int>()
        var previous: ValidatedSample?
        var anchor = 0.0
        var nextGrid = 0.0
        var epoch = 0

        for (sequence, raw) in input.enumerated() {
            let current: ValidatedSample
            do {
                current = try validated(raw, sequence: sequence)
            } catch {
                epoch += 1
                discontinuities.insert(epoch)
                transitions.append(QualityTransition(
                    sourceTimestamp: raw.sourceTimestamp.isFinite ? raw.sourceTimestamp : (previous?.timestamp ?? 0),
                    state: .invalidInput,
                    reason: error.localizedDescription
                ))
                previous = nil
                continue
            }

            guard let left = previous else {
                anchor = current.timestamp
                nextGrid = anchor + configuration.outputInterval
                output.append(current.resampled(anchor: anchor, time: current.timestamp, status: .delivered, epoch: epoch))
                previous = current
                transitions.append(QualityTransition(sourceTimestamp: current.timestamp, state: .warmingUp, reason: "Stream anchored"))
                continue
            }

            let gap = current.timestamp - left.timestamp
            if abs(gap) <= configuration.comparisonEpsilon {
                continue
            }
            if gap < 0 {
                epoch += 1
                discontinuities.insert(epoch)
                transitions.append(QualityTransition(sourceTimestamp: current.timestamp, state: .invalidInput, reason: "Source timestamp moved backward"))
                anchor = current.timestamp
                nextGrid = anchor + configuration.outputInterval
                output.append(current.resampled(anchor: anchor, time: current.timestamp, status: .delivered, epoch: epoch))
                previous = current
                continue
            }

            guard gap <= configuration.maximumInterpolationGap + configuration.comparisonEpsilon,
                  attitudeRate(left.attitude, current.attitude, gap: gap) <= configuration.maximumAttitudeAngularRate else {
                epoch += 1
                discontinuities.insert(epoch)
                let degraded = gap > configuration.degradedGapThreshold + configuration.comparisonEpsilon
                transitions.append(QualityTransition(
                    sourceTimestamp: current.timestamp,
                    state: degraded ? .degraded : .invalidInput,
                    reason: gap > configuration.maximumInterpolationGap ? "Gap cannot be interpolated" : "Attitude angular rate exceeded limit"
                ))
                anchor = current.timestamp
                nextGrid = anchor + configuration.outputInterval
                output.append(current.resampled(anchor: anchor, time: current.timestamp, status: .delivered, epoch: epoch))
                previous = current
                continue
            }

            while nextGrid <= current.timestamp + configuration.comparisonEpsilon {
                let fraction = min(1, max(0, (nextGrid - left.timestamp) / gap))
                let directlyDelivered = abs(nextGrid - current.timestamp) <= configuration.comparisonEpsilon
                output.append(interpolate(
                    left: left,
                    right: current,
                    fraction: fraction,
                    anchor: anchor,
                    time: nextGrid,
                    status: directlyDelivered ? .delivered : .interpolated,
                    epoch: epoch
                ))
                nextGrid += configuration.outputInterval
            }
            previous = current
        }

        return MotionResamplingResult(samples: output, qualityTransitions: transitions, discontinuityEpochs: discontinuities)
    }

    private func validated(_ sample: RawMotionSample, sequence: Int) throws -> ValidatedSample {
        let numbers = [sample.sourceTimestamp, sample.receiptUptime,
                       sample.userAccelerationX, sample.userAccelerationY, sample.userAccelerationZ,
                       sample.rotationRateX, sample.rotationRateY, sample.rotationRateZ,
                       sample.gravityX, sample.gravityY, sample.gravityZ,
                       sample.quaternionW, sample.quaternionX, sample.quaternionY, sample.quaternionZ,
                       sample.roll, sample.pitch, sample.yaw]
        guard numbers.allSatisfy(\.isFinite) else {
            throw ExperimentalV1Error.invalidInput(sequence: sequence, reason: "timestamp or sensor component is non-finite")
        }
        let attitude = ExperimentalQuaternion(w: sample.quaternionW, x: sample.quaternionX,
                                              y: sample.quaternionY, z: sample.quaternionZ)
        guard let attitude = attitude.normalized() else {
            throw ExperimentalV1Error.invalidInput(sequence: sequence, reason: "attitude quaternion is invalid")
        }
        return ValidatedSample(
            timestamp: sample.sourceTimestamp,
            sensorSide: ExperimentalSensorSide(location: sample.sensorLocation),
            userAcceleration: .init(x: sample.userAccelerationX, y: sample.userAccelerationY, z: sample.userAccelerationZ),
            rotationRate: .init(x: sample.rotationRateX, y: sample.rotationRateY, z: sample.rotationRateZ),
            gravity: .init(x: sample.gravityX, y: sample.gravityY, z: sample.gravityZ),
            attitude: attitude
        )
    }

    private func interpolate(
        left: ValidatedSample,
        right: ValidatedSample,
        fraction: Double,
        anchor: Double,
        time: Double,
        status: InterpolationStatus,
        epoch: Int
    ) -> ResampledMotionSample {
        ResampledMotionSample(
            sourceTimestamp: time,
            sessionTime: time - anchor,
            sensorSide: right.sensorSide,
            userAcceleration: .interpolate(left.userAcceleration, right.userAcceleration, fraction: fraction),
            rotationRate: .interpolate(left.rotationRate, right.rotationRate, fraction: fraction),
            gravity: .interpolate(left.gravity, right.gravity, fraction: fraction),
            attitude: Self.slerp(left.attitude, right.attitude, fraction: fraction),
            interpolationStatus: status,
            epoch: epoch
        )
    }

    private func attitudeRate(_ left: ExperimentalQuaternion, _ right: ExperimentalQuaternion, gap: Double) -> Double {
        2 * acos(min(1, max(-1, abs(left.dot(right))))) / gap
    }

    static func slerp(_ start: ExperimentalQuaternion, _ end: ExperimentalQuaternion, fraction: Double) -> ExperimentalQuaternion {
        guard let first = start.normalized(), var second = end.normalized() else { return start }
        var cosine = first.dot(second)
        if cosine < 0 {
            second = second.negated()
            cosine = -cosine
        }
        cosine = min(1, max(-1, cosine))
        if cosine > 0.9995 {
            return ExperimentalQuaternion(
                w: first.w + fraction * (second.w - first.w),
                x: first.x + fraction * (second.x - first.x),
                y: first.y + fraction * (second.y - first.y),
                z: first.z + fraction * (second.z - first.z)
            ).normalized() ?? first
        }
        let angle = acos(cosine)
        let scale = sin(angle)
        let leftWeight = sin((1 - fraction) * angle) / scale
        let rightWeight = sin(fraction * angle) / scale
        return ExperimentalQuaternion(
            w: first.w * leftWeight + second.w * rightWeight,
            x: first.x * leftWeight + second.x * rightWeight,
            y: first.y * leftWeight + second.y * rightWeight,
            z: first.z * leftWeight + second.z * rightWeight
        ).normalized() ?? first
    }
}

private struct ValidatedSample {
    let timestamp: Double
    let sensorSide: ExperimentalSensorSide?
    let userAcceleration: ExperimentalVector3
    let rotationRate: ExperimentalVector3
    let gravity: ExperimentalVector3
    let attitude: ExperimentalQuaternion

    func resampled(anchor: Double, time: Double, status: InterpolationStatus, epoch: Int) -> ResampledMotionSample {
        ResampledMotionSample(sourceTimestamp: time, sessionTime: time - anchor, sensorSide: sensorSide,
                              userAcceleration: userAcceleration, rotationRate: rotationRate, gravity: gravity,
                              attitude: attitude, interpolationStatus: status, epoch: epoch)
    }
}

private extension ExperimentalSensorSide {
    init?(location: HeadphoneSensorLocation) {
        switch location {
        case .leftHeadphone: self = .left
        case .rightHeadphone: self = .right
        case .default, .unknown: return nil
        }
    }
}

struct ScalarSignalExtractor: Sendable {
    let profile: ExperimentalProfile

    func value(for sample: ResampledMotionSample, neutralReference: Double? = nil) -> Double {
        let vector = profile.signalSource == .gravity ? sample.gravity : sample.userAcceleration
        return profile.polarity * (vector.value(on: profile.axis) - (neutralReference ?? 0))
    }
}

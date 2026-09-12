import Foundation

enum V2StreamFailure: Error { case nonFinite, backwardClock }

struct V2StreamStep: Sendable {
    let samples: [ResampledMotionSample]
    let discontinuity: QualityTransition?
}

/// Bounded, source-time streaming preprocessing. The version freezes these stream policies.
/// Existing archives without this version retain their original batch-resampling verification.
struct V2StreamingResampler: Sendable {
    static let version = "incremental-stream-v1"
    static let recoveryDuration = 0.25
    private let configuration = MotionResamplingConfiguration()
    private var previous: ResampledMotionSample?
    private var previousSource: Double?
    private var previousReceipt: Double?
    private var anchor: Double?
    private var gridIndex = 0
    private var epoch = 0

    mutating func append(_ raw: RawMotionSample) throws -> V2StreamStep {
        let values = [raw.sourceTimestamp, raw.receiptUptime, raw.userAccelerationX, raw.userAccelerationY,
                      raw.userAccelerationZ, raw.rotationRateX, raw.rotationRateY, raw.rotationRateZ,
                      raw.gravityX, raw.gravityY, raw.gravityZ, raw.quaternionW, raw.quaternionX,
                      raw.quaternionY, raw.quaternionZ, raw.roll, raw.pitch, raw.yaw]
        guard values.allSatisfy(\.isFinite) else { throw V2StreamFailure.nonFinite }
        let time = raw.sourceTimestamp
        if let previousSource {
            guard time >= previousSource - configuration.comparisonEpsilon else { throw V2StreamFailure.backwardClock }
            if abs(time - previousSource) <= configuration.comparisonEpsilon {
                return .init(samples: [], discontinuity: nil)
            }
        }
        previousSource = time
        let stale = previousReceipt.map { raw.receiptUptime - $0 > configuration.receiptStalenessThreshold } ?? false
        previousReceipt = raw.receiptUptime
        let quaternion = ExperimentalQuaternion(w: raw.quaternionW, x: raw.quaternionX,
                                                 y: raw.quaternionY, z: raw.quaternionZ).normalized()
        let gravity = ExperimentalVector3(x: raw.gravityX, y: raw.gravityY, z: raw.gravityZ)
        guard let quaternion, gravity.magnitude > 1e-9 else {
            previous = nil; epoch += 1
            return .init(samples: [], discontinuity: .init(sourceTimestamp: time, state: .degraded,
                reason: "Invalid attitude or gravity frame; current movement discarded"))
        }
        anchor = anchor ?? time
        let side: ExperimentalSensorSide?
        switch raw.sensorLocation {
        case .rightHeadphone: side = .right
        case .leftHeadphone: side = .left
        default: side = nil
        }
        let current = ResampledMotionSample(sourceTimestamp: time, sessionTime: time - anchor!, sensorSide: side,
            userAcceleration: .init(x: raw.userAccelerationX, y: raw.userAccelerationY, z: raw.userAccelerationZ),
            rotationRate: .init(x: raw.rotationRateX, y: raw.rotationRateY, z: raw.rotationRateZ), gravity: gravity,
            attitude: quaternion, interpolationStatus: .delivered, epoch: epoch)
        var notice: QualityTransition?
        if let left = previous {
            let gap = time - left.sourceTimestamp
            let rate = 2 * acos(min(1, abs(left.attitude.dot(current.attitude)))) / gap
            if gap > configuration.maximumInterpolationGap + configuration.comparisonEpsilon ||
                rate > configuration.maximumAttitudeAngularRate || stale {
                epoch += 1
                let reason = stale ? "Delivery paused; current movement discarded" :
                    (gap > configuration.maximumInterpolationGap + configuration.comparisonEpsilon ?
                     String(format: "Source gap %.0f ms; current movement discarded", gap * 1000) :
                     "Attitude discontinuity; current movement discarded")
                notice = .init(sourceTimestamp: time, state: stale ? .stale : .degraded, reason: reason)
                previous = nil
            }
        }
        guard let left = previous else {
            // Keep the session anchor fixed and advance to the next global grid point. No bridge across a failure.
            gridIndex = max(gridIndex, Int(ceil((time - anchor!) / configuration.outputInterval - configuration.comparisonEpsilon)))
            previous = current
            if abs(anchor! + Double(gridIndex) * configuration.outputInterval - time) <= configuration.comparisonEpsilon {
                gridIndex += 1
                return .init(samples: [frame(current, at: time)], discontinuity: notice)
            }
            return .init(samples: [], discontinuity: notice)
        }
        var output: [ResampledMotionSample] = []
        var gridTime = anchor! + Double(gridIndex) * configuration.outputInterval
        while gridTime <= time + configuration.comparisonEpsilon {
            let fraction = min(1, max(0, (gridTime - left.sourceTimestamp) / (time - left.sourceTimestamp)))
            output.append(.init(sourceTimestamp: gridTime, sessionTime: gridTime - anchor!, sensorSide: side,
                userAcceleration: .interpolate(left.userAcceleration, current.userAcceleration, fraction: fraction),
                rotationRate: .interpolate(left.rotationRate, current.rotationRate, fraction: fraction),
                gravity: .interpolate(left.gravity, current.gravity, fraction: fraction),
                attitude: MotionResampler.slerp(left.attitude, current.attitude, fraction: fraction),
                interpolationStatus: abs(gridTime - time) <= configuration.comparisonEpsilon ? .delivered : .interpolated,
                epoch: epoch))
            gridIndex += 1
            gridTime = anchor! + Double(gridIndex) * configuration.outputInterval
        }
        previous = current
        return .init(samples: output, discontinuity: notice)
    }

    private func frame(_ input: ResampledMotionSample, at time: Double) -> ResampledMotionSample {
        .init(sourceTimestamp: time, sessionTime: time - anchor!, sensorSide: input.sensorSide,
              userAcceleration: input.userAcceleration, rotationRate: input.rotationRate,
              gravity: input.gravity, attitude: input.attitude, interpolationStatus: .delivered, epoch: epoch)
    }
}

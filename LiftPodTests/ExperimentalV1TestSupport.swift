import Foundation
@testable import LiftPod

func experimentalRawSample(
    index: UInt64,
    time: Double,
    side: HeadphoneSensorLocation = .rightHeadphone,
    acceleration: ExperimentalVector3 = .init(x: 0, y: 0, z: 0),
    gravity: ExperimentalVector3 = .init(x: 0, y: 0, z: -1),
    rotation: ExperimentalVector3 = .init(x: 0, y: 0, z: 0),
    attitude: ExperimentalQuaternion = .init(w: 1, x: 0, y: 0, z: 0),
    receiptTime: Double? = nil,
    roll: Double = 0
) -> RawMotionSample {
    RawMotionSample(index: index, sourceTimestamp: time, receiptUptime: receiptTime ?? time,
                    sensorLocation: side,
                    userAccelerationX: acceleration.x, userAccelerationY: acceleration.y, userAccelerationZ: acceleration.z,
                    gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z,
                    rotationRateX: rotation.x, rotationRateY: rotation.y, rotationRateZ: rotation.z,
                    quaternionW: attitude.w, quaternionX: attitude.x, quaternionY: attitude.y, quaternionZ: attitude.z,
                    roll: roll, pitch: 0, yaw: 0)
}

func resampledSignals(
    _ values: [Double],
    exercise: ExperimentalExercise,
    side: ExperimentalSensorSide = .right,
    epoch: Int = 0
) -> [ResampledMotionSample] {
    values.enumerated().map { index, value in
        let acceleration: ExperimentalVector3
        let gravity: ExperimentalVector3
        switch exercise {
        case .bicepsCurl:
            acceleration = .init(x: 0, y: 0, z: 0); gravity = .init(x: value, y: 0, z: -1)
        case .lateralRaise:
            acceleration = .init(x: value, y: 0, z: 0); gravity = .init(x: 0, y: 0, z: -1)
        case .overheadPress:
            acceleration = .init(x: 0, y: value, z: 0); gravity = .init(x: 0, y: 0, z: -1)
        }
        let time = Double(index) * 0.02
        return ResampledMotionSample(sourceTimestamp: time, sessionTime: time, sensorSide: side,
                                     userAcceleration: acceleration, rotationRate: .init(x: 0, y: 0, z: 0),
                                     gravity: gravity, attitude: .init(w: 1, x: 0, y: 0, z: 0),
                                     interpolationStatus: .delivered, epoch: epoch)
    }
}

func biphasicFixture() -> [Double] {
    (0...75).map { index in
        let time = Double(index) * 0.02
        if time < 0.60 { return 0 }
        if time < 1.00 { return 0.30 }
        if time < 1.40 { return -0.30 }
        return 0
    }
}

func evidence(
    id: String,
    exercise: ExperimentalExercise,
    completion: Double,
    disposition: CandidateDisposition = .provisional
) -> RepEvidence {
    RepEvidence(id: id, detectorVersion: ExperimentalAnalysisResult.detectorVersion,
                exercise: exercise, sensorSide: .right, startSourceTimestamp: max(0, completion - 1),
                turnaroundTimestamp: completion - 0.5, completionTimestamp: completion,
                detectionTimestamp: completion, duration: 1, minimumSignal: -0.3, maximumSignal: 0.3,
                excursion: 0.6, positiveArea: 0.1, negativeArea: 0.1, peakMagnitude: 0.3,
                interpolatedSampleCount: 0, detectorEpoch: 0, qualityFlags: [],
                disposition: disposition, rejectionReason: nil)
}

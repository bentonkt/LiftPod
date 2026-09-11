import CoreMotion
import Foundation

enum HeadphoneSensorLocation: Sendable, Equatable, CustomStringConvertible {
    case leftHeadphone
    case rightHeadphone
    case `default`
    case unknown(rawValue: Int)

    init(rawValue: Int) {
        switch rawValue {
        case CMDeviceMotion.SensorLocation.headphoneLeft.rawValue:
            self = .leftHeadphone
        case CMDeviceMotion.SensorLocation.headphoneRight.rawValue:
            self = .rightHeadphone
        case CMDeviceMotion.SensorLocation.default.rawValue:
            self = .default
        default:
            self = .unknown(rawValue: rawValue)
        }
    }

    init(_ location: CMDeviceMotion.SensorLocation) {
        self.init(rawValue: location.rawValue)
    }

    var description: String {
        switch self {
        case .leftHeadphone: "Left headphone"
        case .rightHeadphone: "Right headphone"
        case .default: "Default"
        case let .unknown(rawValue): "Unknown (\(rawValue))"
        }
    }

    var csvValue: String { description }
}
struct RawMotionSample: Sendable, Equatable {
    let index: UInt64
    let sourceTimestamp: TimeInterval
    let receiptUptime: TimeInterval
    let sensorLocation: HeadphoneSensorLocation
    let userAccelerationX: Double
    let userAccelerationY: Double
    let userAccelerationZ: Double
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
    let quaternionW: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double
    let roll: Double
    let pitch: Double
    let yaw: Double
}

extension RawMotionSample {
    init(deviceMotion: CMDeviceMotion, index: UInt64, receiptUptime: TimeInterval) {
        self.init(
            index: index,
            sourceTimestamp: deviceMotion.timestamp,
            receiptUptime: receiptUptime,
            sensorLocation: HeadphoneSensorLocation(deviceMotion.sensorLocation),
            userAccelerationX: deviceMotion.userAcceleration.x,
            userAccelerationY: deviceMotion.userAcceleration.y,
            userAccelerationZ: deviceMotion.userAcceleration.z,
            gravityX: deviceMotion.gravity.x,
            gravityY: deviceMotion.gravity.y,
            gravityZ: deviceMotion.gravity.z,
            rotationRateX: deviceMotion.rotationRate.x,
            rotationRateY: deviceMotion.rotationRate.y,
            rotationRateZ: deviceMotion.rotationRate.z,
            quaternionW: deviceMotion.attitude.quaternion.w,
            quaternionX: deviceMotion.attitude.quaternion.x,
            quaternionY: deviceMotion.attitude.quaternion.y,
            quaternionZ: deviceMotion.attitude.quaternion.z,
            roll: deviceMotion.attitude.roll,
            pitch: deviceMotion.attitude.pitch,
            yaw: deviceMotion.attitude.yaw
        )
    }
}

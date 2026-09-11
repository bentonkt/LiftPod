import Foundation

struct PreprocessingConfiguration: Sendable, Equatable {
    var standardGravity = 9.80665
    var calibrationDuration = 3.0
    var minimumCalibrationSampleCount = 60
    var minimumGravityMagnitude = 0.75
    var maximumGravityMagnitude = 1.25
    var maximumSourceGap = 0.200
    var maximumCalibrationAccelerationStandardDeviation = 0.20
    var maximumCalibrationGyroscopeRMS = 0.15
    var lowPassCutoffFrequency = 5.0

    func validated() throws -> Self {
        var reasons: [String] = []
        let positiveValues: [(String, Double)] = [
            ("standard gravity", standardGravity),
            ("calibration duration", calibrationDuration),
            ("minimum gravity magnitude", minimumGravityMagnitude),
            ("maximum gravity magnitude", maximumGravityMagnitude),
            ("maximum source gap", maximumSourceGap),
            ("maximum calibration acceleration standard deviation", maximumCalibrationAccelerationStandardDeviation),
            ("maximum calibration gyroscope RMS", maximumCalibrationGyroscopeRMS),
            ("low-pass cutoff frequency", lowPassCutoffFrequency)
        ]
        for (name, value) in positiveValues where !value.isFinite || value <= 0 {
            reasons.append("\(name) must be finite and greater than zero")
        }
        if minimumCalibrationSampleCount <= 0 {
            reasons.append("minimum calibration sample count must be greater than zero")
        }
        if minimumGravityMagnitude.isFinite,
           maximumGravityMagnitude.isFinite,
           minimumGravityMagnitude >= maximumGravityMagnitude {
            reasons.append("minimum gravity magnitude must be less than maximum gravity magnitude")
        }
        guard reasons.isEmpty else { throw PreprocessingError.invalidConfiguration(reasons) }
        return self
    }
}

enum CalibrationFailureReason: Sendable, Equatable, CustomStringConvertible {
    case insufficientDuration(required: Double, actual: Double)
    case insufficientSamples(required: Int, actual: Int)
    case accelerationVariation(limit: Double, actual: Double)
    case gyroscopeMotion(limit: Double, actual: Double)

    var description: String {
        switch self {
        case let .insufficientDuration(required, actual):
            "Calibration duration is \(actual) s; at least \(required) s is required."
        case let .insufficientSamples(required, actual):
            "Calibration contains \(actual) samples; at least \(required) are required."
        case let .accelerationVariation(limit, actual):
            "Calibration vertical-acceleration standard deviation is \(actual) m/s²; the limit is \(limit) m/s²."
        case let .gyroscopeMotion(limit, actual):
            "Calibration gyroscope RMS is \(actual) rad/s; the limit is \(limit) rad/s."
        }
    }
}

struct CalibrationResult: Sendable, Equatable {
    let startSourceTimestamp: Double
    let endSourceTimestamp: Double
    let duration: Double
    let sampleCount: Int
    let meanGravityMagnitude: Double
    let verticalBias: Double
    let verticalAccelerationStandardDeviation: Double
    let gyroscopeRMSMagnitude: Double
    let failureReasons: [CalibrationFailureReason]

    var passed: Bool { failureReasons.isEmpty }
}

struct ProcessedMotionFrame: Sendable, Equatable {
    let index: UInt64
    let sourceTimestamp: Double
    let deltaTime: Double
    let sensorLocation: HeadphoneSensorLocation
    let gravityMagnitudeG: Double
    let gyroscopeMagnitudeRadiansPerSecond: Double
    let verticalAccelerationRawMetersPerSecondSquared: Double
    let verticalAccelerationCorrectedMetersPerSecondSquared: Double
    let verticalAccelerationFilteredMetersPerSecondSquared: Double
    let isCalibrationSample: Bool
}

struct PreprocessingResult: Sendable, Equatable {
    let configuration: PreprocessingConfiguration
    let calibration: CalibrationResult
    let frames: [ProcessedMotionFrame]
    let totalSourceDuration: Double
    let effectiveSampleRate: Double
    let maximumSourceTimeGap: Double
}

enum PreprocessingError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration([String])
    case emptySamples
    case insufficientSamples(actual: Int)
    case nonIncreasingIndex(position: Int, previous: UInt64, current: UInt64)
    case invalidTimestamp(index: UInt64, reason: String)
    case excessiveSourceGap(index: UInt64, gap: Double, maximum: Double)
    case nonFiniteComponent(index: UInt64, field: String)
    case invalidGravity(index: UInt64, magnitude: Double)
    case calibrationFailed(CalibrationResult)
    case nonFiniteFilterOutput(index: UInt64)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reasons):
            "Invalid preprocessing configuration: \(reasons.joined(separator: "; "))."
        case .emptySamples:
            "The raw recording contains no samples."
        case let .insufficientSamples(actual):
            "The raw recording contains \(actual) sample; at least two are required."
        case let .nonIncreasingIndex(position, previous, current):
            "Sample \(position) has callback index \(current), which does not follow \(previous) in strictly increasing order."
        case let .invalidTimestamp(index, reason):
            "Sample index \(index) has an invalid source timestamp: \(reason)."
        case let .excessiveSourceGap(index, gap, maximum):
            "The source-time gap before index \(index) is \(gap) s, exceeding the \(maximum) s limit."
        case let .nonFiniteComponent(index, field):
            "Sample index \(index) has a non-finite \(field) component."
        case let .invalidGravity(index, magnitude):
            "Sample index \(index) has gravity magnitude \(magnitude) g outside the configured plausible range."
        case let .calibrationFailed(result):
            "Stationary calibration failed: \(result.failureReasons.map(\.description).joined(separator: " "))"
        case let .nonFiniteFilterOutput(index):
            "Filtering produced a non-finite value at sample index \(index)."
        }
    }
}

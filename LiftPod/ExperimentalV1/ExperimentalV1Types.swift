import Foundation

enum ExperimentalExercise: String, Codable, CaseIterable, Sendable, Identifiable {
    case bicepsCurl = "Biceps Curl"
    case lateralRaise = "Lateral Raise"
    case overheadPress = "Overhead Press"

    var id: String { rawValue }
}

enum ExperimentalSensorSide: String, Codable, CaseIterable, Sendable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    func matches(_ location: HeadphoneSensorLocation) -> Bool {
        switch (self, location) {
        case (.left, .leftHeadphone), (.right, .rightHeadphone): true
        default: false
        }
    }
}

enum ExperimentalAxis: String, Codable, Sendable { case x, y, z }
enum ExperimentalSignalSource: String, Codable, Sendable { case gravity, userAcceleration }
enum ExperimentalDetectorKind: String, Codable, Sendable { case endpointProgress, biphasicCycle }

struct ExperimentalProfile: Codable, Sendable, Equatable {
    let exercise: ExperimentalExercise
    let signalSource: ExperimentalSignalSource
    let axis: ExperimentalAxis
    let polarity: Double
    let sensorSide: ExperimentalSensorSide
    let detectorKind: ExperimentalDetectorKind
    let requiresNeutralReference: Bool

    static func profile(
        for exercise: ExperimentalExercise,
        sensorSide: ExperimentalSensorSide
    ) -> Self {
        switch exercise {
        case .bicepsCurl:
            Self(exercise: exercise, signalSource: .gravity, axis: .x, polarity: 1,
                 sensorSide: sensorSide, detectorKind: .endpointProgress, requiresNeutralReference: true)
        case .lateralRaise:
            Self(exercise: exercise, signalSource: .userAcceleration, axis: .x, polarity: 1,
                 sensorSide: sensorSide, detectorKind: .biphasicCycle, requiresNeutralReference: false)
        case .overheadPress:
            Self(exercise: exercise, signalSource: .userAcceleration, axis: .y, polarity: 1,
                 sensorSide: sensorSide, detectorKind: .biphasicCycle, requiresNeutralReference: false)
        }
    }
}

struct MotionResamplingConfiguration: Codable, Sendable, Equatable {
    var outputRate = 50.0
    var outputInterval = 0.020
    var maximumInterpolationGap = 0.060
    var degradedGapThreshold = 0.100
    var maximumAttitudeAngularRate = 20.0
    var comparisonEpsilon = 1e-9
    var transitionPersistenceSamples = 3
    var minimumPhaseDuration = 0.20
    var minimumCycleDuration = 0.70
    var maximumCycleDuration = 8.0
    var maximumTurnaroundPause = 3.0
    var refractoryInterval = 0.25
    var receiptStalenessThreshold = 0.250
    var recoveryDuration = 0.250
    var candidateRetentionDuration = 8.0
    var filter = BiquadConfiguration.v1
    var endpoint = EndpointConfiguration()
    var biphasic = BiphasicConfiguration()
    var neutral = NeutralConfiguration()

    func validated() throws -> Self {
        let values = [outputRate, outputInterval, maximumInterpolationGap, degradedGapThreshold,
                      maximumAttitudeAngularRate, comparisonEpsilon, minimumPhaseDuration,
                      minimumCycleDuration, maximumCycleDuration, maximumTurnaroundPause,
                      refractoryInterval, receiptStalenessThreshold, recoveryDuration,
                      candidateRetentionDuration,
                      endpoint.startUpper, endpoint.leaveStart, endpoint.apexLower,
                      endpoint.leaveApex, endpoint.minimumExcursion,
                      biphasic.quietBand, biphasic.minimumProminence, biphasic.minimumLobeArea,
                      biphasic.minimumLobeDuration, biphasic.maximumLobeDuration,
                      biphasic.requiredQuietDuration,
                      neutral.quietActivityThreshold, neutral.requiredDwell,
                      neutral.adaptationFraction, neutral.adaptationLimitFraction]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }),
              [filter.b0, filter.b1, filter.b2, filter.a1, filter.a2,
               biphasic.permittedInitialMinimum, biphasic.permittedInitialMaximum,
               neutral.permittedSignalMinimum, neutral.permittedSignalMaximum].allSatisfy(\.isFinite),
              transitionPersistenceSamples > 0,
              abs(outputInterval - 1 / outputRate) <= comparisonEpsilon,
              maximumInterpolationGap <= degradedGapThreshold,
              minimumCycleDuration < maximumCycleDuration,
              endpoint.startUpper < endpoint.leaveStart,
              endpoint.leaveStart < endpoint.apexLower,
              endpoint.leaveApex < endpoint.apexLower,
              endpoint.minimumExcursion <= endpoint.apexLower - endpoint.startUpper,
              biphasic.minimumLobeDuration < biphasic.maximumLobeDuration,
              biphasic.permittedInitialMinimum < biphasic.permittedInitialMaximum,
              neutral.permittedSignalMinimum < neutral.permittedSignalMaximum,
              neutral.adaptationFraction <= 1,
              neutral.adaptationLimitFraction <= 1 else {
            throw ExperimentalV1Error.invalidConfiguration
        }
        return self
    }
}

// Retained so archived Experimental V1 recordings and tests continue to decode and replay.
typealias ExperimentalV1Configuration = MotionResamplingConfiguration

struct BiquadConfiguration: Codable, Sendable, Equatable {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    static let v1 = Self(
        b0: 0.04613180209331292,
        b1: 0.09226360418662584,
        b2: 0.04613180209331292,
        a1: -1.3072850288493234,
        a2: 0.49181223722257517
    )

    static let v2Fixed4Hz = Self(
        b0: 0.04613180209331292,
        b1: 0.09226360418662584,
        b2: 0.04613180209331292,
        a1: -1.3072850288493234,
        a2: 0.49181223722257517
    )
}

struct EndpointConfiguration: Codable, Sendable, Equatable {
    var startUpper = 0.20
    var leaveStart = 0.30
    var apexLower = 0.80
    var leaveApex = 0.70
    var minimumExcursion = 0.60
}

struct BiphasicConfiguration: Codable, Sendable, Equatable {
    var quietBand = 0.05
    var minimumProminence = 0.15
    var minimumLobeArea = 0.02
    var minimumLobeDuration = 0.20
    var maximumLobeDuration = 3.0
    var requiredQuietDuration = 0.06
    var permittedInitialMinimum = -0.25
    var permittedInitialMaximum = 0.25
}

struct NeutralConfiguration: Codable, Sendable, Equatable {
    var quietActivityThreshold = 0.20
    var requiredDwell = 0.25
    var permittedSignalMinimum = -1.10
    var permittedSignalMaximum = 1.10
    var adaptationFraction = 0.05
    var adaptationLimitFraction = 0.10
}

struct ExperimentalVector3: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let z: Double

    var magnitude: Double { sqrt(x * x + y * y + z * z) }
    func value(on axis: ExperimentalAxis) -> Double {
        switch axis { case .x: x; case .y: y; case .z: z }
    }
    static func interpolate(_ left: Self, _ right: Self, fraction: Double) -> Self {
        Self(x: left.x + (right.x - left.x) * fraction,
             y: left.y + (right.y - left.y) * fraction,
             z: left.z + (right.z - left.z) * fraction)
    }
}

struct ExperimentalQuaternion: Codable, Sendable, Equatable {
    let w: Double
    let x: Double
    let y: Double
    let z: Double

    var norm: Double { sqrt(w * w + x * x + y * y + z * z) }
    func normalized() -> Self? {
        let length = norm
        guard length.isFinite, length > 1e-12 else { return nil }
        return Self(w: w / length, x: x / length, y: y / length, z: z / length)
    }
    func dot(_ other: Self) -> Double { w * other.w + x * other.x + y * other.y + z * other.z }
    func negated() -> Self { Self(w: -w, x: -x, y: -y, z: -z) }
}

enum InterpolationStatus: String, Codable, Sendable { case delivered, interpolated }

struct ResampledMotionSample: Codable, Sendable, Equatable {
    let sourceTimestamp: Double
    let sessionTime: Double
    let sensorSide: ExperimentalSensorSide?
    let userAcceleration: ExperimentalVector3
    let rotationRate: ExperimentalVector3
    let gravity: ExperimentalVector3
    let attitude: ExperimentalQuaternion
    let interpolationStatus: InterpolationStatus
    let epoch: Int
}

enum SignalQualityState: String, Codable, Sendable {
    case warmingUp = "Warming up"
    case usable = "Usable"
    case degraded = "Degraded"
    case stale = "Stale"
    case disconnected = "Disconnected"
    case wrongSensorSide = "Wrong sensor side"
    case invalidInput = "Invalid input"
}

struct QualityTransition: Codable, Sendable, Equatable {
    let sourceTimestamp: Double
    let state: SignalQualityState
    let reason: String
}

enum DetectorPhase: String, Codable, Sendable {
    case unarmed, startConfirmed, outbound, turnaroundConfirmed, returning, quiet, positiveLobe, negativeLobe, refractory
}

enum CandidateDisposition: String, Codable, Sendable { case provisional, committed, rejected }

enum RepRejectionReason: String, Codable, CaseIterable, Sendable {
    case insufficientExcursion
    case invalidOrdering
    case insufficientDuration
    case excessiveDuration
    case excessivePause
    case insufficientArea
    case insufficientProminence
    case sameSignOnly
    case discontinuity
    case wrongSensorSide
    case conflictingExerciseDecision
}

enum RepQualityFlag: String, Codable, Sendable {
    case containsInterpolation
    case adaptedNeutralUsed
    case delayedAuthorization
    case recoveredStream
}

struct RepEvidence: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let detectorVersion: String
    let exercise: ExperimentalExercise
    let sensorSide: ExperimentalSensorSide
    let startSourceTimestamp: Double
    let turnaroundTimestamp: Double?
    let completionTimestamp: Double
    let detectionTimestamp: Double
    let duration: Double
    let minimumSignal: Double
    let maximumSignal: Double
    let excursion: Double
    let positiveArea: Double
    let negativeArea: Double
    let peakMagnitude: Double
    let interpolatedSampleCount: Int
    let detectorEpoch: Int
    var qualityFlags: [RepQualityFlag]
    var disposition: CandidateDisposition
    var rejectionReason: RepRejectionReason?
}

enum ExerciseDecisionReason: String, Codable, Sendable { case manualSelection }

struct StableExerciseSelection: Codable, Sendable, Equatable {
    let epoch: Int
    let selectedProfile: ExperimentalExercise?
    let supportStartTimestamp: Double
    let effectiveFromTimestamp: Double
    let decisionTimestamp: Double
    let confidence: Double?
    let reason: ExerciseDecisionReason
}

struct DetectionSnapshot: Codable, Sendable, Equatable {
    let committedCount: Int
    let provisionalCount: Int
    let rejectedCount: Int
    let quality: SignalQualityState
    let detectorPhase: DetectorPhase
    let candidateIDs: [String]
}

struct ExperimentalAnalysisResult: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    static let detectorVersion = "experimental-v1"
    let schemaVersion: Int
    let detectorVersion: String
    let sourceFilename: String
    let profile: ExperimentalProfile
    let configuration: ExperimentalV1Configuration
    let inputSampleCount: Int
    let resampledSampleCount: Int
    let committedCount: Int
    let provisionalCount: Int
    let rejectedCount: Int
    let candidates: [RepEvidence]
    let rejectionTotals: [String: Int]
    let qualityTransitions: [QualityTransition]
    let warnings: [String]
    let finalQuality: SignalQualityState
    let finalPhase: DetectorPhase
}

enum ExperimentalV1Error: LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case emptyInput
    case invalidInput(sequence: Int, reason: String)
    case invalidAnnotation(String)
    case annotationFileExists
    case replayMismatch(transaction: Int, field: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Experimental V1 configuration is invalid."
        case .emptyInput: "The imported recording contains no motion samples."
        case let .invalidInput(sequence, reason): "Invalid motion input at sequence \(sequence): \(reason)."
        case let .invalidAnnotation(reason): "Invalid annotation sidecar: \(reason)."
        case .annotationFileExists: "The annotation destination already exists; choose a different filename."
        case let .replayMismatch(transaction, field): "Replay mismatch at transaction \(transaction): \(field)."
        }
    }
}

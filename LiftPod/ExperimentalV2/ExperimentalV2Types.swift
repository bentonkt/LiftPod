import CryptoKit
import Foundation

enum V2Exercise: String, Codable, CaseIterable, Sendable, Identifiable {
    case bicepsCurl = "Biceps Curl"
    case lateralRaise = "Lateral Raise"
    case overheadPress = "Overhead Press"
    var id: String { rawValue }
}

enum V2ProfileKind: String, Codable, Sendable { case localCycle, fullCycleTemplate }
enum V2ValidationStatus: String, Codable, Sendable { case experimental, importedUnvalidated, generatedUnvalidated, validated }
enum V2AuthorizationSource: String, Codable, Sendable { case manual }
enum V2SetState: String, Codable, Sendable { case idle, preparing, active, finalizing, complete, interrupted }
enum V2DetectorPhase: String, Codable, Sendable { case waitingForBottom, ready, outbound, returning }
enum V2SetInterruption: String, Codable, Sendable {
    case disconnect, staleDelivery, wrongSensorSide, invalidInput, backwardSourceClock
    case appBackgrounding, recordingFailure, processingQueueOverflow, explicitCancellation
}
enum V2RejectionReason: String, Codable, Sendable {
    case insufficientExcursion, incompleteReturn, returnTooHigh, returnTooDeep
    case invalidOrdering, invalidDuration, excessivePause, discontinuity, ambiguousTemplate
    case templateCost, negativeMargin, endpointMismatch, phaseEvidence, nonFiniteEvidence
}

enum V2Error: LocalizedError, Sendable, Equatable {
    case invalidProfile(String)
    case invalidCalibration(String)
    case invalidLifecycle(String)
    case recordingFailure(String)
    case replayFailure(sequence: Int?, field: String)

    var errorDescription: String? {
        switch self {
        case let .invalidProfile(reason): "Invalid Experimental V2 profile: \(reason)."
        case let .invalidCalibration(reason): "Invalid Experimental V2 calibration: \(reason)."
        case let .invalidLifecycle(reason): "Experimental V2 set lifecycle error: \(reason)."
        case let .recordingFailure(reason): "Experimental V2 recording failed: \(reason)."
        case let .replayFailure(sequence, field):
            "Experimental V2 replay mismatch" + (sequence.map { " at ingest \($0)" } ?? "") + ": \(field)."
        }
    }
}

struct V2TimingConfiguration: Codable, Sendable, Equatable {
    var persistenceSamples = 3
    var minimumPreparationDuration = 3.0
    var minimumPhaseDuration = 0.20
    var minimumCycleDuration = 0.70
    var maximumCycleDuration = 8.0
    var maximumTurnaroundPause = 3.0
    var refractoryDuration = 0.25
    var finalizationDrainDuration = 0.40
}

struct V2ReferenceConfiguration: Codable, Sendable, Equatable {
    var quietActivityThreshold = 0.05
    var dwell = 0.50
    var maximumWindow = 0.75
    var minimumSamples = 20
    var rawLower = -0.7924151325348823
    var rawUpper = -0.3231202125427133
}

struct V2LocalCycleConfiguration: Codable, Sendable, Equatable {
    var startLower = -0.1407884759976507
    var startUpper = 0.1407884759976507
    var leaveStart = 0.25811220599569296
    var apexLower = 0.9972517049833591
    var leaveApex = 0.8212661099862958
    var trainedSpan = 1.1732372999804226
    var minimumOutboundExcursion = 0.9385898399843381
    var minimumReturnExcursion = 0.7978013639866874
    var minimumReturnFraction = 0.85
    var maximumPositiveBottomOffsetFraction = 0.20
    var maximumDeeperReturnFraction = 0.50
    var returnSettlingDuration = 0.08
    var gyroscopeQuietThreshold = 0.35
    var reversalDisplacementFraction = 0.02
}

struct V2TemplateConfiguration: Codable, Sendable, Equatable {
    var frameCount = 64
    var channelCount = 10
    var warpingBandFraction = 0.20
    var maximumCost = 0.20
    var minimumNegativeMargin = 0.10
    var endpointLimit = 0.25
    var phaseEvidenceRatio = 0.85
    var startActivityThreshold = 0.04
    var quietDuration = 0.25
    var preRollDuration = 0.12
    var evaluationStride = 3
}

struct V2Template: Codable, Sendable, Equatable {
    let frames: [[Double]]
    let landmarks: [Int]
    let duration: Double
    let channelScales: [Double]
    let negativeSubtype: String?

    func validated(configuration: V2TemplateConfiguration) throws -> Self {
        guard frames.count == 64, frames.allSatisfy({ $0.count == 10 && $0.allSatisfy(\.isFinite) }),
              landmarks.count == 5, landmarks.first == 0, landmarks.last == 63,
              zip(landmarks, landmarks.dropFirst()).allSatisfy({ $0 < $1 }),
              duration.isFinite, duration >= 0.7, duration <= 8,
              channelScales.count == 10,
              channelScales.allSatisfy({ $0.isFinite && $0 > 0 }),
              configuration.frameCount == 64, configuration.channelCount == 10 else {
            throw V2Error.invalidProfile("Invalid full-cycle template")
        }
        return self
    }
}

struct V2DSPIdentity: Codable, Sendable, Equatable {
    let profileVersion: String
    let exercise: V2Exercise
    let expectedSensorSide: ExperimentalSensorSide
    let setupIdentifier: String
    let sampleRate: Double
    let signalSource: ExperimentalSignalSource
    let projectionAxis: ExperimentalAxis
    let polarity: Double
    let filter: BiquadConfiguration
    let reference: V2ReferenceConfiguration
    let localCycle: V2LocalCycleConfiguration
    let templateConfiguration: V2TemplateConfiguration
    let timing: V2TimingConfiguration
    let positiveTemplates: [V2Template]
    let negativeTemplates: [V2Template]
    let kind: V2ProfileKind
}

struct V2DSPProfile: Codable, Sendable, Equatable, Identifiable {
    let profileID: String
    let identity: V2DSPIdentity
    var validationStatus: V2ValidationStatus
    var descriptiveNotes: String?
    var id: String { profileID }

    var contentHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(identity) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validated() throws -> Self {
        let i = identity
        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let positive = [i.sampleRate, i.polarity, i.reference.quietActivityThreshold, i.reference.dwell,
                        i.localCycle.trainedSpan, i.localCycle.minimumOutboundExcursion,
                        i.localCycle.minimumReturnExcursion, i.localCycle.minimumReturnFraction,
                        i.timing.minimumPreparationDuration, i.timing.minimumCycleDuration,
                        i.timing.maximumCycleDuration, i.timing.finalizationDrainDuration]
        guard i.profileVersion == "experimental-v2", !profileID.isEmpty,
              profileID.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }),
              positive.allSatisfy({ $0.isFinite && $0 > 0 }), i.sampleRate == 50,
              i.timing.persistenceSamples > 0,
              i.timing.minimumCycleDuration < i.timing.maximumCycleDuration,
              i.reference.rawLower < i.reference.rawUpper,
              i.localCycle.startLower < i.localCycle.startUpper,
              i.localCycle.minimumReturnFraction <= 1,
              i.templateConfiguration.warpingBandFraction <= 0.20 else {
            throw V2Error.invalidProfile("DSP configuration is internally inconsistent")
        }
        if i.kind == .fullCycleTemplate {
            guard !i.positiveTemplates.isEmpty else { throw V2Error.invalidProfile("A positive template is required") }
            _ = try i.positiveTemplates.map { try $0.validated(configuration: i.templateConfiguration) }
            _ = try i.negativeTemplates.map { try $0.validated(configuration: i.templateConfiguration) }
        }
        return self
    }

    static let bundledCurl = V2DSPProfile(
        profileID: "local-cycle-v2-bundled-curl-right",
        identity: V2DSPIdentity(
            profileVersion: "experimental-v2", exercise: .bicepsCurl, expectedSensorSide: .right,
            setupIdentifier: "right-airpod-held-weight", sampleRate: 50, signalSource: .gravity,
            projectionAxis: .x, polarity: 1, filter: .v2Fixed4Hz, reference: .init(), localCycle: .init(),
            templateConfiguration: .init(), timing: .init(), positiveTemplates: [], negativeTemplates: [],
            kind: .localCycle
        ),
        validationStatus: .experimental,
        descriptiveNotes: "Experimental and orientation-dependent; not a universal AirPods profile."
    )
}

struct V2SetDescriptor: Codable, Sendable, Equatable {
    let setID: UUID
    let exercise: V2Exercise
    let profileID: String
    let dspContentHash: String
    let authorizationSource: V2AuthorizationSource
    let hardwareSetupIdentifier: String
}

struct V2ReferenceMeasurements: Codable, Sendable, Equatable {
    let neutralSignal: Double
    let referenceAttitude: ExperimentalQuaternion
    let referenceGravity: ExperimentalVector3
    let activityMedian: Double
    let activityP90: Double
    let signalP05: Double
    let signalP95: Double
    let signalMAD: Double
    let earlyLateDrift: Double
    let accelerationNoiseMAD: Double
    let gyroNoiseMAD: Double
    let observedSampleRate: Double
    let sampleCount: Int
    let startTimestamp: Double
    let endTimestamp: Double
}

struct V2CycleEvidence: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let setID: UUID
    let exercise: V2Exercise
    let authorizationSource: V2AuthorizationSource
    let profileID: String
    let dspContentHash: String
    let detectorEpoch: Int
    let cycleSequence: Int
    let startTimestamp: Double
    let topTimestamp: Double
    let completionTimestamp: Double
    let detectionTimestamp: Double
    let bottom: Double
    let top: Double
    let returned: Double
    let outboundArea: Double
    let returnArea: Double
    var committed: Bool
    var rejectionReason: V2RejectionReason?
}

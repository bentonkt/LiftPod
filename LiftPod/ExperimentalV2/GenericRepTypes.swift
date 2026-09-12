import CryptoKit
import Foundation
import simd

enum RepCountingMode: String, CaseIterable, Identifiable, Sendable {
    case exercise = "Exercise profile", generic = "Generic movement"
    var id: String { rawValue }
}

/// Engineering defaults, deliberately independent of the legacy template score.
/// No configuration is promoted by the app; physical validation is still required.
struct GenericRepConfiguration: Codable, Equatable, Sendable {
    var version = "generic-pattern-v1"
    var sampleRate = 50.0
    var historyDuration = 32.0
    var discoveryInterval = 0.20
    var minimumCycleDuration = 0.70
    var maximumCycleDuration = 8.0
    var minimumCorrelation = 0.65
    var maximumMatchCost = 0.32
    var maximumEndpointCost = 0.45
    var ambiguityMargin = 0.08
    var maximumPause = 3.0
    var unmatchedDuration = 0.30
    var noiseFloors = [0.025, 0.10, 0.025] // g, rad/s, g; one scale per vector group
    var filter: BiquadConfiguration = .v2Fixed4Hz

    var contentHash: String { GenericHash.of(self) }
    func validated() throws -> Self {
        guard version == "generic-pattern-v1", sampleRate == 50, historyDuration == 32,
              discoveryInterval == 0.20, minimumCycleDuration == 0.70, maximumCycleDuration == 8,
              noiseFloors.count == 3, noiseFloors.allSatisfy({ $0.isFinite && $0 > 0 }),
              [minimumCorrelation, maximumMatchCost, maximumEndpointCost, ambiguityMargin,
               maximumPause, unmatchedDuration].allSatisfy({ $0.isFinite && $0 > 0 }),
              minimumCorrelation < 1, maximumMatchCost <= 1, maximumEndpointCost <= 1,
              maximumPause <= 3, unmatchedDuration <= 0.6, filter == .v2Fixed4Hz else {
            throw V2Error.invalidLifecycle("invalid generic configuration")
        }
        return self
    }
}

enum GenericHash {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func of<T: Encodable>(_ value: T) -> String {
        guard let data = try? data(value) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct GenericMotionFrame: Codable, Equatable, Sendable {
    let sample: ResampledMotionSample
    let features: [Double]
    var time: Double { sample.sourceTimestamp }
    var moving: Bool { sample.userAcceleration.magnitude > 0.025 || sample.rotationRate.magnitude > 0.10 }
}

struct GenericFeaturePipeline: Sendable {
    private var filters = (0..<9).map { _ in ScalarBiquadFilter(coefficients: .v2Fixed4Hz) }
    private var worldGravity: SIMD3<Double>?
    mutating func reset() { self = .init() }
    mutating func observe(_ sample: ResampledMotionSample) -> GenericMotionFrame? {
        guard (0.75...1.25).contains(sample.gravity.magnitude),
              let a = DevicePathMath.world(sample.userAcceleration, attitude: sample.attitude),
              let w = DevicePathMath.world(sample.rotationRate, attitude: sample.attitude),
              let g = DevicePathMath.world(sample.gravity, attitude: sample.attitude) else { return nil }
        let up = simd_normalize(g)
        if let worldGravity, simd_length(up - worldGravity) > 0.08 { return nil }
        worldGravity = worldGravity ?? up
        let values = [a.x, a.y, a.z, w.x, w.y, w.z, sample.gravity.x, sample.gravity.y, sample.gravity.z]
        return .init(sample: sample, features: values.indices.map { filters[$0].process(values[$0]) })
    }
}

struct GenericPattern: Codable, Equatable, Sendable {
    let frames: [[Double]]
    let scales: [Double]
    let activeGroups: [Bool]
    let duration: Double
    let sourceEpoch: Int
    let learningEpoch: Int
    let learnedFrom: [Double]
    let frozenAt: Double
    var contentHash: String { GenericHash.of(self) }
}

/// Pattern phase is not a physical turnaround. Only independently supported
/// angular reversals may populate turnaroundTimestamp.
struct GenericCycleEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let setID: UUID
    let sourceEpoch: Int
    let learningEpoch: Int
    let templateHash: String
    let startTimestamp: Double
    let completionTimestamp: Double
    let detectionTimestamp: Double
    let authorizationTimestamp: Double
    let matchCost: Double
    var turnaroundTimestamp: Double?
    var outwardEndTimestamp: Double?
    var returnStartTimestamp: Double?
    var turnaroundPauseDuration: Double?
    var precedingPauseDuration: Double?
    var authorizationSource = "set-local-pattern"
}

enum GenericTrackingState: String, Codable, Sendable { case learning, tracking, holding, unmatched, recovering }

struct GenericRepSnapshot: Codable, Equatable, Sendable {
    var state: GenericTrackingState = .learning
    var learningEpoch = 0
    var templateHash: String?
    var phase: Int?
    var candidateCount = 0
    var events: [GenericCycleEvent] = []
    var metrics: [GenericCycleMetrics] = []
    var detail = "Learning movement…"
    var baselineMeanSpeed: Double?
}

struct GenericCycleMetrics: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let learningEpoch: Int
    var status: RepMetricsStatus = .pending
    var reason: RepMetricsReason?
    var meanSpeed: Double?
    var peakSpeed: Double?
    var meanVerticalSpeed: Double?
    var peakVerticalSpeed: Double?
    var outwardDuration: Double?
    var returnDuration: Double?
    var outwardMeanSpeed: Double?
    var returnMeanSpeed: Double?
    var turnaroundPause: Double?
    var precedingPause: Double?
    var finalizedAt: Double?
    var estimatorVersion = "generic-cycle-metrics-v1"
}

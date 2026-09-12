import Foundation

struct AutoWorkoutConfiguration: Codable, Equatable, Sendable {
    var schemaVersion = 9
    var version = "auto-workout-v1"
    var workoutID = UUID()
    var side: ExperimentalSensorSide = .right
    var detector = GenericRepConfiguration()
    var minimumCycles = 3
    var recoveryDelay = 1.5
    var groupingGrace = 10.0
    var candidateLifetime = 32.0
    var contextDuration = 64.0
    var metricsEnabled = true
    func validated() throws -> Self {
        guard schemaVersion == 9, version == "auto-workout-v1", minimumCycles == 3,
              recoveryDelay == 1.5, groupingGrace == 10, candidateLifetime == 32,
              contextDuration == 64 else { throw V2Error.invalidLifecycle("unsupported automatic workout configuration") }
        _ = try detector.validated()
        return self
    }
}

enum AutoWorkoutState: String, Codable, Sendable { case idle, connecting, running, paused, suspended, finished }
enum AutoActivity: String, Codable, Sendable { case quiet, moving, unavailable }
enum AutoIntervalKind: String, Codable, Sendable { case preparation, recovery, unclassified, unavailable, intraSetPause }
enum AutoBoutStatus: String, Codable, Sendable { case open, provisional, sealed, discarded }

struct AutoCycleEvidence: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceEpoch: Int
    let learningEpoch: Int
    let templateHash: String
    let start: Double
    let completion: Double
    let detected: Double
    let authorized: Double
    let matchCost: Double
}

struct AutoProgressEvidence: Codable, Equatable, Sendable {
    let traversalID: String
    let start: Double
    let observedAt: Double
    let meaningfulSections: Int
    var replacement = false
}

struct AutoEvidenceBatch: Codable, Equatable, Sendable {
    let timestamp: Double
    var sourceEpoch = 0
    var cycles: [AutoCycleEvidence] = []
    var progress: AutoProgressEvidence?
    var activity: AutoActivity = .quiet
    var candidateStart: Double?
    var resolvedThrough: Double
    var discontinuity = false
    var templates: [GenericPattern] = []
}

struct AutoSetRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var cycleIDs: [String]
    var start: Double
    var end: Double
    var status: AutoBoutStatus = .open
    var sealedAt: Double?
    var correctedCount: Int?
    var baselineMeanSpeed: Double?
    var count: Int { correctedCount ?? cycleIDs.count }
}

struct AutoTimelineInterval: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var kind: AutoIntervalKind
    var start: Double
    var end: Double
    var provisional = true
}

struct AutoWorkoutCorrection: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case discard, count, split, merge }
    let kind: Kind
    let setID: String
    var otherSetID: String?
    var count: Int?
    var afterCycleID: String?
}

struct AutoWorkoutInput: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case sample, pause, resume, suspend, finish, endSet, correction, clock }
    let kind: Kind
    var raw: RawMotionEvent?
    var timestamp: Double?
    var reason: String?
    var correction: AutoWorkoutCorrection?
}

struct AutoWorkoutSnapshot: Codable, Equatable, Sendable {
    var state: AutoWorkoutState = .idle
    var timestamp: Double?
    var status = "Ready — begin when ready"
    var sets: [AutoSetRecord] = []
    var cycles: [AutoCycleEvidence] = []
    var intervals: [AutoTimelineInterval] = []
    var metrics: [GenericCycleMetrics] = []
    var candidateCount = 0
    var restStartedAt: Double?
    var availabilityReason: String?
    var elapsedRest: Double? { guard let timestamp, let restStartedAt else { return nil }; return max(0,timestamp-restStartedAt) }
}

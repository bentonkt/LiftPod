import Combine
import Foundation

struct WorkoutPolicy: Codable, Equatable {
    var version = "automatic-sets-v1"
    var inactivitySeconds = 12.0
}

struct SessionRep: Codable, Equatable {
    let id: String
    let exercise: V2Exercise
    let start: Double
    let end: Double
    var duration: Double { end - start }
    var valid: Bool { start.isFinite && end.isFinite && duration >= 0.7 && duration <= 8 }
    init(_ event: V2CycleEvidence) {
        id = event.id; exercise = event.exercise; start = event.startTimestamp; end = event.completionTimestamp
    }
    init(_ event: GenericCycleEvent, exercise: V2Exercise) {
        id = event.id; self.exercise = exercise
        start = event.startTimestamp; end = event.completionTimestamp
    }
    init(id: String, exercise: V2Exercise = .bicepsCurl, start: Double, end: Double) {
        self.id = id; self.exercise = exercise; self.start = start; self.end = end
    }
}

struct SessionSet: Codable, Identifiable, Equatable {
    let id: String
    let prescription: WorkoutPrescription
    var reps: [SessionRep]
    var interrupted = false
    var endReason: String?
    var start: Double { reps.first!.start }
    var end: Double { reps.last!.end }
    var averageDuration: Double { reps.map(\.duration).reduce(0, +) / Double(reps.count) }

}

enum SessionInput: Codable {
    case rep(SessionRep)
    case clock(Double)
    case selection(WorkoutPrescription)
    case end(Double, interrupted: Bool)
    case closeSet(Double)
}

/// A pure reducer: replaying the same inputs produces the same set boundaries.
struct WorkoutSessionReducer {
    let policy: WorkoutPolicy
    private(set) var prescription: WorkoutPrescription
    private(set) var sets: [SessionSet] = []
    private(set) var current: SessionSet?
    private(set) var ended = false
    private(set) var inputs: [SessionInput] = []
    private var seen: Set<String> = []
    private var boundary = -Double.infinity

    init(prescription: WorkoutPrescription, policy: WorkoutPolicy = .init()) {
        self.prescription = prescription; self.policy = policy
    }

    mutating func apply(_ input: SessionInput) {
        guard !ended else { return }
        switch input {
        case let .rep(rep):
            guard rep.valid, rep.exercise == prescription.exercise, rep.start >= boundary, !seen.contains(rep.id) else { return }
            if let last = current?.reps.last, rep.start < last.end { return }
            if let last = current?.reps.last, rep.end - last.end >= policy.inactivitySeconds {
                close(reason: "inactivity", boundary: last.end)
            }
            if let current, current.prescription.exercise != rep.exercise {
                close(reason: "exerciseChanged", boundary: rep.start)
            }
            guard rep.exercise == prescription.exercise else { return }
            seen.insert(rep.id)
            if current == nil {
                current = SessionSet(id: rep.id, prescription: prescription, reps: [])
            }
            current!.reps.append(rep)
        case let .clock(time):
            guard time.isFinite, let last = current?.reps.last,
                  time - last.end >= policy.inactivitySeconds else { return }
            close(reason: "inactivity", boundary: last.end)
        case let .selection(value):
            guard value.isValid else { return }
            if value.exercise != prescription.exercise, let last = current?.reps.last {
                close(reason: "exerciseChanged", boundary: last.end)
            }
            // Freeze the active set; same-exercise changes apply to the next set only.
            prescription = value
        case let .closeSet(time):
            guard time.isFinite else { return }
            close(reason: "manual", boundary: time)
        case let .end(time, interrupted):
            guard time.isFinite else { return }
            if interrupted { current?.interrupted = true }
            close(reason: interrupted ? "interrupted" : "workoutEnded", boundary: time)
            ended = true
        }
        inputs.append(input)
    }

    private mutating func close(reason: String, boundary: Double) {
        if var set = current, !set.reps.isEmpty { set.endReason = reason; sets.append(set) }
        current = nil; self.boundary = max(self.boundary, boundary)
    }


}

struct WorkoutSessionArchive: Codable {
    let schemaVersion: Int
    let sessionID: UUID
    let initialPrescription: WorkoutPrescription
    let policy: WorkoutPolicy
    let inputs: [SessionInput]
    let sets: [SessionSet]
    let interrupted: Bool
    let recordingDirectory: String?

    func replay() -> WorkoutSessionReducer {
        var reducer = WorkoutSessionReducer(prescription: initialPrescription, policy: policy)
        for input in inputs { reducer.apply(input) }
        return reducer
    }
}

struct SetReviewDraft: Identifiable, Equatable {
    let id: String
    let sessionID: UUID
    let exercise: V2Exercise
    let detectedReps: Int
    let averageRepDuration: Double?
    let endedAt: Date
    var loadLB: Double
    let velocityProfile: SetVelocityProfile?
    let automaticRIR: AutomaticRIREstimate?
    let precedingSetID: String?
    let precedingRestSeconds: Double?

    init(sessionID: UUID, set: SessionSet, endedAt: Date = Date(),
         velocityProfile: SetVelocityProfile? = nil,
         automaticRIR: AutomaticRIREstimate? = nil,
         precedingSetID: String? = nil,
         precedingRestSeconds: Double? = nil) {
        id = set.id
        self.sessionID = sessionID
        exercise = set.prescription.exercise
        detectedReps = set.reps.count
        averageRepDuration = set.reps.isEmpty ? nil : set.averageDuration
        self.endedAt = endedAt
        loadLB = set.prescription.loadLB
        self.velocityProfile = velocityProfile
        self.automaticRIR = automaticRIR
        self.precedingSetID = precedingSetID
        self.precedingRestSeconds = precedingRestSeconds
    }
}

enum RIRValueSource: String, Codable, Equatable {
    case automaticVelocity
    case userEntered
}

struct SetVelocityProfile: Codable, Equatable {
    let meanLiftingSpeeds: [Double?]
    let estimatorVersion: String
    let measurementKind: String

    var availableRepCount: Int { meanLiftingSpeeds.compactMap { $0 }.count }
    var baselineSpeed: Double? {
        let early = meanLiftingSpeeds.prefix(3).compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        return early.count >= 2 ? early.max() : nil
    }
    var velocityLossPercent: Double? {
        guard let baselineSpeed, let final = meanLiftingSpeeds.last ?? nil,
              final.isFinite, final > 0 else { return nil }
        return min(90, max(0, 100 * (1 - final / baselineSpeed)))
    }

    init?(set: SessionSet, metrics: RepMetricsSnapshot?) {
        guard let metrics else { return nil }
        let byID = Dictionary(grouping: metrics.reps, by: \.id)
        let matched = set.reps.map { rep in
            byID[rep.id]?.last(where: { $0.status == .available })
        }
        let speeds = matched.map { metric -> Double? in
            guard let value = metric?.meanLiftingSpeed, value.isFinite, value > 0 else { return nil }
            return value
        }
        let available = speeds.compactMap { $0 }.count
        guard speeds.count >= 3, available >= 3,
              Double(available) / Double(speeds.count) >= 0.60,
              speeds.last! != nil,
              let representative = matched.compactMap({ $0 }).last,
              let estimatorVersion = representative.estimatorVersion,
              let measurementKind = representative.measurementKind else { return nil }
        self.meanLiftingSpeeds = speeds
        self.estimatorVersion = estimatorVersion
        self.measurementKind = measurementKind
        guard baselineSpeed != nil, velocityLossPercent != nil else { return nil }
    }

    init?(set: SessionSet, genericMetrics: [GenericCycleMetrics]) {
        let byID = Dictionary(grouping: genericMetrics, by: \.id)
        let matched = set.reps.map { rep in
            byID[rep.id]?.last(where: { $0.status == .available })
        }
        let speeds = matched.map { metric -> Double? in
            guard let value = metric?.meanSpeed, value.isFinite, value > 0 else { return nil }
            return value
        }
        let available = speeds.compactMap { $0 }.count
        guard speeds.count >= 3, available >= 3,
              Double(available) / Double(speeds.count) >= 0.60,
              speeds.last! != nil,
              let estimatorVersion = matched.compactMap({ $0 }).last?.estimatorVersion else { return nil }
        self.meanLiftingSpeeds = speeds
        self.estimatorVersion = estimatorVersion
        self.measurementKind = "generic-cycle-speed"
        guard baselineSpeed != nil, velocityLossPercent != nil else { return nil }
    }

    init(meanLiftingSpeeds: [Double?], estimatorVersion: String = "test-estimator",
         measurementKind: String = "test-motion") {
        self.meanLiftingSpeeds = meanLiftingSpeeds
        self.estimatorVersion = estimatorVersion
        self.measurementKind = measurementKind
    }
}

struct AutomaticRIREstimate: Equatable {
    enum Method: String, Equatable {
        case individualized = "Personal velocity model"
        case populationHeuristic = "Velocity-loss estimate"
    }
    enum Confidence: String, Equatable {
        case low = "Low confidence"
        case medium = "Medium confidence"
        case high = "High confidence"
    }

    let repsInReserve: Int
    let velocityLossPercent: Double
    let measuredRepCount: Int
    let method: Method
    let confidence: Confidence
    let calibrationSetCount: Int
    let cappedAtFourPlus: Bool
}

struct LoggedWorkoutSet: Codable, Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let sourceSetID: String
    let exercise: V2Exercise
    let loadLB: Double
    let reps: Int
    let repsInReserve: Int?
    let averageRepDuration: Double?
    let performedAt: Date
    let velocityProfile: SetVelocityProfile?
    let rirValueSource: RIRValueSource?
    let precedingSetID: String?
    let precedingRestSeconds: Double?

    var volumeLB: Double { loadLB * Double(reps) }
}

struct WorkoutDay: Identifiable, Equatable {
    let date: Date
    let sets: [LoggedWorkoutSet]
    var id: Date { date }
    var totalVolumeLB: Double { sets.map(\.volumeLB).reduce(0, +) }
}

struct LoadPrediction: Equatable {
    enum Action: String, Equatable {
        case increase = "Increase"
        case keep = "Keep"
        case decrease = "Decrease"
    }

    let loadLB: Double
    let targetReps: Int
    let targetRIR: Int
    let estimatedCapacityLB: Double
    let source: LoggedWorkoutSet
    let sourceCount: Int
    let confidence: Confidence
    let action: Action
    let explanation: String

    enum Confidence: String, Equatable {
        case low = "Low confidence"
        case medium = "Medium confidence"
        case high = "High confidence"
    }
}

struct RestRecommendation: Equatable {
    enum Basis: Equatable {
        case rir
        case velocityLoss(percent: Double)
        case performanceDrop(percent: Double)
    }

    let seconds: Int
    let reps: Int
    let repsInReserve: Int
    let basis: Basis
    let explanation: String

    init?(reps: Int, repsInReserve: Int, velocityLossPercent: Double? = nil,
          precedingRestSeconds: Double? = nil, previousReps: Int? = nil,
          previousRepsInReserve: Int? = nil) {
        guard (1...100).contains(reps), (0...4).contains(repsInReserve) else { return nil }
        // A 90-second floor follows the 2024 hypertrophy meta-analysis. The
        // graduated RIR and high-repetition additions are deliberately coarse:
        // controlled studies support their direction, not an exact curl formula.
        let proximityAddition = 30 * max(0, 3 - repsInReserve)
        let highRepAddition = reps >= 12 ? 30 : 0
        let rirSeconds = 90 + proximityAddition + highRepAddition
        var recommendedSeconds = rirSeconds
        var selectedBasis: Basis = .rir
        var selectedExplanation = "Based on \(reps) reps at \(repsInReserve) RIR."

        // Velocity loss is used as another view of the same set fatigue, so it
        // establishes a floor rather than adding time to the RIR estimate.
        // The 20% and 40% anchors combine controlled rest-interval and recovery
        // findings; the interpolation is an explicit product heuristic.
        if let loss = velocityLossPercent, loss.isFinite, loss >= 20 {
            let boundedLoss = min(40, max(20, loss))
            let velocitySeconds = Int(((180 + (boundedLoss - 20) * 6) / 10).rounded()) * 10
            if velocitySeconds > recommendedSeconds {
                recommendedSeconds = velocitySeconds
                selectedBasis = .velocityLoss(percent: loss)
                selectedExplanation = "\(Int(loss.rounded()))% rep-speed loss raised the recovery target."
            }
        }

        // Zhang et al. (2026) increased a three-minute rest proportionally when
        // repetitions fell by at least 20%. LiftPod compares estimated rep
        // capacity (completed reps + RIR) so sets stopped at different RIR are
        // more comparable. Recommendations never decrease from this feedback.
        if let rest = precedingRestSeconds, rest.isFinite, rest > 0,
           let previousReps, let previousRIR = previousRepsInReserve,
           (1...100).contains(previousReps), (0...4).contains(previousRIR) {
            let previousCapacity = previousReps + previousRIR
            let currentCapacity = reps + repsInReserve
            let decline = Double(previousCapacity - currentCapacity) / Double(previousCapacity)
            if decline >= 0.20 {
                let proportional = rest * (1 + decline)
                let adaptiveSeconds = min(300, Int((proportional / 10).rounded()) * 10)
                if adaptiveSeconds > recommendedSeconds {
                    recommendedSeconds = adaptiveSeconds
                    selectedBasis = .performanceDrop(percent: decline * 100)
                    selectedExplanation = "\(Int((decline * 100).rounded()))% estimated performance drop after \(Int(rest.rounded()))s rest."
                }
            }
        }

        seconds = recommendedSeconds
        self.reps = reps
        self.repsInReserve = repsInReserve
        basis = selectedBasis
        explanation = selectedExplanation
    }
}

/// Stores only user-confirmed sets. Detector output remains a review draft until
/// the user verifies the load, rep count, and optional repetitions in reserve.
@MainActor
final class WorkoutHistoryStore: ObservableObject {
    @Published private(set) var sets: [LoggedWorkoutSet] = []
    @Published private(set) var error: String?

    private let fileURL: URL
    private let calendar: Calendar

    init(fileURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkoutHistory/workouts.json")
        load()
    }

    var days: [WorkoutDay] {
        Dictionary(grouping: sets) { calendar.startOfDay(for: $0.performedAt) }
            .map { WorkoutDay(date: $0.key, sets: $0.value.sorted { $0.performedAt < $1.performedAt }) }
            .sorted { $0.date > $1.date }
    }

    func contains(sessionID: UUID, sourceSetID: String) -> Bool {
        sets.contains { $0.sessionID == sessionID && $0.sourceSetID == sourceSetID }
    }

    @discardableResult
    func confirm(_ draft: SetReviewDraft, loadLB: Double, reps: Int, repsInReserve: Int?) -> Bool {
        guard loadLB.isFinite, (0...1000).contains(loadLB), (1...100).contains(reps),
              repsInReserve.map({ (0...10).contains($0) }) ?? true else {
            error = "Enter a weight from 0 to 1,000 lb, 1–100 reps, and 0–10 RIR."
            return false
        }
        guard !contains(sessionID: draft.sessionID, sourceSetID: draft.id) else { return true }
        let velocityProfile = reps == draft.detectedReps ? draft.velocityProfile : nil
        let rirSource: RIRValueSource? = repsInReserve.map {
            draft.automaticRIR?.repsInReserve == $0 ? .automaticVelocity : .userEntered
        }
        let entry = LoggedWorkoutSet(id: UUID(), sessionID: draft.sessionID, sourceSetID: draft.id,
            exercise: draft.exercise, loadLB: loadLB, reps: reps, repsInReserve: repsInReserve,
            averageRepDuration: draft.averageRepDuration, performedAt: draft.endedAt,
            velocityProfile: velocityProfile, rirValueSource: rirSource,
            precedingSetID: draft.precedingSetID,
            precedingRestSeconds: draft.precedingRestSeconds)
        sets.append(entry)
        sets.sort { $0.performedAt > $1.performedAt }
        guard save() else {
            sets.removeAll { $0.id == entry.id }
            return false
        }
        return true
    }

    func restRecommendation(after set: LoggedWorkoutSet) -> RestRecommendation? {
        guard let rir = set.repsInReserve, (0...10).contains(rir) else { return nil }
        let modeledRIR = min(4, rir)
        let previous = set.precedingSetID.flatMap { precedingID in
            sets.first { $0.sessionID == set.sessionID && $0.sourceSetID == precedingID }
        }
        let comparable = previous.flatMap { candidate -> LoggedWorkoutSet? in
            guard candidate.exercise == set.exercise,
                  abs(candidate.loadLB - set.loadLB) < 0.001,
                  candidate.repsInReserve.map({ (0...10).contains($0) }) == true else { return nil }
            return candidate
        }
        return RestRecommendation(
            reps: set.reps,
            repsInReserve: modeledRIR,
            velocityLossPercent: set.velocityProfile?.velocityLossPercent,
            precedingRestSeconds: comparable == nil ? nil : set.precedingRestSeconds,
            previousReps: comparable?.reps,
            previousRepsInReserve: comparable?.repsInReserve.map { min(4, $0) }
        )
    }

    /// Uses an individual within-set velocity/RIR relationship when enough
    /// user-corrected history exists. Until then, a bench-press velocity-loss
    /// equation is used only as an explicitly low-confidence population prior.
    func automaticRIR(for exercise: V2Exercise, completedReps: Int,
                      velocityProfile: SetVelocityProfile) -> AutomaticRIREstimate? {
        guard completedReps >= 1, let currentLoss = velocityProfile.velocityLossPercent else { return nil }
        let compatible = sets.filter {
            $0.exercise == exercise && $0.rirValueSource == .userEntered &&
            $0.velocityProfile?.estimatorVersion == velocityProfile.estimatorVersion &&
            $0.velocityProfile?.measurementKind == velocityProfile.measurementKind
        }
        if let personalized = Self.personalizedRIR(
            currentLoss: currentLoss, current: velocityProfile,
            calibrationSets: compatible
        ) { return personalized }

        // Gonzalez-Badillo et al. (2017), 50-70% 1RM bench press:
        // percent completed = -0.00855*VL^2 + 1.83311*VL + 5.55281.
        // This is a cold-start heuristic because exercise and measurement mode
        // differ; it is replaced as soon as a validated individual fit exists.
        let modeledLoss = min(75, max(0, currentLoss))
        let percentCompleted = min(95, max(5.55281,
            -0.00855 * modeledLoss * modeledLoss + 1.83311 * modeledLoss + 5.55281))
        let rawRIR = max(0, Double(completedReps) / (percentCompleted / 100) - Double(completedReps))
        let rounded = Int(rawRIR.rounded())
        return .init(repsInReserve: min(4, rounded), velocityLossPercent: currentLoss,
                     measuredRepCount: velocityProfile.availableRepCount,
                     method: .populationHeuristic, confidence: .low,
                     calibrationSetCount: 0, cappedAtFourPlus: rounded >= 4)
    }

    private static func personalizedRIR(currentLoss: Double, current: SetVelocityProfile,
                                        calibrationSets: [LoggedWorkoutSet]) -> AutomaticRIREstimate? {
        guard calibrationSets.count >= 2 else { return nil }
        var points: [(loss: Double, rir: Double)] = []
        for set in calibrationSets {
            guard let finalRIR = set.repsInReserve, let profile = set.velocityProfile,
                  profile.meanLiftingSpeeds.count == set.reps,
                  let baseline = profile.baselineSpeed else { continue }
            for (index, speed) in profile.meanLiftingSpeeds.enumerated() {
                guard let speed, speed.isFinite, speed > 0 else { continue }
                let loss = min(90, max(0, 100 * (1 - speed / baseline)))
                let rir = Double(finalRIR + set.reps - 1 - index)
                if rir <= 15 { points.append((loss, rir)) }
            }
        }
        guard points.count >= 8,
              let minimumLoss = points.map(\.loss).min(), let maximumLoss = points.map(\.loss).max(),
              maximumLoss - minimumLoss >= 15 else { return nil }
        let meanX = points.map(\.loss).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.rir).reduce(0, +) / Double(points.count)
        let denominator = points.reduce(0) { $0 + pow($1.loss - meanX, 2) }
        guard denominator > 0 else { return nil }
        let slope = points.reduce(0) { $0 + ($1.loss - meanX) * ($1.rir - meanY) } / denominator
        let intercept = meanY - slope * meanX
        guard slope < 0 else { return nil }
        let rmse = sqrt(points.reduce(0) {
            let residual = $1.rir - (intercept + slope * $1.loss)
            return $0 + residual * residual
        } / Double(points.count))
        guard rmse <= 2 else { return nil }
        let rawRIR = max(0, intercept + slope * currentLoss)
        let rounded = Int(rawRIR.rounded())
        let confidence: AutomaticRIREstimate.Confidence =
            calibrationSets.count >= 3 && rmse <= 1 ? .high : .medium
        return .init(repsInReserve: min(4, rounded), velocityLossPercent: currentLoss,
                     measuredRepCount: current.availableRepCount, method: .individualized,
                     confidence: confidence, calibrationSetCount: calibrationSets.count,
                     cappedAtFourPlus: rounded >= 4)
    }

    /// Selects one bounded equipment step and a rep target for the next set.
    /// The controller uses the most recent confirmed set as immediate feedback,
    /// while the public-data capacity curve checks whether the adjacent load is
    /// likely to remain inside the requested rep range.
    func nextSetRecommendation(for exercise: V2Exercise, repRange: ClosedRange<Int>,
                               targetRIR: Int, incrementLB: Double = 5) -> LoadPrediction? {
        guard (1...100).contains(repRange.lowerBound),
              (repRange.lowerBound...100).contains(repRange.upperBound),
              (0...4).contains(targetRIR), incrementLB.isFinite, incrementLB > 0,
              let source = sets.first(where: {
                  $0.exercise == exercise && $0.loadLB >= Self.minimumModelLoadLB &&
                  $0.repsInReserve.map { (0...4).contains($0) } == true
              }), let sourceRIR = source.repsInReserve else { return nil }

        let observations = sets.filter { set in
            guard set.exercise == exercise, let rir = set.repsInReserve else { return false }
            return set.loadLB >= Self.minimumModelLoadLB && (0...4).contains(rir) &&
                (2...15).contains(set.reps + rir)
        }.prefix(8).enumerated().compactMap { index, set -> (capacity: Double, weight: Double, set: LoggedWorkoutSet)? in
            guard let rir = set.repsInReserve,
                  let capacity = Self.estimatedCapacity(loadLB: set.loadLB,
                                                        repsToFailure: set.reps + rir) else { return nil }
            // Recent performances matter more; higher RIR receives less weight
            // because subjective RIR is less accurate farther from failure.
            let recencyWeight = pow(0.85, Double(index))
            let effortWeight = 1 / (1 + 0.25 * Double(rir))
            return (capacity, recencyWeight * effortWeight, set)
        }
        let totalWeight = observations.reduce(0) { $0 + $1.weight }
        let capacity: Double? = totalWeight > 0
            ? observations.reduce(0) { $0 + $1.capacity * $1.weight } / totalWeight
            : Self.estimatedCapacity(loadLB: source.loadLB, repsToFailure: source.reps + sourceRIR)
        let dispersion = capacity.flatMap { value -> Double? in
            guard totalWeight > 0, value > 0 else { return nil }
            return observations.reduce(0) {
                $0 + abs($1.capacity - value) * $1.weight
            } / totalWeight / value
        }

        let rirError = sourceRIR - targetRIR
        let repDirection: Int = source.reps < repRange.lowerBound ? -1 :
            (source.reps > repRange.upperBound ? 1 : 0)
        let effortDirection: Int = rirError < -1 ? -1 : (rirError > 1 ? 1 : 0)
        let conflicting = repDirection != 0 && effortDirection != 0 && repDirection != effortDirection
        let direction: Int
        if conflicting {
            direction = 0
        } else if effortDirection != 0 {
            direction = effortDirection
        } else {
            direction = repDirection
        }

        let adjacentLoad = max(Self.minimumModelLoadLB,
                               source.loadLB + Double(direction) * incrementLB)
        let predictedAtAdjacent = capacity.flatMap {
            Self.predictedWorkingReps(capacityLB: $0, loadLB: adjacentLoad,
                                      targetRIR: targetRIR)
        }
        let adjacentFitsRange = predictedAtAdjacent.map {
            $0 >= Double(repRange.lowerBound) - 0.5 && $0 <= Double(repRange.upperBound) + 0.5
        } ?? false

        let recommendedLoad: Double
        if direction == 0 {
            recommendedLoad = source.loadLB
        } else if adjacentFitsRange {
            recommendedLoad = adjacentLoad
        } else if capacity == nil && abs(rirError) >= 2 && repDirection == 0 {
            // A strong, directionally consistent RIR miss may still justify one
            // equipment step when the population curve is outside its rep range.
            recommendedLoad = adjacentLoad
        } else {
            recommendedLoad = source.loadLB
        }

        let predictedReps = capacity.flatMap {
            Self.predictedWorkingReps(capacityLB: $0, loadLB: recommendedLoad,
                                      targetRIR: targetRIR)
        }
        let midpoint = (repRange.lowerBound + repRange.upperBound) / 2
        let targetReps = min(repRange.upperBound, max(repRange.lowerBound,
            predictedReps.map { Int($0.rounded()) } ?? midpoint))
        let action: LoadPrediction.Action = recommendedLoad > source.loadLB ? .increase :
            (recommendedLoad < source.loadLB ? .decrease : .keep)

        let confidence: LoadPrediction.Confidence
        if source.rirValueSource == .automaticVelocity || capacity == nil {
            confidence = .low
        } else if observations.count >= 5 && (dispersion ?? .infinity) <= 0.08 {
            confidence = .high
        } else if observations.count >= 3 && (dispersion ?? .infinity) <= 0.15 {
            confidence = .medium
        } else {
            confidence = .low
        }

        let explanation: String
        if conflicting {
            explanation = String(source.reps) + " reps at " + String(sourceRIR) +
                " RIR gives conflicting load signals. Keep the weight and use the next set as another measurement."
        } else if action == .keep && repRange.contains(source.reps) && abs(rirError) <= 1 {
            explanation = String(source.reps) + " reps at " + String(sourceRIR) + " RIR landed in the " +
                String(repRange.lowerBound) + "–" + String(repRange.upperBound) + " rep target."
        } else if action == .increase {
            explanation = String(source.reps) + " reps at " + String(sourceRIR) + " RIR was easier than the " +
                String(targetRIR) + " RIR target. One heavier step still predicts " + String(targetReps) + " reps."
        } else if action == .decrease {
            explanation = String(source.reps) + " reps at " + String(sourceRIR) + " RIR was harder than the " +
                String(targetRIR) + " RIR target. One lighter step predicts " + String(targetReps) + " reps."
        } else {
            explanation = "The " + incrementLB.formatted() +
                " lb adjacent step misses the target range, so keep this weight and adjust reps."
        }
        return LoadPrediction(loadLB: recommendedLoad, targetReps: targetReps,
                              targetRIR: targetRIR, estimatedCapacityLB: capacity ?? source.loadLB,
                              source: source, sourceCount: observations.count,
                              confidence: confidence, action: action,
                              explanation: explanation)
    }

    private static let poundsPerKilogram = 2.2046226218
    private static let minimumModelLoadLB = 4 * poundsPerKilogram

    /// Weight-dependent equation reported by Marzagao (2026). Kilograms are
    /// required because absolute load is an input to the fitted relationship.
    private static func estimatedCapacity(loadLB: Double, repsToFailure: Int) -> Double? {
        let loadKG = loadLB / poundsPerKilogram
        guard loadKG >= 4, (2...15).contains(repsToFailure) else { return nil }
        let denominator = -2.55 + 4.58 * log(loadKG)
        guard denominator > 0 else { return nil }
        let capacityKG = loadKG * (1 + pow(Double(repsToFailure - 1), 0.85) / denominator)
        return capacityKG.isFinite ? capacityKG * poundsPerKilogram : nil
    }

    private static func load(forCapacityLB capacityLB: Double, repsToFailure: Int) -> Double? {
        var lower = minimumModelLoadLB
        var upper = 1_000.0
        guard let minimumCapacity = estimatedCapacity(loadLB: lower, repsToFailure: repsToFailure),
              capacityLB >= minimumCapacity else { return nil }
        for _ in 0..<80 {
            let midpoint = (lower + upper) / 2
            guard let estimate = estimatedCapacity(loadLB: midpoint, repsToFailure: repsToFailure) else { return nil }
            if estimate < capacityLB { lower = midpoint } else { upper = midpoint }
        }
        return (lower + upper) / 2
    }

    private static func predictedWorkingReps(capacityLB: Double, loadLB: Double,
                                             targetRIR: Int) -> Double? {
        let loadKG = loadLB / poundsPerKilogram
        guard loadKG >= 4, capacityLB >= loadLB else { return nil }
        let denominator = -2.55 + 4.58 * log(loadKG)
        let poweredReps = (capacityLB / loadLB - 1) * denominator
        guard denominator > 0, poweredReps >= 0 else { return nil }
        let repsToFailure = 1 + pow(poweredReps, 1 / 0.85)
        guard repsToFailure.isFinite, (2.0...15.0).contains(repsToFailure) else { return nil }
        return max(1, repsToFailure - Double(targetRIR))
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sets = try decoder.decode([LoggedWorkoutSet].self, from: Data(contentsOf: fileURL))
                .sorted { $0.performedAt > $1.performedAt }
        } catch { self.error = "Could not load workout history: \(error.localizedDescription)" }
    }

    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(sets).write(to: fileURL, options: .atomic)
            error = nil
            return true
        } catch {
            self.error = "Could not save workout history: \(error.localizedDescription)"
            return false
        }
    }
}

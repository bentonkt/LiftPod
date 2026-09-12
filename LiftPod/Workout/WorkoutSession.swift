import Combine
import Foundation

struct WorkoutPolicy: Codable, Equatable {
    var version = "manual-sets-v1"
    var inactivitySeconds = 12.0
    var automaticBoundaries: Bool { version.hasPrefix("automatic-") }
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
            if policy.automaticBoundaries, let last = current?.reps.last,
               rep.end - last.end >= policy.inactivitySeconds {
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
            guard policy.automaticBoundaries, time.isFinite, let last = current?.reps.last,
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
    var setResults: [WorkoutSetResult]? = nil

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
    var precedingPauses: [Double]? = nil

    var hasInterruptedCadence: Bool {
        precedingPauses?.suffix(5).contains { $0.isFinite && $0 > 3 } ?? false
    }

    private var validSpeeds: [(index: Int, speed: Double)] {
        meanLiftingSpeeds.enumerated().compactMap { index, speed in
            guard let speed, speed.isFinite, speed > 0 else { return nil }
            return (index, speed)
        }
    }
    var availableRepCount: Int { validSpeeds.count }
    var baselineSpeed: Double? {
        let early = validSpeeds.filter { $0.index < 3 }.map(\.speed).sorted()
        guard early.count >= 2 else { return nil }
        // Retain a fast reference, but prevent one startup spike from defining fatigue.
        let fastest = early[early.count - 1], runnerUp = early[early.count - 2]
        return fastest > runnerUp * 1.25 ? runnerUp : fastest
    }
    var hasUsableEvidence: Bool {
        meanLiftingSpeeds.count >= 3 && availableRepCount >= 3 &&
        Double(availableRepCount) / Double(meanLiftingSpeeds.count) >= 0.60 &&
        validSpeeds.last?.index == meanLiftingSpeeds.count - 1 && baselineSpeed != nil
    }

    /// A short Theil–Sen fit preserves a sustained decline without letting one
    /// unusually fast/slow rep dictate RIR. Rep indices retain gaps in the data.
    private var recentFit: (speed: Double, slope: Double, residual: Double)? {
        guard hasUsableEvidence else { return nil }
        let points = validSpeeds.filter { $0.index >= meanLiftingSpeeds.count - 5 }
        guard points.count >= 3, let last = points.last else { return nil }
        var slopes: [Double] = []
        for i in points.indices {
            for j in points.indices where j > i {
                slopes.append((points[j].speed - points[i].speed) / Double(points[j].index - points[i].index))
            }
        }
        let slope = Self.median(slopes)
        let atLast = Self.median(points.map { $0.speed + slope * Double(last.index - $0.index) })
        let residual = points.map {
            abs($0.speed - (atLast + slope * Double($0.index - last.index)))
        }.max() ?? 0
        guard atLast.isFinite, atLast > 0, slope.isFinite else { return nil }
        return (atLast, slope, residual)
    }
    var recentSpeed: Double? { recentFit?.speed }
    var slowdownPerRep: Double? {
        guard let baselineSpeed, let fit = recentFit else { return nil }
        return -100 * fit.slope / baselineSpeed
    }
    var isNoisy: Bool {
        guard let baselineSpeed, let fit = recentFit else { return true }
        return fit.residual / baselineSpeed > 0.15
    }
    var velocityLossPercent: Double? {
        guard let baselineSpeed, let speed = recentSpeed else { return nil }
        return min(90, max(0, 100 * (1 - speed / baselineSpeed)))
    }
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    init?(set: SessionSet, metrics: RepMetricsSnapshot?) {
        guard let metrics else { return nil }
        let byID = Dictionary(grouping: metrics.reps, by: \.id)
        let matched = set.reps.map { rep in
            byID[rep.id]?.last
        }
        let speeds = matched.map { metric -> Double? in
            guard metric?.status == .available, let value = metric?.meanLiftingSpeed, value.isFinite, value > 0 else { return nil }
            return value
        }
        let available = speeds.compactMap { $0 }.count
        guard speeds.count >= 3, available >= 3,
              Double(available) / Double(speeds.count) >= 0.60,
              speeds.last! != nil,
              let representative = matched.compactMap({ $0 }).last,
              let estimatorVersion = representative.estimatorVersion,
              let measurementKind = representative.measurementKind else { return nil }
        guard matched.compactMap({ $0 }).filter({ $0.status == .available }).allSatisfy({
            $0.estimatorVersion == estimatorVersion && $0.measurementKind == measurementKind
        }) else { return nil }
        self.meanLiftingSpeeds = speeds
        self.estimatorVersion = estimatorVersion
        self.measurementKind = measurementKind
        precedingPauses = set.reps.enumerated().map { index, rep in
            index == 0 ? 0 : max(0, rep.start - set.reps[index - 1].end)
        }
        guard baselineSpeed != nil, velocityLossPercent != nil else { return nil }
    }

    init?(set: SessionSet, genericMetrics: [GenericCycleMetrics]) {
        let byID = Dictionary(grouping: genericMetrics, by: \.id)
        let matched = set.reps.map { rep in
            byID[rep.id]?.last
        }
        let speeds = matched.map { metric -> Double? in
            guard metric?.status == .available, let value = metric?.meanSpeed, value.isFinite, value > 0 else { return nil }
            return value
        }
        let available = speeds.compactMap { $0 }.count
        guard speeds.count >= 3, available >= 3,
              Double(available) / Double(speeds.count) >= 0.60,
              speeds.last! != nil,
              let estimatorVersion = matched.compactMap({ $0 }).last?.estimatorVersion else { return nil }
        let qualified = matched.compactMap { $0 }.filter { $0.status == .available }
        guard Set(qualified.map(\.learningEpoch)).count == 1,
              qualified.allSatisfy({ $0.estimatorVersion == estimatorVersion }) else { return nil }
        self.meanLiftingSpeeds = speeds
        self.estimatorVersion = estimatorVersion
        self.measurementKind = "generic-cycle-speed"
        precedingPauses = set.reps.enumerated().map { index, rep in
            matched[index]?.precedingPause ?? (index == 0 ? 0 : max(0, rep.start - set.reps[index - 1].end))
        }
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
        case individualized = "Personal rep-speed trajectory"
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
    var lowerRIR: Int = 0
    var upperRIR: Int = 4
    var validationMAE: Double? = nil
    var explanation: String = ""

    var rangeDescription: String {
        let upper = upperRIR >= 4 ? "4+" : String(upperRIR)
        return lowerRIR == upperRIR ? upper : "\(lowerRIR)–\(upper)"
    }
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
        case repHeuristic
        case velocityLoss(percent: Double)
        case performanceDrop(percent: Double)
    }

    let seconds: Int
    let reps: Int
    let repsInReserve: Int?
    let basis: Basis
    let explanation: String

    init?(reps: Int, repsInReserve: Int?, velocityLossPercent: Double? = nil,
          precedingRestSeconds: Double? = nil, previousReps: Int? = nil,
          previousRepsInReserve: Int? = nil) {
        guard (1...100).contains(reps), repsInReserve.map({ (0...4).contains($0) }) ?? true else { return nil }
        // A 90-second floor follows the 2024 hypertrophy meta-analysis. The
        // graduated RIR and high-repetition additions are deliberately coarse:
        // controlled studies support their direction, not an exact curl formula.
        let proximityAddition = 30 * max(0, 3 - (repsInReserve ?? 2))
        let highRepAddition = reps >= 12 ? 30 : 0
        let rirSeconds = 90 + proximityAddition + highRepAddition
        var recommendedSeconds = rirSeconds
        var selectedBasis: Basis = repsInReserve == nil ? .repHeuristic : .rir
        var selectedExplanation = repsInReserve.map { "Based on \(reps) reps at \($0) RIR." }
            ?? "Low confidence · Rep-based rest: 2 minutes, plus 30 seconds for 12+ reps; effort is unknown."

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
        if let repsInReserve, let rest = precedingRestSeconds, rest.isFinite, rest > 0,
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
        let modeledRIR = set.repsInReserve.map { min(4, max(0, $0)) }
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

    /// All paths use the same robust finalized speed features as live coaching.
    func automaticRIR(for exercise: V2Exercise, completedReps: Int,
                      velocityProfile: SetVelocityProfile, loadLB: Double? = nil) -> AutomaticRIREstimate? {
        guard completedReps == velocityProfile.meanLiftingSpeeds.count,
              velocityProfile.hasUsableEvidence,
              let currentLoss = velocityProfile.velocityLossPercent else { return nil }
        let compatible = sets.filter { set in
            set.exercise == exercise && set.rirValueSource == .userEntered &&
            set.repsInReserve.map { (0...4).contains($0) } == true &&
            set.velocityProfile?.estimatorVersion == velocityProfile.estimatorVersion &&
            set.velocityProfile?.measurementKind == velocityProfile.measurementKind &&
            (loadLB.map { load in abs(set.loadLB - load) <= max(2.5, load * 0.25) } ?? true)
        }.prefix(24)
        let samples = compatible.flatMap { set -> [RIRObservation] in
            guard let profile = set.velocityProfile, profile.meanLiftingSpeeds.count == set.reps,
                  let finalRIR = set.repsInReserve, set.reps >= 3 else { return [] }
            return (3...set.reps).compactMap { count in
                var prefix = SetVelocityProfile(meanLiftingSpeeds: Array(profile.meanLiftingSpeeds.prefix(count)),
                    estimatorVersion: profile.estimatorVersion, measurementKind: profile.measurementKind)
                prefix.precedingPauses = profile.precedingPauses.map { Array($0.prefix(count)) }
                let rir = finalRIR + set.reps - count
                guard rir <= 10, prefix.hasUsableEvidence, !prefix.isNoisy, !prefix.hasInterruptedCadence,
                      let features = RIRFeatures(profile: prefix) else { return nil }
                return RIRObservation(setID: set.id, sessionID: set.sessionID, profile: prefix, rir: Double(rir), features: features)
            }
        }
        var rawRIR = Self.populationRIR(reps: completedReps, loss: currentLoss)
        var method: AutomaticRIREstimate.Method = .populationHeuristic
        var confidence: AutomaticRIREstimate.Confidence = .low
        var sourceCount = 0
        var validationMAE: Double?
        if !velocityProfile.isNoisy, !velocityProfile.hasInterruptedCadence,
           let personal = Self.trajectoryRIR(current: velocityProfile, samples: samples) {
            method = .individualized
            rawRIR = personal.rir
            sourceCount = personal.setCount
            // Hold out whole sessions, not adjacent reps from the same set.
            let sessions = Set(samples.map(\.sessionID))
            if sessions.count >= 3 {
                var sessionErrors: [Double] = []
                var priorErrors: [Double] = []
                for sessionID in sessions {
                    let training = samples.filter { $0.sessionID != sessionID }
                    let heldOut = samples.filter { $0.sessionID == sessionID && $0.rir <= 4 }
                    var errorsBySet: [UUID: [Double]] = [:]
                    var priorBySet: [UUID: [Double]] = [:]
                    for point in heldOut {
                        guard let prediction = Self.trajectoryRIR(current: point.profile, samples: training),
                              let loss = point.profile.velocityLossPercent else { continue }
                        errorsBySet[point.setID, default: []].append(abs(prediction.rir - point.rir))
                        priorBySet[point.setID, default: []].append(abs(Self.populationRIR(
                            reps: point.profile.meanLiftingSpeeds.count, loss: loss) - point.rir))
                    }
                    if !heldOut.isEmpty, errorsBySet.values.reduce(0, { $0 + $1.count }) >=
                        Int(ceil(Double(heldOut.count) * 0.8)) {
                        sessionErrors.append(Self.mean(errorsBySet.values.map(Self.mean)))
                        priorErrors.append(Self.mean(priorBySet.values.map(Self.mean)))
                    }
                }
                if sessionErrors.count == sessions.count {
                    let mae = Self.mean(sessionErrors)
                    validationMAE = mae
                    if mae <= 2 && mae <= Self.mean(priorErrors) {
                        confidence = .medium
                    } else {
                        // A failed validation must not silently replace the prior.
                        rawRIR = Self.populationRIR(reps: completedReps, loss: currentLoss)
                        method = .populationHeuristic
                    }
                }
            }
        }
        let uncertainty = confidence == .medium ? max(1, validationMAE ?? 2) :
            (velocityProfile.isNoisy || velocityProfile.hasInterruptedCadence ? 3.0 : 2.0)
        let bounded = min(100, max(0, rawRIR))
        let rounded = Int(bounded.rounded())
        let trend = velocityProfile.slowdownPerRep ?? 0
        let detail = "\(completedReps) reps; \(Int(currentLoss.rounded()))% speed loss; " +
            "\(trend.formatted(.number.precision(.fractionLength(1)))) percentage points of slowdown per rep."
        return .init(repsInReserve: min(4, rounded), velocityLossPercent: currentLoss,
            measuredRepCount: velocityProfile.availableRepCount, method: method,
            confidence: confidence, calibrationSetCount: sourceCount, cappedAtFourPlus: rounded >= 4,
            lowerRIR: min(4, max(0, Int(floor(bounded - uncertainty)))),
            upperRIR: min(4, Int(ceil(bounded + uncertainty))), validationMAE: validationMAE,
            explanation: detail + (velocityProfile.isNoisy ? " Uneven speeds widen the estimate." : "") +
                (velocityProfile.hasInterruptedCadence ? " Longer pauses between reps reduce confidence." : "") +
                (confidence == .medium ? " Checked against held-out sessions." : " Provisional estimate; confirm how the set felt."))
    }

    private struct RIRObservation {
        let setID: UUID
        let sessionID: UUID
        let profile: SetVelocityProfile
        let rir: Double
        let features: RIRFeatures
    }

    /// Cache features once per observation; validation must not refit hundreds
    /// of identical speed windows on the live motion callback.
    private struct RIRFeatures {
        let speed: Double
        let baseline: Double
        let loss: Double
        let trend: Double
        init?(profile: SetVelocityProfile) {
            guard let speed = profile.recentSpeed, let baseline = profile.baselineSpeed,
                  let loss = profile.velocityLossPercent, let trend = profile.slowdownPerRep else { return nil }
            self.speed = speed; self.baseline = baseline; self.loss = loss; self.trend = trend
        }
    }

    /// Match one prefix per previous set: completed reps, absolute speed,
    /// relative loss and rate of decline jointly describe progress through a set.
    private static func trajectoryRIR(current: SetVelocityProfile, samples: [RIRObservation])
        -> (rir: Double, setCount: Int)? {
        guard let speed = current.recentSpeed, let baseline = current.baselineSpeed,
              let loss = current.velocityLossPercent, let trend = current.slowdownPerRep else { return nil }
        var best: [UUID: (distance: Double, rir: Double)] = [:]
        for sample in samples {
            let otherSpeed = sample.features.speed, otherBaseline = sample.features.baseline
            let otherLoss = sample.features.loss, otherTrend = sample.features.trend
            guard abs(otherLoss - loss) <= 20,
                  (0.6...1.67).contains(otherBaseline / baseline) else { continue }
            let distance = pow((otherLoss - loss) / 15, 2) +
                pow(log(otherSpeed / speed) / 0.35, 2) +
                pow((otherTrend - trend) / 5, 2) +
                pow(Double(sample.profile.meanLiftingSpeeds.count - current.meanLiftingSpeeds.count) / 6, 2)
            guard distance <= 4 else { continue }
            if distance < (best[sample.setID]?.distance ?? .infinity) {
                best[sample.setID] = (distance, sample.rir)
            }
        }
        let neighbors = best.sorted {
            $0.value.distance == $1.value.distance ? $0.key.uuidString < $1.key.uuidString :
                $0.value.distance < $1.value.distance
        }.prefix(6).map(\.value)
        guard neighbors.count >= 2 else { return nil }
        let weights = neighbors.map { 1 / (0.25 + $0.distance) }
        let rir = zip(neighbors, weights).reduce(0) { $0 + $1.0.rir * $1.1 } / weights.reduce(0, +)
        return (rir, neighbors.count)
    }

    nonisolated private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func populationRIR(reps: Int, loss: Double) -> Double {
        // González-Badillo 2017 bench-press prior, not a validated AirPod model.
        let modeledLoss = min(75, max(0, loss))
        let percent = min(100, max(5.55281,
            -0.00855 * modeledLoss * modeledLoss + 1.83311 * modeledLoss + 5.55281))
        return min(100, max(0, Double(reps) * (100 / percent - 1)))
    }

    /// Selects one bounded equipment step and a rep target for the next set.
    /// The controller uses the most recent confirmed set as immediate feedback,
    /// while the public-data capacity curve checks whether the adjacent load is
    /// likely to remain inside the requested rep range.
    func nextSetRecommendation(for exercise: V2Exercise, repRange: ClosedRange<Int>,
                               targetRIR: Int, incrementLB: Double = 5,
                               latestSource: LoggedWorkoutSet? = nil) -> LoadPrediction? {
        guard (1...100).contains(repRange.lowerBound),
              (repRange.lowerBound...100).contains(repRange.upperBound),
              (0...4).contains(targetRIR), incrementLB.isFinite, incrementLB > 0,
              let source = latestSource ?? sets.first(where: { $0.exercise == exercise }),
              source.exercise == exercise else { return nil }
        guard let sourceRIR = source.repsInReserve, (0...4).contains(sourceRIR),
              Self.estimatedCapacity(loadLB: source.loadLB,
                                     repsToFailure: source.reps + sourceRIR) != nil else {
            let fallback = WorkoutCoach.repBasedAdjustment(loadLB: source.loadLB, reps: source.reps,
                repRange: repRange, incrementLB: incrementLB)
            return LoadPrediction(loadLB: fallback.load, targetReps: fallback.reps,
                targetRIR: targetRIR, estimatedCapacityLB: source.loadLB,
                source: source, sourceCount: 1, confidence: .low,
                action: fallback.load > source.loadLB ? .increase :
                    (fallback.load < source.loadLB ? .decrease : .keep),
                explanation: fallback.explanation)
        }

        let evidence = [source] + sets.filter { $0.id != source.id }
        let observations = evidence.filter { set in
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

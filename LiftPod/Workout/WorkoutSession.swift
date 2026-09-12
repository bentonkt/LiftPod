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

    init(sessionID: UUID, set: SessionSet, endedAt: Date = Date()) {
        id = set.id
        self.sessionID = sessionID
        exercise = set.prescription.exercise
        detectedReps = set.reps.count
        averageRepDuration = set.reps.isEmpty ? nil : set.averageDuration
        self.endedAt = endedAt
        loadLB = set.prescription.loadLB
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

    var volumeLB: Double { loadLB * Double(reps) }
}

struct WorkoutDay: Identifiable, Equatable {
    let date: Date
    let sets: [LoggedWorkoutSet]
    var id: Date { date }
    var totalVolumeLB: Double { sets.map(\.volumeLB).reduce(0, +) }
}

struct LoadPrediction: Equatable {
    let loadLB: Double
    let estimatedCapacityLB: Double
    let source: LoggedWorkoutSet
    let sourceCount: Int
    let confidence: Confidence

    enum Confidence: String, Equatable {
        case low = "Low confidence"
        case medium = "Medium confidence"
        case high = "High confidence"
    }
}

struct RestRecommendation: Equatable {
    let seconds: Int
    let reps: Int
    let repsInReserve: Int

    init?(reps: Int, repsInReserve: Int) {
        guard (1...100).contains(reps), (0...4).contains(repsInReserve) else { return nil }
        // A 90-second floor follows the 2024 hypertrophy meta-analysis. The
        // graduated RIR and high-repetition additions are deliberately coarse:
        // controlled studies support their direction, not an exact curl formula.
        let proximityAddition = 30 * max(0, 3 - repsInReserve)
        let highRepAddition = reps >= 12 ? 30 : 0
        seconds = 90 + proximityAddition + highRepAddition
        self.reps = reps
        self.repsInReserve = repsInReserve
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
        let entry = LoggedWorkoutSet(id: UUID(), sessionID: draft.sessionID, sourceSetID: draft.id,
            exercise: draft.exercise, loadLB: loadLB, reps: reps, repsInReserve: repsInReserve,
            averageRepDuration: draft.averageRepDuration, performedAt: draft.endedAt)
        sets.append(entry)
        sets.sort { $0.performedAt > $1.performedAt }
        guard save() else {
            sets.removeAll { $0.id == entry.id }
            return false
        }
        return true
    }

    /// Estimates a comparable load from confirmed, near-failure performances.
    /// The load-dependent curve comes from Marzagao's 303,494-set public dataset.
    /// RIR is added to completed reps as an explicit product adaptation, so the
    /// result remains a user-reviewed suggestion rather than an automatic edit.
    func prediction(for exercise: V2Exercise, targetReps: Int, targetRIR: Int,
                    incrementLB: Double = 5) -> LoadPrediction? {
        let targetEffortReps = targetReps + targetRIR
        guard (2...15).contains(targetEffortReps), (0...4).contains(targetRIR),
              incrementLB.isFinite, incrementLB > 0 else { return nil }

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
        guard let source = observations.first?.set, !observations.isEmpty else { return nil }

        let totalWeight = observations.reduce(0) { $0 + $1.weight }
        let capacity = observations.reduce(0) { $0 + $1.capacity * $1.weight } / totalWeight
        let dispersion = observations.reduce(0) {
            $0 + abs($1.capacity - capacity) * $1.weight
        } / totalWeight / capacity
        guard let rawLoad = Self.load(forCapacityLB: capacity, repsToFailure: targetEffortReps) else { return nil }
        let roundedLoad = max(0, (rawLoad / incrementLB).rounded() * incrementLB)
        let confidence: LoadPrediction.Confidence
        if observations.count >= 5 && dispersion <= 0.08 {
            confidence = .high
        } else if observations.count >= 3 && dispersion <= 0.15 {
            confidence = .medium
        } else {
            confidence = .low
        }
        return LoadPrediction(loadLB: roundedLoad, estimatedCapacityLB: capacity,
                              source: source, sourceCount: observations.count,
                              confidence: confidence)
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

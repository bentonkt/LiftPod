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

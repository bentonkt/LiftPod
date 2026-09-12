import Combine
import Foundation

enum TrainingGoal: String, Codable, CaseIterable, Identifiable {
    case strength = "Strength", muscle = "Build muscle", consistency = "Consistency"
    var id: String { rawValue }
}

struct WorkoutPrescription: Codable, Equatable {
    var exercise: V2Exercise = .bicepsCurl
    var goal: TrainingGoal = .muscle
    var loadLB: Double = 25
    var minimumReps = 8
    var maximumReps = 12

    var isValid: Bool {
        loadLB.isFinite && (0...1000).contains(loadLB) &&
        (1...100).contains(minimumReps) && (minimumReps...100).contains(maximumReps)
    }
}

struct WorkoutSetResult: Codable, Identifiable {
    let id: UUID
    let prescription: WorkoutPrescription
    let reps: Int
    let averageRepDuration: Double?
    let movementDuration: Double?
    let interrupted: Bool
    let finishedAt: Date

    var targetDescription: String {
        if interrupted { return "Interrupted — target not assessed" }
        if reps == 0 { return "No complete reps recorded" }
        if reps < prescription.minimumReps { return "Below your rep target" }
        if reps > prescription.maximumReps { return "Above your rep target" }
        return "Within your rep target"
    }
}

/// Retains accepted events across the detector's rolling 12-event snapshot.
struct WorkoutRepLedger {
    private(set) var events: [String: V2CycleEvidence] = [:]
    mutating func observe(_ recent: [V2CycleEvidence]) {
        for event in recent where event.committed && event.rejectionReason == nil {
            events[event.id] = event
        }
    }
    var averageDuration: Double? {
        let durations = events.values.map { $0.completionTimestamp - $0.startTimestamp }
            .filter { $0.isFinite && $0 > 0 }
        return durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)
    }
    var movementDuration: Double? {
        guard let start = events.values.map(\.startTimestamp).min(),
              let end = events.values.map(\.completionTimestamp).max() else { return nil }
        return max(0, end - start)
    }
}

@MainActor
final class WorkoutModel: ObservableObject, WorkoutMotionConsumer {
    @Published var prescription = WorkoutPrescription()
    @Published var mountConfirmed = false
    @Published private(set) var state: V2SetState = .idle
    @Published private(set) var reps = 0
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var result: WorkoutSetResult?
    @Published private(set) var summaryURL: URL?

    @Published private(set) var session: WorkoutSessionReducer?
    @Published private(set) var sessionURL: URL?
    private var sessionID = UUID()
    private let sessionDirectory: URL
    private let engine = V2SetEngine()
    private let makeRecorder: () -> any V2RecordingSink
    private var frozenPrescription: WorkoutPrescription?
    private var ledger = WorkoutRepLedger()
    private var latestSourceTime: Double?
    private var startedAtUptime: Double = 0
    private var lastReceipt: Double?
    private var finishing = false

    init(makeRecorder: @escaping () -> any V2RecordingSink = { V2SessionRecorder() },
         sessionDirectory: URL? = nil) {
        self.makeRecorder = makeRecorder
        self.sessionDirectory = sessionDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Workouts")
    }

    var completedSets: [SessionSet] { session?.sets ?? [] }
    var restStart: Double? { session?.current == nil ? session?.sets.last?.end : nil }
    var sourceTime: Double { latestSourceTime ?? 0 }

    func updateNextSet() {
        guard prescription.isValid, supportedExercise else { error = "Choose an available exercise and valid target."; return }
        session?.apply(.selection(prescription))
    }

    func endSet() {
        guard state == .active, let latestSourceTime else { return }
        session?.apply(.closeSet(latestSourceTime))
        reps = 0
        saveSession(interrupted: false, recordingDirectory: nil)
    }

    var isRunning: Bool { [.preparing, .active, .finalizing].contains(state) || busy }
    var activePrescription: WorkoutPrescription { frozenPrescription ?? prescription }
    var supportedExercise: Bool { prescription.exercise == .bicepsCurl }

    func signalReady(_ capture: CaptureModel, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard capture.motionUpdatesActive, let sample = capture.latestSample else { return false }
        let age = now - sample.receiptUptime
        return age >= 0 && age < 0.25 && sample.sensorLocation == .rightHeadphone
    }

    func canStart(_ capture: CaptureModel) -> Bool {
        !isRunning && prescription.isValid && supportedExercise && mountConfirmed &&
        !capture.recordingActive && signalReady(capture)
    }

    func start(_ capture: CaptureModel) async {
        guard canStart(capture) else { return }
        busy = true
        defer { busy = false }
        error = nil; result = nil; summaryURL = nil
        ledger = WorkoutRepLedger(); reps = 0; latestSourceTime = nil; lastReceipt = nil
        frozenPrescription = prescription
        sessionID = UUID()
        session = WorkoutSessionReducer(prescription: prescription)
        sessionURL = nil
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        capture.workoutConsumer = self
        do {
            try await engine.start(profile: .bundledCurl, recorder: makeRecorder(),
                                   motionActive: capture.motionUpdatesActive, sideVerified: true,
                                   noOtherRecording: !capture.recordingActive, setupConfirmed: mountConfirmed)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func ingest(_ sample: RawMotionSample) async {
        guard [.preparing, .active, .finalizing].contains(state) else { return }
        lastReceipt = sample.receiptUptime
        latestSourceTime = sample.sourceTimestamp
        await engine.ingest(sample)
        await refresh()
    }

    func end() async {
        guard state == .active, !busy, let latestSourceTime else { return }
        busy = true
        defer { busy = false }
        do { try await engine.requestEnd(at: latestSourceTime); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func cancelPreparation() async {
        guard state == .preparing, !busy else { return }
        await engine.cancel()
        await refresh()
    }

    func motionUnavailable() async {
        guard [.preparing, .active, .finalizing].contains(state) else { return }
        await engine.motionDisconnected()
        await refresh()
    }

    /// Detects a stopped stream even when no further callback arrives.
    func checkStaleness(now: Double = ProcessInfo.processInfo.systemUptime) async {
        guard [.preparing, .active, .finalizing].contains(state),
              now - (lastReceipt ?? startedAtUptime) > 0.5 else { return }
        error = "Motion stopped arriving. Reconnect the AirPod and start a new set."
        await motionUnavailable()
    }

    func reset() {
        guard !isRunning else { return }
        state = .idle; result = nil; summaryURL = nil; error = nil; reps = 0; session = nil; sessionURL = nil
    }

    private func refresh() async {
        let snapshot = await engine.snapshot
        let newEvents = snapshot.recentEvents.filter { $0.committed && $0.rejectionReason == nil && ledger.events[$0.id] == nil }
            .sorted { $0.completionTimestamp < $1.completionTimestamp }
        ledger.observe(snapshot.recentEvents)
        let previousSetCount = session?.sets.count ?? 0
        for event in newEvents { session?.apply(.rep(SessionRep(event))) }
        if let latestSourceTime { session?.apply(.clock(latestSourceTime)) }
        if (session?.sets.count ?? 0) != previousSetCount { saveSession(interrupted: false, recordingDirectory: nil) }
        // The detector clears its event buffer when interrupted; retain confirmed reps.
        reps = session?.current?.reps.count ?? 0
        state = snapshot.setState
        guard [.complete, .interrupted].contains(state), result == nil, !finishing,
              let frozenPrescription else { return }
        finishing = true
        defer { finishing = false }
        session?.apply(.end(latestSourceTime ?? 0, interrupted: state == .interrupted))
        let accepted = session?.sets.flatMap(\.reps) ?? []
        reps = accepted.count
        let averageDuration = accepted.isEmpty ? nil : accepted.map(\.duration).reduce(0, +) / Double(accepted.count)
        let movementDuration = accepted.first.flatMap { first in accepted.last.map { $0.end - first.start } }
        let descriptor = await engine.descriptor
        let completed = WorkoutSetResult(
            id: descriptor?.setID ?? UUID(), prescription: frozenPrescription, reps: reps,
            averageRepDuration: averageDuration, movementDuration: movementDuration,
            interrupted: state == .interrupted, finishedAt: Date())
        result = completed
        if state == .interrupted, error == nil {
            error = "This set was interrupted. Recorded reps are retained; start a new set when ready."
        }
        let bundle = await engine.completedBundle
        saveSession(interrupted: state == .interrupted, recordingDirectory: bundle?.directory.path)
        if let bundle {
            do {
                let url = bundle.directory.appendingPathComponent("workout-summary.json")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(completed).write(to: url, options: .atomic)
                summaryURL = url
            } catch { self.error = "Could not save workout summary: \(error.localizedDescription)" }
        } else if state == .complete {
            error = "The recording could not be saved."
        }
    }
    private func saveSession(interrupted: Bool, recordingDirectory: String?) {
        guard let session, let frozenPrescription else { return }
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            let archive = WorkoutSessionArchive(schemaVersion: 1, sessionID: sessionID,
                initialPrescription: frozenPrescription, policy: session.policy, inputs: session.inputs,
                sets: session.sets, interrupted: interrupted, recordingDirectory: recordingDirectory)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = sessionDirectory.appendingPathComponent("\(sessionID.uuidString).json")
            try encoder.encode(archive).write(to: url, options: .atomic)
            sessionURL = url
        } catch { self.error = "Could not save session: \(error.localizedDescription)" }
    }

}

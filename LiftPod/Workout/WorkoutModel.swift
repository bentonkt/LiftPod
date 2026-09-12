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
    var targetRIR = 2
    var equipmentIncrementLB = 5.0

    var isValid: Bool {
        loadLB.isFinite && (0...1000).contains(loadLB) &&
        (1...100).contains(minimumReps) && (minimumReps...100).contains(maximumReps) &&
        (0...4).contains(targetRIR) && equipmentIncrementLB.isFinite &&
        (0.5...100).contains(equipmentIncrementLB)
    }

    private enum CodingKeys: String, CodingKey {
        case exercise, goal, loadLB, minimumReps, maximumReps, targetRIR, equipmentIncrementLB
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exercise = try values.decodeIfPresent(V2Exercise.self, forKey: .exercise) ?? .bicepsCurl
        goal = try values.decodeIfPresent(TrainingGoal.self, forKey: .goal) ?? .muscle
        loadLB = try values.decodeIfPresent(Double.self, forKey: .loadLB) ?? 25
        minimumReps = try values.decodeIfPresent(Int.self, forKey: .minimumReps) ?? 8
        maximumReps = try values.decodeIfPresent(Int.self, forKey: .maximumReps) ?? 12
        targetRIR = try values.decodeIfPresent(Int.self, forKey: .targetRIR) ?? 2
        equipmentIncrementLB = try values.decodeIfPresent(Double.self, forKey: .equipmentIncrementLB) ?? 5
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
    @Published var countingMode: RepCountingMode = .generic
    @Published var mountConfirmed = false
    @Published private(set) var state: V2SetState = .idle
    @Published private(set) var reps = 0
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var result: WorkoutSetResult?
    @Published private(set) var summaryURL: URL?

    @Published private(set) var session: WorkoutSessionReducer?
    @Published private(set) var sessionURL: URL?
    @Published private(set) var pendingSetReviews: [SetReviewDraft] = []
    let history: WorkoutHistoryStore
    private var sessionID = UUID()
    private let sessionDirectory: URL
    private let genericSession = GenericRepSession()
    private let profileEngine = V2SetEngine()
    private let makeProfileRecorder: () -> any V2RecordingSink
    private var runningGeneric = true
    private var frozenPrescription: WorkoutPrescription?
    private var genericEventIDs: Set<String> = []
    private var genericMetrics: [String: GenericCycleMetrics] = [:]
    private var profileLedger = WorkoutRepLedger()
    private var profileMetrics: RepMetricsSnapshot?
    private var firstSourceTime: Double?
    private var latestSourceTime: Double?
    private var startedAtUptime: Double = 0
    private var lastReceipt: Double?
    private var finishing = false

    init(sessionDirectory: URL? = nil, historyFileURL: URL? = nil,
         makeProfileRecorder: @escaping () -> any V2RecordingSink = { V2SessionRecorder() }) {
        self.sessionDirectory = sessionDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Workouts")
        self.makeProfileRecorder = makeProfileRecorder
        history = WorkoutHistoryStore(fileURL: historyFileURL)
    }

    var completedSets: [SessionSet] { session?.sets ?? [] }
    var restStart: Double? { session?.current == nil ? session?.sets.last?.end : nil }
    var sourceTime: Double { latestSourceTime ?? 0 }
    var elapsedTime: Double { max(0, sourceTime - (firstSourceTime ?? sourceTime)) }
    var activeTime: Double {
        let recorded = completedSets.flatMap(\.reps).map(\.duration).reduce(0, +)
        return recorded + (session?.current?.reps.map(\.duration).reduce(0, +) ?? 0)
    }
    var currentPace: Double? { session?.current?.averageDuration }
    var timeoutRemaining: Double? {
        session?.current.map { max(0, 12 - (sourceTime - $0.end)) }
    }
    var restRecommendation: RestRecommendation? {
        guard session?.current == nil, let sourceSetID = completedSets.last?.id else { return nil }
        if let confirmed = history.sets.first(where: {
            $0.sessionID == sessionID && $0.sourceSetID == sourceSetID
        }) {
            return history.restRecommendation(after: confirmed)
        }
        guard let draft = pendingSetReviews.first(where: { $0.id == sourceSetID }),
              let estimate = draft.automaticRIR else { return nil }
        return RestRecommendation(reps: draft.detectedReps,
                                  repsInReserve: estimate.repsInReserve,
                                  velocityLossPercent: draft.velocityProfile?.velocityLossPercent)
    }

    func updateNextSet() {
        guard prescription.isValid, supportedExercise else { error = "Choose an available exercise and valid target."; return }
        session?.apply(.selection(prescription))
    }

    func applyGoalDefaults() {
        switch prescription.goal {
        case .strength:
            prescription.minimumReps = 3; prescription.maximumReps = 6; prescription.targetRIR = 2
        case .muscle:
            prescription.minimumReps = 8; prescription.maximumReps = 12; prescription.targetRIR = 2
        case .consistency:
            prescription.minimumReps = 10; prescription.maximumReps = 15; prescription.targetRIR = 3
        }
    }

    func endSet() {
        guard state == .active, let latestSourceTime else { return }
        let previousSetCount = session?.sets.count ?? 0
        session?.apply(.closeSet(latestSourceTime))
        enqueueSetReviews(after: previousSetCount)
        reps = 0
        saveSession(interrupted: false, recordingDirectory: nil)
    }

    @discardableResult
    func confirmSet(_ draft: SetReviewDraft, loadLB: Double, reps: Int, repsInReserve: Int?) -> Bool {
        guard history.confirm(draft, loadLB: loadLB, reps: reps, repsInReserve: repsInReserve) else {
            error = history.error
            return false
        }
        pendingSetReviews.removeAll { $0.sessionID == draft.sessionID && $0.id == draft.id }
        error = nil
        return true
    }

    func loadPrediction() -> LoadPrediction? {
        history.nextSetRecommendation(for: prescription.exercise,
            repRange: prescription.minimumReps...prescription.maximumReps,
            targetRIR: prescription.targetRIR,
            incrementLB: prescription.equipmentIncrementLB)
    }

    func use(_ prediction: LoadPrediction) {
        guard !isRunning || session?.current == nil else { return }
        prescription.loadLB = prediction.loadLB
        session?.apply(.selection(prescription))
    }

    var isRunning: Bool { [.preparing, .active, .finalizing].contains(state) || busy }
    var activePrescription: WorkoutPrescription { session?.current?.prescription ?? session?.prescription ?? frozenPrescription ?? prescription }
    var selectedProfile: V2DSPProfile? {
        switch prescription.exercise {
        case .bicepsCurl: .adaptiveCurlV6
        case .lateralRaise: .lateralRaiseV6
        case .overheadPress: nil
        }
    }
    var supportedExercise: Bool { countingMode == .generic || selectedProfile != nil }

    func signalReady(_ capture: CaptureModel, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        capture.liveSensor(now: now) == .rightHeadphone
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
        genericEventIDs = []; genericMetrics = [:]; profileLedger = .init(); profileMetrics = nil
        reps = 0; firstSourceTime = nil; latestSourceTime = nil; lastReceipt = nil
        frozenPrescription = prescription
        sessionID = UUID()
        session = WorkoutSessionReducer(prescription: prescription)
        sessionURL = nil
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        capture.workoutConsumer = self
        do {
            if countingMode == .generic {
                try await genericSession.start(side: .right, metricsEnabled: true,
                                               directory: sessionDirectory)
                runningGeneric = true
            } else if let selectedProfile {
                try await profileEngine.start(profile: selectedProfile,
                    recorder: makeProfileRecorder(), motionActive: capture.motionUpdatesActive,
                    sideVerified: true, noOtherRecording: !capture.recordingActive,
                    setupConfirmed: mountConfirmed, metricsConfiguration: .cyclicDevicePath3D)
                runningGeneric = false
            } else {
                error = "No bundled profile is available for this exercise. Use Generic movement."
                return
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func ingest(_ sample: RawMotionSample) async {
        guard [.preparing, .active, .finalizing].contains(state) else { return }
        firstSourceTime = firstSourceTime ?? sample.sourceTimestamp
        lastReceipt = sample.receiptUptime
        latestSourceTime = sample.sourceTimestamp
        if runningGeneric {
            do { try await genericSession.apply(.init(kind: .sample, raw: RawMotionEvent(sample))) }
            catch { self.error = error.localizedDescription }
        } else {
            await profileEngine.ingest(sample)
        }
        await refresh()
    }

    func end() async {
        guard state == .active, !busy, let latestSourceTime else { return }
        busy = true
        defer { busy = false }
        do {
            if runningGeneric {
                try await genericSession.apply(.init(kind: .end, timestamp: latestSourceTime))
            } else {
                try await profileEngine.requestEnd(at: latestSourceTime)
            }
            await refresh()
        }
        catch { self.error = error.localizedDescription }
    }

    func cancelPreparation() async {
        guard state == .preparing, !busy else { return }
        if runningGeneric {
            try? await genericSession.apply(.init(kind: .interrupt, interruption: .explicitCancellation))
        } else {
            await profileEngine.cancel()
        }
        await refresh()
    }

    func motionUnavailable() async {
        guard [.preparing, .active, .finalizing].contains(state) else { return }
        if runningGeneric {
            try? await genericSession.apply(.init(kind: .interrupt, interruption: .disconnect))
        } else {
            await profileEngine.motionDisconnected()
        }
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
        let snapshot: V2ProcessorSnapshot
        if runningGeneric {
            guard let genericSnapshot = await genericSession.snapshot else { return }
            snapshot = genericSnapshot
        } else {
            snapshot = await profileEngine.snapshot
        }
        let previousSetCount = session?.sets.count ?? 0
        if runningGeneric {
            for metric in snapshot.generic?.metrics ?? [] { genericMetrics[metric.id] = metric }
            let newEvents = (snapshot.generic?.events ?? [])
                .filter { !genericEventIDs.contains($0.id) }
                .sorted { $0.completionTimestamp < $1.completionTimestamp }
            for event in newEvents {
                genericEventIDs.insert(event.id)
                session?.apply(.rep(SessionRep(event, exercise: activePrescription.exercise)))
            }
        } else {
            profileMetrics = snapshot.metrics
            let newEvents = snapshot.recentEvents.filter {
                $0.committed && $0.rejectionReason == nil && profileLedger.events[$0.id] == nil
            }.sorted { $0.completionTimestamp < $1.completionTimestamp }
            profileLedger.observe(snapshot.recentEvents)
            for event in newEvents { session?.apply(.rep(SessionRep(event))) }
        }
        if let latestSourceTime { session?.apply(.clock(latestSourceTime)) }
        enqueueSetReviews(after: previousSetCount)
        if (session?.sets.count ?? 0) != previousSetCount { saveSession(interrupted: false, recordingDirectory: nil) }
        // The detector clears its event buffer when interrupted; retain confirmed reps.
        reps = session?.current?.reps.count ?? 0
        state = snapshot.setState
        guard [.complete, .interrupted].contains(state), result == nil, !finishing,
              let frozenPrescription else { return }
        finishing = true
        defer { finishing = false }
        let setCountBeforeEnd = session?.sets.count ?? 0
        session?.apply(.end(latestSourceTime ?? 0, interrupted: state == .interrupted))
        enqueueSetReviews(after: setCountBeforeEnd)
        let accepted = session?.sets.flatMap(\.reps) ?? []
        reps = accepted.count
        let averageDuration = accepted.isEmpty ? nil : accepted.map(\.duration).reduce(0, +) / Double(accepted.count)
        let movementDuration = accepted.first.flatMap { first in accepted.last.map { $0.end - first.start } }
        let detectorSetID = runningGeneric ? snapshot.generic?.events.first?.setID : await profileEngine.descriptor?.setID
        let completed = WorkoutSetResult(
            id: detectorSetID ?? UUID(), prescription: frozenPrescription, reps: reps,
            averageRepDuration: averageDuration, movementDuration: movementDuration,
            interrupted: state == .interrupted, finishedAt: Date())
        result = completed
        if state == .interrupted, error == nil {
            error = "This set was interrupted. Recorded reps are retained; start a new set when ready."
        }
        let bundle = runningGeneric ? await genericSession.completedBundle : await profileEngine.completedBundle
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

    private func enqueueSetReviews(after previousSetCount: Int) {
        guard let session, session.sets.count > previousSetCount else { return }
        for (index, set) in session.sets.enumerated() where index >= previousSetCount {
            let duplicate = pendingSetReviews.contains { $0.sessionID == sessionID && $0.id == set.id }
            guard !duplicate, !history.contains(sessionID: sessionID, sourceSetID: set.id) else { continue }
            let velocityProfile = runningGeneric
                ? SetVelocityProfile(set: set, genericMetrics: Array(genericMetrics.values))
                : SetVelocityProfile(set: set, metrics: profileMetrics)
            let automaticRIR = velocityProfile.flatMap {
                history.automaticRIR(for: set.prescription.exercise,
                                     completedReps: set.reps.count,
                                     velocityProfile: $0)
            }
            let precedingSet = index > 0 ? session.sets[index - 1] : nil
            let precedingRest = precedingSet.map { max(0, set.start - $0.end) }
            pendingSetReviews.append(SetReviewDraft(sessionID: sessionID, set: set,
                                                     velocityProfile: velocityProfile,
                                                     automaticRIR: automaticRIR,
                                                     precedingSetID: precedingSet?.id,
                                                     precedingRestSeconds: precedingRest))
        }
    }

}

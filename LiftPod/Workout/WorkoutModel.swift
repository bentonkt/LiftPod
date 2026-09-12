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
    var slowdownPercent: Double? = nil
    var coaching: WorkoutCoachingSnapshot? = nil
    var nextSetPlan: NextSetPlan? = nil

    var targetDescription: String {
        if interrupted { return "Interrupted — target not assessed" }
        if reps == 0 { return "No complete reps recorded" }
        if reps < prescription.minimumReps { return "Below your rep target" }
        if reps > prescription.maximumReps { return "Above your rep target" }
        return "Within your rep target"
    }
}

enum WorkoutCoachingState: String, Codable, Equatable {
    case buildingBaseline
    case steady
    case approachingTarget
    case targetReached
    case unavailable

    var title: String {
        switch self {
        case .buildingBaseline: "Building baseline"
        case .steady: "Keep going"
        case .approachingTarget: "Approaching target"
        case .targetReached: "Target reached"
        case .unavailable: "Coaching unavailable"
        }
    }
}

struct WorkoutCoachingSnapshot: Codable, Equatable {
    let state: WorkoutCoachingState
    let slowdownPercent: Double?
    let explanation: String
    let evidenceIsValid: Bool
}

enum NextSetAction: String, Codable, Equatable {
    case keepLoad
    case lowerLoad
    case considerHeavierLoad
    case noRecommendation
}

struct NextSetPlan: Codable, Equatable {
    let action: NextSetAction
    let title: String
    let explanation: String
}

enum WorkoutCoach {
    static func evaluate(snapshot: V2ProcessorSnapshot, reps: Int,
                         prescription: WorkoutPrescription) -> WorkoutCoachingSnapshot {
        guard snapshot.quality == .usable, snapshot.isRecovering != true else {
            return .init(state: .unavailable, slowdownPercent: nil,
                         explanation: snapshot.qualityDetail ?? "The motion signal is not reliable enough for coaching.",
                         evidenceIsValid: false)
        }
        guard let metrics = snapshot.metrics, let baseline = metrics.baselineMeanLiftingSpeed,
              baseline.isFinite, baseline > 0 else {
            return .init(state: .buildingBaseline, slowdownPercent: nil,
                         explanation: "Complete three smooth reps to establish your baseline.",
                         evidenceIsValid: false)
        }
        let qualified = metrics.reps.filter { $0.status == .available }
            .compactMap { metrics.slowdownPercent(for: $0) }.filter(\.isFinite)
        guard !qualified.isEmpty else {
            return .init(state: .buildingBaseline, slowdownPercent: nil,
                         explanation: "Waiting for a qualified rep measurement.", evidenceIsValid: false)
        }
        let recent = qualified.suffix(2)
        let smoothed = recent.reduce(0, +) / Double(recent.count)
        if reps >= prescription.maximumReps {
            return .init(state: .targetReached, slowdownPercent: smoothed,
                         explanation: "You reached the top of your target range.", evidenceIsValid: true)
        }
        if smoothed >= 19.5 {
            return .init(state: .targetReached, slowdownPercent: smoothed,
                         explanation: "Recent reps are \(rounded(smoothed))% slower than your baseline.", evidenceIsValid: true)
        }
        if smoothed >= 12 {
            return .init(state: .approachingTarget, slowdownPercent: smoothed,
                         explanation: "Recent reps are \(rounded(smoothed))% slower than your baseline.", evidenceIsValid: true)
        }
        return .init(state: .steady, slowdownPercent: smoothed,
                     explanation: "Recent reps remain near your baseline.", evidenceIsValid: true)
    }

    static func nextSetPlan(for result: WorkoutSetResult) -> NextSetPlan {
        guard !result.interrupted, let coaching = result.coaching, coaching.evidenceIsValid else {
            return .init(action: .noRecommendation, title: "No load recommendation",
                         explanation: "Keep your current setup and verify the next set from a clean signal.")
        }
        if result.reps >= result.prescription.maximumReps,
           let slowdown = coaching.slowdownPercent, slowdown < 12 {
            return .init(action: .considerHeavierLoad, title: "Consider a heavier load",
                         explanation: "You completed the full range while your qualified reps stayed steady.")
        }
        if coaching.state == .targetReached && result.reps < result.prescription.minimumReps {
            return .init(action: .lowerLoad, title: "Use a lighter load",
                         explanation: "Your slowdown target arrived before \(result.prescription.minimumReps) reps.")
        }
        if coaching.state == .targetReached && result.reps <= result.prescription.maximumReps {
            return .init(action: .keepLoad,
                         title: "Keep \(result.prescription.loadLB.formatted()) lb",
                         explanation: "You reached the target inside your rep range.")
        }
        return .init(action: .noRecommendation, title: "Keep the plan for now",
                     explanation: "This set did not provide enough evidence for a load change.")
    }

    static func nextSetPlan(from prediction: LoadPrediction) -> NextSetPlan {
        let action: NextSetAction = switch prediction.action {
        case .increase: .considerHeavierLoad
        case .keep: .keepLoad
        case .decrease: .lowerLoad
        }
        return .init(action: action,
                     title: "\(prediction.loadLB.formatted()) lb × \(prediction.targetReps)",
                     explanation: prediction.explanation)
    }

    private static func rounded(_ value: Double) -> Int { Int(value.rounded()) }

    static func evaluate(velocityProfile: SetVelocityProfile?, reps: Int,
                         prescription: WorkoutPrescription) -> WorkoutCoachingSnapshot {
        guard let velocityProfile, let slowdown = velocityProfile.velocityLossPercent else {
            return .init(state: .buildingBaseline, slowdownPercent: nil,
                         explanation: "Complete three smooth reps to establish your baseline.",
                         evidenceIsValid: false)
        }
        if reps >= prescription.maximumReps {
            return .init(state: .targetReached, slowdownPercent: slowdown,
                         explanation: "You reached the top of your target range.", evidenceIsValid: true)
        }
        if slowdown >= 19.5 {
            return .init(state: .targetReached, slowdownPercent: slowdown,
                         explanation: "Recent reps are \(rounded(slowdown))% slower than your baseline.",
                         evidenceIsValid: true)
        }
        if slowdown >= 12 {
            return .init(state: .approachingTarget, slowdownPercent: slowdown,
                         explanation: "Recent reps are \(rounded(slowdown))% slower than your baseline.",
                         evidenceIsValid: true)
        }
        return .init(state: .steady, slowdownPercent: slowdown,
                     explanation: "Recent reps remain near your baseline.", evidenceIsValid: true)
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
    @Published private(set) var latestSetResult: WorkoutSetResult?
    @Published private(set) var completedSetResults: [WorkoutSetResult] = []
    @Published private(set) var coaching = WorkoutCoachingSnapshot(
        state: .buildingBaseline, slowdownPercent: nil,
        explanation: "Complete three smooth reps to establish your baseline.", evidenceIsValid: false)
    @Published private(set) var summaryURL: URL?

    @Published private(set) var session: WorkoutSessionReducer?
    @Published private(set) var sessionURL: URL?
    @Published private(set) var pendingSetReviews: [SetReviewDraft] = []
    let history: WorkoutHistoryStore
    private var sessionID = UUID()
    private var initialPrescription: WorkoutPrescription?
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
    private var sessionStartedAtUptime: Double?
    private var finalizedElapsedTime: Double?
    private var lastReceipt: Double?
    private var finishing = false
    private var betweenSetStartedAt: Double?
    private var resultBeforePreparation: WorkoutSetResult?
    private var restStartBeforePreparation: Double?
    private var summaryURLBeforePreparation: URL?

    init(sessionDirectory: URL? = nil, historyFileURL: URL? = nil,
         makeProfileRecorder: @escaping () -> any V2RecordingSink = { V2SessionRecorder() }) {
        self.sessionDirectory = sessionDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Workouts")
        self.makeProfileRecorder = makeProfileRecorder
        history = WorkoutHistoryStore(fileURL: historyFileURL)
    }

    var completedSets: [SessionSet] { session?.sets ?? [] }
    var restStart: Double? { betweenSetStartedAt }
    var sourceTime: Double { latestSourceTime ?? 0 }
    var elapsedTime: Double {
        if let finalizedElapsedTime { return finalizedElapsedTime }
        let sourceElapsed = max(0, sourceTime - (firstSourceTime ?? sourceTime))
        let wallElapsed = sessionStartedAtUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
        return max(sourceElapsed, wallElapsed)
    }
    var activeTime: Double {
        let recorded = completedSets.flatMap(\.reps).map(\.duration).reduce(0, +)
        return recorded + (session?.current?.reps.map(\.duration).reduce(0, +) ?? 0)
    }
    var currentPace: Double? { session?.current?.averageDuration }
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
        guard !isRunning, session?.current == nil else { return }
        prescription.loadLB = prediction.loadLB
        session?.apply(.selection(prescription))
    }

    var isRunning: Bool { [.preparing, .active, .finalizing].contains(state) || busy }
    var workoutStarted: Bool { session != nil && result == nil }
    var betweenSets: Bool { workoutStarted && !isRunning && latestSetResult != nil }
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

    func startSet(_ capture: CaptureModel) async {
        guard canStart(capture) else { return }
        busy = true
        defer { busy = false }
        resultBeforePreparation = latestSetResult
        restStartBeforePreparation = betweenSetStartedAt
        summaryURLBeforePreparation = summaryURL
        error = nil; result = nil; summaryURL = nil; latestSetResult = nil
        genericEventIDs = []; genericMetrics = [:]; profileLedger = .init(); profileMetrics = nil
        reps = 0; lastReceipt = nil; betweenSetStartedAt = nil
        frozenPrescription = prescription
        if session == nil {
            sessionID = UUID()
            sessionStartedAtUptime = ProcessInfo.processInfo.systemUptime
            finalizedElapsedTime = nil
            initialPrescription = prescription
            session = WorkoutSessionReducer(prescription: prescription)
            completedSetResults = []
            sessionURL = nil
            firstSourceTime = nil
            latestSourceTime = nil
        } else {
            session?.apply(.selection(prescription))
        }
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
                throw V2Error.invalidLifecycle("No bundled profile is available for this exercise. Use Generic movement.")
            }
            await refresh()
        } catch {
            self.error = error.localizedDescription
            restoreAfterAbandonedSet()
        }
    }

    func start(_ capture: CaptureModel) async { await startSet(capture) }

    func ingest(_ sample: RawMotionSample) async {
        guard workoutStarted else { return }
        firstSourceTime = firstSourceTime ?? sample.sourceTimestamp
        latestSourceTime = sample.sourceTimestamp
        guard [.preparing, .active, .finalizing].contains(state) else { return }
        lastReceipt = sample.receiptUptime
        if runningGeneric {
            do { try await genericSession.apply(.init(kind: .sample, raw: RawMotionEvent(sample))) }
            catch { self.error = error.localizedDescription }
        } else {
            await profileEngine.ingest(sample)
        }
        await refresh()
    }

    func endSet() async {
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

    func end() async { await endSet() }

    func finishWorkout() {
        guard workoutStarted, !isRunning else { return }
        finalizedElapsedTime = elapsedTime
        let interrupted = state == .interrupted
        if !interrupted, let latestSourceTime { session?.apply(.end(latestSourceTime, interrupted: false)) }
        let accepted = completedSets.flatMap(\.reps)
        let average = accepted.isEmpty ? nil : accepted.map(\.duration).reduce(0, +) / Double(accepted.count)
        let movement = accepted.first.flatMap { first in accepted.last.map { $0.end - first.start } }
        result = WorkoutSetResult(id: sessionID, prescription: initialPrescription ?? prescription,
                                  reps: accepted.count, averageRepDuration: average,
                                  movementDuration: movement, interrupted: interrupted, finishedAt: Date())
        saveSession(interrupted: interrupted, recordingDirectory: nil)
    }

    func cancelPreparation() async {
        guard state == .preparing, !busy else { return }
        if runningGeneric {
            try? await genericSession.apply(.init(kind: .interrupt, interruption: .explicitCancellation))
        } else {
            await profileEngine.cancel()
        }
        restoreAfterAbandonedSet()
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
        state = .idle; result = nil; latestSetResult = nil; summaryURL = nil; error = nil
        reps = 0; session = nil; sessionURL = nil; completedSetResults = []; initialPrescription = nil
        frozenPrescription = nil; betweenSetStartedAt = nil; sessionStartedAtUptime = nil
        finalizedElapsedTime = nil
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
        reps = session?.current?.reps.count ?? 0
        if runningGeneric {
            let velocity = session?.current.flatMap {
                SetVelocityProfile(set: $0, genericMetrics: Array(genericMetrics.values))
            }
            coaching = WorkoutCoach.evaluate(velocityProfile: velocity, reps: reps,
                                             prescription: frozenPrescription ?? prescription)
        } else {
            coaching = WorkoutCoach.evaluate(snapshot: snapshot, reps: reps,
                                             prescription: frozenPrescription ?? prescription)
        }
        state = snapshot.setState
        if state == .interrupted {
            coaching = .init(state: .unavailable, slowdownPercent: nil,
                             explanation: "The set ended before coaching evidence could be finalized.",
                             evidenceIsValid: false)
        }
        guard [.complete, .interrupted].contains(state), latestSetResult == nil, !finishing,
              let frozenPrescription else { return }
        finishing = true
        defer { finishing = false }
        let setCountBeforeEnd = previousSetCount
        let accepted = session?.current?.reps ?? []
        if state == .interrupted {
            session?.apply(.end(latestSourceTime ?? 0, interrupted: true))
        } else {
            session?.apply(.closeSet(latestSourceTime ?? 0))
        }
        enqueueSetReviews(after: setCountBeforeEnd)
        reps = accepted.count
        let averageDuration = accepted.isEmpty ? nil : accepted.map(\.duration).reduce(0, +) / Double(accepted.count)
        let movementDuration = accepted.first.flatMap { first in accepted.last.map { $0.end - first.start } }
        let detectorSetID = runningGeneric ? snapshot.generic?.events.first?.setID : await profileEngine.descriptor?.setID
        var completed = WorkoutSetResult(
            id: detectorSetID ?? UUID(), prescription: frozenPrescription, reps: reps,
            averageRepDuration: averageDuration, movementDuration: movementDuration,
            interrupted: state == .interrupted, finishedAt: Date(),
            slowdownPercent: coaching.slowdownPercent, coaching: coaching)
        completed.nextSetPlan = loadPrediction().map { WorkoutCoach.nextSetPlan(from: $0) }
            ?? WorkoutCoach.nextSetPlan(for: completed)
        completedSetResults.append(completed)
        latestSetResult = completed
        betweenSetStartedAt = ProcessInfo.processInfo.systemUptime
        resultBeforePreparation = nil
        restStartBeforePreparation = nil
        summaryURLBeforePreparation = nil
        if state == .interrupted, error == nil {
            error = "This set was interrupted. Recorded reps are retained, but coaching is unavailable."
        }
        let bundle = runningGeneric ? await genericSession.completedBundle : await profileEngine.completedBundle
        saveSession(interrupted: state == .interrupted, recordingDirectory: bundle?.directory.path)
        if let bundle {
            do {
                let url = bundle.directory.appendingPathComponent("set-summary.json")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(completed).write(to: url, options: .atomic)
                summaryURL = url
            } catch { self.error = "Could not save workout summary: \(error.localizedDescription)" }
        } else if state == .complete {
            error = "The recording could not be saved."
        }
    }
    private func saveSession(interrupted: Bool, recordingDirectory: String?) {
        guard let session, let initialPrescription else { return }
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            let archive = WorkoutSessionArchive(schemaVersion: 1, sessionID: sessionID,
                initialPrescription: initialPrescription, policy: session.policy, inputs: session.inputs,
                sets: session.sets, interrupted: interrupted, recordingDirectory: recordingDirectory,
                setResults: completedSetResults)
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

    private func restoreAfterAbandonedSet() {
        reps = 0
        genericEventIDs = []
        genericMetrics = [:]
        profileLedger = .init()
        profileMetrics = nil
        frozenPrescription = nil
        if completedSetResults.isEmpty {
            state = .idle
            session = nil
            sessionURL = nil
            sessionStartedAtUptime = nil
            finalizedElapsedTime = nil
            initialPrescription = nil
            latestSetResult = nil
            betweenSetStartedAt = nil
            summaryURL = nil
        } else {
            state = .complete
            latestSetResult = resultBeforePreparation ?? completedSetResults.last
            betweenSetStartedAt = restStartBeforePreparation ?? ProcessInfo.processInfo.systemUptime
            summaryURL = summaryURLBeforePreparation
        }
        resultBeforePreparation = nil
        restStartBeforePreparation = nil
        summaryURLBeforePreparation = nil
    }

}

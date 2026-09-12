import Combine
import Foundation

/// Display-only series. Missing measurements and new patterns break the line.
struct RepSpeedSeries: Equatable {
    struct Point: Identifiable, Equatable {
        let id: Int
        let speed: Double?
        let epoch: Int
        let segment: Int
    }
    let points: [Point]
    let baseline: Double?
    let activeEpoch: Int
    let wholeCycle: Bool

    init(speeds: [Double?] = [], epochs: [Int] = [], activeEpoch: Int = 0,
         wholeCycle: Bool = true) {
        self.activeEpoch = activeEpoch
        self.wholeCycle = wholeCycle
        var points: [Point] = []
        var segment = 0
        for (index, value) in speeds.enumerated() {
            let speed = value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let epoch = epochs.indices.contains(index) ? epochs[index] : activeEpoch
            if let previous = points.last, previous.speed == nil || speed == nil || previous.epoch != epoch {
                segment += 1
            }
            points.append(.init(id: index + 1, speed: speed, epoch: epoch, segment: segment))
        }
        self.points = points
        let firstThree = points.filter { $0.epoch == activeEpoch }
            .compactMap(\.speed).filter { $0 >= 0.05 }.prefix(3)
        baseline = firstThree.count == 3 ? firstThree.reduce(0, +) / 3 : nil
    }

    var latestSlowdownPercent: Double? {
        guard let last = points.last, last.epoch == activeEpoch,
              let speed = last.speed, let baseline else { return nil }
        return 100 * (1 - speed / baseline)
    }
}

enum TrainingGoal: String, Codable, CaseIterable, Identifiable {
    case strength = "Strength", muscle = "Build muscle", consistency = "Consistency"
    var id: String { rawValue }
}

struct WorkoutPrescription: Codable, Equatable {
    var exercise: V2Exercise = .bicepsCurl
    var goal: TrainingGoal = .muscle
    var loadLB: Double? = nil
    var minimumReps = 8
    var maximumReps = 12
    var targetRIR = 2
    var equipmentIncrementLB = 5.0

    var isValid: Bool {
        (loadLB.map { $0.isFinite && (0...1000).contains($0) } ?? true) &&
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
        loadLB = try values.decodeIfPresent(Double.self, forKey: .loadLB)
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
    /// Average of the available per-rep mean speeds, in metres per second.
    var averageSpeedMPS: Double? = nil
    /// Maximum available instantaneous rep speed, in metres per second.
    var peakSpeedMPS: Double? = nil
    var coaching: WorkoutCoachingSnapshot? = nil
    var nextSetPlan: NextSetPlan? = nil
    var aiAdvice: AISetAdvice? = nil

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
        let profile = snapshot.metrics.map { metrics in
            SetVelocityProfile(meanLiftingSpeeds: metrics.reps.map {
                $0.status == .available ? $0.meanLiftingSpeed : nil
            })
        }
        return evaluate(velocityProfile: profile, reps: reps, prescription: prescription,
                        signalUsable: snapshot.quality == .usable && snapshot.isRecovering != true)
    }

    static func nextSetPlan(for result: WorkoutSetResult) -> NextSetPlan {
        let prescription = result.prescription
        guard let loadLB = prescription.loadLB else {
            return .init(action: .noRecommendation,
                         title: "\(prescription.minimumReps)–\(prescription.maximumReps) reps · \(prescription.targetRIR) RIR",
                         explanation: "Add weight for a next-set weight suggestion.")
        }
        let fallback = repBasedAdjustment(loadLB: loadLB, reps: result.reps,
            repRange: prescription.minimumReps...prescription.maximumReps,
            incrementLB: prescription.equipmentIncrementLB,
            interrupted: result.interrupted,
            steadyAtTop: result.coaching?.evidenceIsValid == true &&
                (result.coaching?.slowdownPercent ?? .infinity) < 12)
        let action: NextSetAction = fallback.load > loadLB ? .considerHeavierLoad :
            (fallback.load < loadLB ? .lowerLoad : .keepLoad)
        return .init(action: action,
                     title: "\(fallback.load.formatted()) lb × \(fallback.reps)",
                     explanation: fallback.explanation)
    }

    /// Bounded double progression when a calibrated capacity estimate is unavailable.
    static func repBasedAdjustment(loadLB: Double, reps: Int, repRange: ClosedRange<Int>,
                                   incrementLB: Double, interrupted: Bool = false,
                                   steadyAtTop: Bool = false)
        -> (load: Double, reps: Int, explanation: String) {
        let direction = interrupted || reps <= 0 ? 0 :
            (reps > repRange.upperBound || (reps == repRange.upperBound && steadyAtTop) ? 1 :
                (reps < repRange.lowerBound ? -1 : 0))
        let load = min(1000, max(0, loadLB + Double(direction) * incrementLB))
        let target = direction > 0 ? repRange.lowerBound :
            min(repRange.upperBound, max(repRange.lowerBound, reps))
        let reason: String
        if interrupted || reps <= 0 {
            reason = "The set was incomplete. Keep the current load and retry the rep target."
        } else if load > loadLB {
            reason = "\(reps) reps reached or exceeded your \(repRange.lowerBound)–\(repRange.upperBound) target. Try one heavier equipment step and aim for \(target) reps."
        } else if load < loadLB {
            reason = "\(reps) reps fell below your \(repRange.lowerBound)–\(repRange.upperBound) target. Try one lighter equipment step."
        } else {
            reason = "Keep this load and aim for \(target) reps within your \(repRange.lowerBound)–\(repRange.upperBound) target."
        }
        return (load, target, reason)
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
                         prescription: WorkoutPrescription,
                         rirEstimate: AutomaticRIREstimate? = nil,
                         signalUsable: Bool = true) -> WorkoutCoachingSnapshot {
        let slowdown = signalUsable ? velocityProfile?.velocityLossPercent : nil
        if reps >= prescription.maximumReps {
            return .init(state: .targetReached, slowdownPercent: slowdown,
                         explanation: "You reached the top of your rep range.",
                         evidenceIsValid: slowdown != nil)
        }
        guard signalUsable else {
            return .init(state: .unavailable, slowdownPercent: nil,
                         explanation: "Speed signal is recovering. Rep target: \(prescription.minimumReps)–\(prescription.maximumReps).",
                         evidenceIsValid: false)
        }
        guard let slowdown else {
            return .init(state: reps < 3 ? .buildingBaseline : .steady, slowdownPercent: nil,
                         explanation: "\(reps) reps completed; aim for \(prescription.minimumReps)–\(prescription.maximumReps). Waiting for consistent finalized speeds.",
                         evidenceIsValid: false)
        }
        if let estimate = rirEstimate {
            let reached = estimate.upperRIR <= prescription.targetRIR && estimate.upperRIR < 4
            let approaching = estimate.lowerRIR <= prescription.targetRIR + 1
            return .init(state: reached ? .targetReached : (approaching ? .approachingTarget : .steady),
                slowdownPercent: slowdown,
                explanation: "\(estimate.rangeDescription) RIR · target \(prescription.targetRIR). " +
                    (reached ? "Finish this set." : "\(rounded(slowdown))% speed loss."),
                evidenceIsValid: true)
        }
        return .init(state: .steady, slowdownPercent: slowdown,
                     explanation: "\(rounded(slowdown))% speed loss. Aim for \(prescription.minimumReps)–\(prescription.maximumReps) reps; slowdown alone does not establish RIR.",
                     evidenceIsValid: true)
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
    private var exerciseWeights: [V2Exercise: Double] = [:]
    @Published var prescription = WorkoutPrescription() {
        didSet {
            if prescription.exercise != oldValue.exercise {
                exerciseWeights[oldValue.exercise] = oldValue.loadLB
                prescription.loadLB = exerciseWeights[prescription.exercise]
            } else {
                exerciseWeights[prescription.exercise] = prescription.loadLB
            }
            if automaticSets, automaticWorkoutActive {
                rememberAutomaticPrescription(prescription, at: automaticSnapshot.timestamp)
            }
        }
    }
    @Published var automaticSets = false
    @Published var exerciseAutoDetect = false
    @Published private(set) var exerciseSuggestion = StableExerciseState()
    @Published private(set) var classificationError: String?
    private var classifier: ExerciseClassificationSession?
    private var acceptingClassificationUpdates = false
    private var classificationCaptureID: UUID?
    private var classificationPatternEpoch: Int?
    private var classificationWatchdog: Task<Void, Never>?
    private var exerciseAnnotations: [SetExerciseAnnotation] = []

    var classificationAvailable: Bool { countingMode == .generic && !automaticSets }
    var correctedExercise: V2Exercise? {
        if let confirmed = exerciseAnnotations.first(where: { $0.captureID == classificationCaptureID })?.confirmedLabel {
            return confirmed.exercise
        }
        guard exerciseSuggestion.manual else { return nil }
        return exerciseSuggestion.label?.exercise
    }
    var correctionChangesPrescription: Bool {
        correctedExercise.map { $0 != activePrescription.exercise } ?? false
    }
    private func beginClassification() async {
        await freezeClassification()
        exerciseSuggestion = .init(); classificationError = nil; classificationPatternEpoch = nil
        guard exerciseAutoDetect, classificationAvailable else { return }
        let id = UUID(); classificationCaptureID = id
        acceptingClassificationUpdates = true
        exerciseSuggestion.status = .warmingUp
        exerciseAnnotations.append(.init(captureID: id, state: exerciseSuggestion))
        do {
            classifier = try ExerciseClassificationSession(captureID: id, directory: sessionDirectory,
                now: ProcessInfo.processInfo.systemUptime) { [weak self] update in
                    await self?.receiveClassification(update)
                }
            classificationWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    await self.classifier?.tick(now: ProcessInfo.processInfo.systemUptime)
                }
            }
        } catch {
            classificationError = "Exercise suggestions unavailable: \(error.localizedDescription)"
            exerciseSuggestion.status = .unavailable
        }
    }
    private func receiveClassification(_ update: ExerciseClassificationSession.Update) {
        guard acceptingClassificationUpdates, classificationCaptureID == update.captureID else { return }
        exerciseSuggestion = update.state
        classificationError = update.loggingError
        if let index = exerciseAnnotations.firstIndex(where: { $0.captureID == update.captureID }) {
            exerciseAnnotations[index].state = update.state
            if !update.state.manual { exerciseAnnotations[index].predictedLabel = update.state.label }
        }
    }
    private func freezeClassification(interrupted: Bool = false) async {
        acceptingClassificationUpdates = false
        classificationWatchdog?.cancel(); classificationWatchdog = nil
        if let classifier {
            exerciseSuggestion = await classifier.finish(now: ProcessInfo.processInfo.systemUptime, interrupted: interrupted)
            if let index = exerciseAnnotations.firstIndex(where: { $0.captureID == classificationCaptureID }) {
                exerciseAnnotations[index].state = exerciseSuggestion
                if !exerciseSuggestion.manual { exerciseAnnotations[index].predictedLabel = exerciseSuggestion.label }
            }
        }
        classifier = nil
    }
    func confirmExerciseSuggestion(_ label: ExerciseLabel) async {
        guard classificationCaptureID != nil else { return }
        invalidateLatestAIAdvice()
        let now = ProcessInfo.processInfo.systemUptime
        await classifier?.confirm(label, now: now)
        exerciseSuggestion.label = label; exerciseSuggestion.manual = true
        exerciseSuggestion.status = .recognized; exerciseSuggestion.reason = "manualOverride"
        if let index = exerciseAnnotations.firstIndex(where: { $0.captureID == classificationCaptureID }) {
            exerciseAnnotations[index].confirmedLabel = label
            exerciseAnnotations[index].correctionTime = now
            exerciseAnnotations[index].state = exerciseSuggestion
        }
        if correctionChangesPrescription {
            liveRIR = nil
            coaching = .init(state: .unavailable, slowdownPercent: nil,
                explanation: "Exercise corrected. Previous exercise-specific advice is unavailable.", evidenceIsValid: false)
        }
        saveSession(interrupted: state == .interrupted, recordingDirectory: latestRecordingDirectory?.path)
    }
    func reviewedExercise(for draft: SetReviewDraft) -> V2Exercise {
        exerciseAnnotations.first(where: { $0.setID == draft.id })?.confirmedLabel?.exercise ?? draft.exercise
    }
    func reviewedDraft(_ draft: SetReviewDraft) -> SetReviewDraft {
        var value = draft; value.exercise = reviewedExercise(for: draft)
        if value.exercise != draft.exercise { value.automaticRIR = nil }
        return value
    }
    @Published var countingMode: RepCountingMode = .generic
    @Published private(set) var state: V2SetState = .idle
    @Published private(set) var reps = 0
    @Published private(set) var learningMovement = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var result: WorkoutSetResult?
    @Published private(set) var latestSetResult: WorkoutSetResult?
    @Published private(set) var completedSetResults: [WorkoutSetResult] = []
    @Published private(set) var coaching = WorkoutCoachingSnapshot(
        state: .buildingBaseline, slowdownPercent: nil,
        explanation: "Complete three smooth reps to establish your baseline.", evidenceIsValid: false)
    @Published private(set) var liveRepSpeedMPS: Double?
    @Published private(set) var repSpeedSeries = RepSpeedSeries()
    @Published private(set) var liveSpeedDegradationPercent: Double?
    @Published private(set) var liveRIR: AutomaticRIREstimate?
    @Published private(set) var summaryURL: URL?
    @Published private(set) var latestRecordingDirectory: URL?

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
    private var cachedRIRProfile: SetVelocityProfile?
    private var cachedRIRHistoryCount = -1
    private var cachedRIRPrescription: WorkoutPrescription?
    private var firstSourceTime: Double?
    private var latestSourceTime: Double?
    private var startedAtUptime: Double = 0
    private var sessionStartedAtUptime: Double?
    private var finalizedElapsedTime: Double?
    private var lastReceipt: Double?
    @Published private(set) var aiLoading = false
    @Published private(set) var aiError: String?
    private let analyzeAI: @MainActor (AISetRequest, String, String) async throws -> AISetAdvice
    private var aiInput: AISetRequest?
    private var aiInputSetID: UUID?
    private var automaticAIInputs: [UUID: AISetRequest] = [:]
    private var aiAdviceBySet: [UUID: AISetAdvice] = [:]
    private var aiExerciseBySet: [UUID: V2Exercise] = [:]
    var latestAIExercise: V2Exercise? {
        latestSetResult.flatMap { aiExerciseBySet[$0.id] } ?? latestSetResult?.prescription.exercise
    }
    var canAnalyzeLatestSet: Bool {
        !isRunning && !aiLoading && !automaticRecoveryProvisional &&
        latestSetResult.map { !$0.interrupted && $0.reps > 0 && $0.id == aiInputSetID } == true
    }
    private func invalidateLatestAIAdvice() {
        aiRequestID = UUID(); aiLoading = false; aiError = nil
        if let id = latestSetResult?.id {
            aiAdviceBySet[id] = nil; aiExerciseBySet[id] = nil
            latestSetResult?.aiAdvice = nil
            if let index = completedSetResults.firstIndex(where: { $0.id == id }) { completedSetResults[index].aiAdvice = nil }
        }
    }
    private var aiRequestID = UUID()
    private var finishing = false
    private var betweenSetStartedAt: Double?
    private var resultBeforePreparation: WorkoutSetResult?
    private var restStartBeforePreparation: Double?
    private var summaryURLBeforePreparation: URL?
    private weak var automaticCapture: CaptureModel?
    private var automaticSnapshotSubscription: AnyCancellable?
    private var automaticSnapshot = AutoWorkoutSnapshot()
    @Published private(set) var automaticStatus = "Ready — begin when ready"
    @Published private(set) var automaticState: AutoWorkoutState = .idle
    @Published private(set) var automaticRecoveryProvisional = false
    private var automaticSetPrescriptions: [String: WorkoutPrescription] = [:]
    private var automaticPrescriptionTimeline: [(time: Double, value: WorkoutPrescription)] = []
    private var automaticResultIDs: [String: UUID] = [:]
    private var automaticReviewedSetIDs: Set<String> = []
    private var automaticPostSetID: String?
    private var automaticPostSetCycleCount = 0

    init(sessionDirectory: URL? = nil, historyFileURL: URL? = nil,
         makeProfileRecorder: @escaping () -> any V2RecordingSink = { V2SessionRecorder() },
         analyzeAI: @escaping @MainActor (AISetRequest, String, String) async throws -> AISetAdvice = {
             try await AIWorkoutCoach().analyze($0, model: $1, apiKey: $2)
         }) {
        self.sessionDirectory = sessionDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Workouts")
        self.analyzeAI = analyzeAI
        self.makeProfileRecorder = makeProfileRecorder
        history = WorkoutHistoryStore(fileURL: historyFileURL)
    }

    var completedSets: [SessionSet] { session?.sets ?? [] }
    var automaticWorkoutActive: Bool {
        automaticState != .idle && automaticState != .finished
    }
    var ownsMotionCapture: Bool { !automaticSets && isRunning }
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
        if correctionChangesPrescription { return nil }
        guard session?.current == nil, let sourceSetID = completedSets.last?.id else { return nil }
        if let confirmed = history.sets.first(where: {
            $0.sessionID == sessionID && $0.sourceSetID == sourceSetID
        }) {
            return history.restRecommendation(after: confirmed)
        }
        guard let draft = pendingSetReviews.first(where: { $0.id == sourceSetID }) else { return nil }
        return RestRecommendation(reps: draft.detectedReps,
                                  repsInReserve: draft.automaticRIR?.repsInReserve,
                                  velocityLossPercent: draft.velocityProfile?.velocityLossPercent)
    }

    var latestSetRIRDescription: String? {
        if correctionChangesPrescription { return nil }
        guard session?.current == nil, let sourceSetID = completedSets.last?.id else { return nil }
        if let confirmed = history.sets.first(where: {
            $0.sessionID == sessionID && $0.sourceSetID == sourceSetID
        }), let rir = confirmed.repsInReserve {
            return String(rir)
        }
        guard let estimate = pendingSetReviews.first(where: { $0.id == sourceSetID })?.automaticRIR else {
            guard automaticSets, let liveRIR else { return nil }
            return liveRIR.cappedAtFourPlus ? "4+" : String(liveRIR.repsInReserve)
        }
        return estimate.cappedAtFourPlus ? "4+" : String(estimate.repsInReserve)
    }

    var liveRIRDescription: String? {
        if correctionChangesPrescription { return nil }
        guard let liveRIR else { return nil }
        return liveRIR.cappedAtFourPlus ? "4+" : String(liveRIR.repsInReserve)
    }

    func updateNextSet() {
        guard prescription.isValid, supportedExercise else { error = "Choose an available exercise and valid target."; return }
        guard !automaticWorkoutActive else { return }
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

    var latestLoggedSet: LoggedWorkoutSet? {
        guard let latest = completedSets.last else { return nil }
        return history.sets.first { $0.sessionID == sessionID && $0.sourceSetID == latest.id }
    }

    func updateCompletedWeight(_ set: LoggedWorkoutSet, loadLB: Double?) {
        if history.updateWeight(for: set.id, loadLB: loadLB) { error = nil }
        else { error = history.error ?? "Could not update weight." }
    }

    @discardableResult
    func confirmSet(_ draft: SetReviewDraft, loadLB: Double?, reps: Int, repsInReserve: Int?, exercise: V2Exercise? = nil) -> Bool {
        var reviewed = reviewedDraft(draft)
        reviewed.exercise = exercise ?? reviewed.exercise
        if reviewed.exercise != draft.exercise { reviewed.automaticRIR = nil }
        guard history.confirm(reviewed, loadLB: loadLB, reps: reps,
                              repsInReserve: repsInReserve) else {
            error = history.error
            return false
        }
        if completedSets.last?.id == draft.id && draft.sessionID == sessionID {
            invalidateLatestAIAdvice()
        }
        pendingSetReviews.removeAll { $0.sessionID == draft.sessionID && $0.id == draft.id }
        if let index = exerciseAnnotations.firstIndex(where: { $0.setID == draft.id }) {
            exerciseAnnotations[index].confirmedLabel = ExerciseLabel.allCases.first { $0.exercise == reviewed.exercise }
            exerciseAnnotations[index].correctionTime = ProcessInfo.processInfo.systemUptime
            saveSession(interrupted: state == .interrupted, recordingDirectory: latestRecordingDirectory?.path)
        }
        error = nil
        return true
    }

    func loadPrediction() -> LoadPrediction? {
        if correctionChangesPrescription { return nil }
        if latestSetResult?.interrupted == true || prescription.loadLB == nil { return nil }
        let draft = completedSets.last.flatMap { latest in
            pendingSetReviews.first { $0.id == latest.id && $0.exercise == prescription.exercise }
        }
        let source = draft.map {
            LoggedWorkoutSet(id: UUID(), sessionID: $0.sessionID, sourceSetID: $0.id,
                exercise: $0.exercise, loadLB: $0.loadLB, reps: $0.detectedReps,
                repsInReserve: $0.automaticRIR?.repsInReserve,
                averageRepDuration: $0.averageRepDuration, performedAt: $0.endedAt,
                velocityProfile: $0.velocityProfile,
                rirValueSource: $0.automaticRIR == nil ? nil : .automaticVelocity,
                precedingSetID: $0.precedingSetID, precedingRestSeconds: $0.precedingRestSeconds)
        }
        return history.nextSetRecommendation(for: prescription.exercise,
            repRange: prescription.minimumReps...prescription.maximumReps,
            targetRIR: prescription.targetRIR,
            incrementLB: prescription.equipmentIncrementLB, latestSource: source)
    }

    func use(_ prediction: LoadPrediction) {
        guard !isRunning, session?.current == nil else { return }
        applyNextSet(loadLB: prediction.loadLB, reps: prediction.targetReps, rir: prediction.targetRIR)
    }

    var isRunning: Bool { [.preparing, .active, .finalizing].contains(state) || busy }
    var workoutStarted: Bool { session != nil && result == nil }
    var betweenSets: Bool { workoutStarted && !isRunning && latestSetResult != nil }
    var activePrescription: WorkoutPrescription { session?.current?.prescription ?? session?.prescription ?? frozenPrescription ?? prescription }
    var selectedProfile: V2DSPProfile? {
        switch prescription.exercise {
        case .bicepsCurl: .adaptiveCurlV6
        case .lateralRaise: .lateralRaiseV6
        case .rdl, .gobletSquat, .chestPress, .overheadPress, .externalRotation,
             .skullCrusher, .overheadTricepsExtension, .lunge, .bentOverRows: nil
        }
    }
    var supportedExercise: Bool { automaticSets || countingMode == .generic || selectedProfile != nil }

    func signalReady(_ capture: CaptureModel, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        capture.liveSensor(now: now) == .rightHeadphone
    }

    func canStart(_ capture: CaptureModel) -> Bool {
        !automaticSets && !isRunning && prescription.isValid && supportedExercise &&
        !capture.recordingActive && !capture.automaticTrackingActive &&
        !capture.manualAnalysisActive && signalReady(capture)
    }

    func bindAutoWorkout(_ capture: CaptureModel) {
        automaticCapture = capture
        automaticSnapshotSubscription = capture.autoWorkout.$snapshot.dropFirst().sink { [weak self] snapshot in
            self?.synchronizeAutomatic(snapshot: snapshot)
        }
        if capture.automaticTrackingActive {
            synchronizeAutomatic(snapshot: capture.autoWorkout.snapshot)
        }
    }

    func startAutomaticWorkout(_ capture: CaptureModel) async {
        guard prescription.isValid, !isRunning,
              !capture.recordingActive, !capture.manualAnalysisActive,
              !capture.automaticTrackingActive else { return }
        automaticSets = true
        await freezeClassification()
        classificationCaptureID = nil; exerciseSuggestion = .init(); classificationError = nil
        aiRequestID = UUID(); aiLoading = false; aiError = nil; aiInput = nil; aiInputSetID = nil
        automaticAIInputs = [:]; aiAdviceBySet = [:]; aiExerciseBySet = [:]
        bindAutoWorkout(capture)
        prepareAutomaticProjection()
        await capture.startAutoWorkout(side: .right)
        synchronizeAutomatic(snapshot: capture.autoWorkout.snapshot)
    }

    func finishAutomaticWorkout() async {
        guard let automaticCapture, automaticWorkoutActive else { return }
        await automaticCapture.finishAutoWorkout()
        synchronizeAutomatic(snapshot: automaticCapture.autoWorkout.snapshot)
    }

    func pauseAutomaticTracking() async {
        guard let automaticCapture, automaticWorkoutActive else { return }
        await automaticCapture.pauseAutoWorkout()
        synchronizeAutomatic(snapshot: automaticCapture.autoWorkout.snapshot)
    }

    func resumeAutomaticTracking() async {
        guard let automaticCapture, automaticWorkoutActive else { return }
        await automaticCapture.resumeAutoWorkout()
        synchronizeAutomatic(snapshot: automaticCapture.autoWorkout.snapshot)
    }

    /// Applies the coordinator's published truth to the existing workout UI.
    /// Tests may call this directly without constructing a motion provider.
    func synchronizeAutomatic(snapshot: AutoWorkoutSnapshot, now: Date = Date()) {
        guard automaticSets else { return }
        if session == nil || session?.policy.version != "automatic-schema9-projection" {
            prepareAutomaticProjection()
        }
        automaticSnapshot = snapshot
        automaticState = snapshot.state
        automaticStatus = snapshot.status
        if let export = automaticCapture?.autoWorkout.exportURLs.first {
            latestRecordingDirectory = export.deletingLastPathComponent()
            summaryURL = automaticCapture?.autoWorkout.exportURLs.first {
                $0.lastPathComponent == "summary.json"
            }
        }
        latestSourceTime = snapshot.timestamp
        if firstSourceTime == nil {
            firstSourceTime = snapshot.cycles.map(\.start).min() ?? snapshot.timestamp
        }

        for record in snapshot.sets where record.status != .discarded &&
            automaticSetPrescriptions[record.id] == nil {
            automaticSetPrescriptions[record.id] = automaticPrescription(at: record.start)
        }
        let eligibleRecords = snapshot.sets.filter { $0.status != .discarded }
        let lastRecord = eligibleRecords.last
        if let record = lastRecord, snapshot.restStartedAt != nil,
           record.status != .sealed {
            automaticPostSetID = record.id
            automaticPostSetCycleCount = record.cycleIDs.count
        }
        var liveSetID: String?
        if snapshot.state == .running, snapshot.restStartedAt == nil,
           snapshot.candidateCount == 0, let record = lastRecord, record.status == .open {
            if let postSetID = automaticPostSetID {
                if record.id != postSetID || record.cycleIDs.count > automaticPostSetCycleCount {
                    automaticPostSetID = nil
                    liveSetID = record.id
                }
            } else {
                liveSetID = record.id
            }
        }
        session?.projectAutomatic(snapshot, prescriptions: automaticSetPrescriptions,
                                  liveSetID: liveSetID)

        let recordByID = Dictionary(uniqueKeysWithValues: snapshot.sets.map { ($0.id, $0) })
        let metrics = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.id, $0) })
        let projectedSets = (session?.sets ?? []) + (session?.current.map { [$0] } ?? [])
        let liveID = session?.current?.id
        let completed = projectedSets.filter { $0.id != liveID }.compactMap { set -> WorkoutSetResult? in
            guard let record = recordByID[set.id] else { return nil }
            return automaticResult(for: set, record: record, snapshot: snapshot,
                                   metrics: metrics, now: now)
        }
        completedSetResults = completed
        latestSetResult = completed.last
        let nextAIID = latestSetResult?.id
        if aiInputSetID != nextAIID {
            aiRequestID = UUID(); aiLoading = false; aiError = nil
        }
        aiInputSetID = nextAIID
        aiInput = nextAIID.flatMap { automaticAIInputs[$0] }

        if let live = session?.current, let record = recordByID[live.id] {
            applyAutomaticLive(set: live, record: record, snapshot: snapshot, metrics: metrics)
            betweenSetStartedAt = nil
        } else {
            reps = latestSetResult?.reps ?? 0
            learningMovement = snapshot.candidateCount > 0
            let displayedRecord = completed.last.flatMap { result in
                snapshot.sets.first { automaticResultIDs[$0.id] == result.id }
            }
            automaticRecoveryProvisional = latestSetResult != nil && displayedRecord?.status != .sealed
            if latestSetResult != nil {
                state = .complete
                if snapshot.restStartedAt != nil {
                    betweenSetStartedAt = ProcessInfo.processInfo.systemUptime - (snapshot.elapsedRest ?? 0)
                } else if betweenSetStartedAt == nil {
                    betweenSetStartedAt = ProcessInfo.processInfo.systemUptime
                }
            } else {
                state = snapshot.candidateCount > 0 ? .preparing : .idle
                betweenSetStartedAt = nil
            }
            updateAutomaticSummaryMetrics(for: projectedSets.last, record: displayedRecord,
                                          snapshot: snapshot, metrics: metrics)
        }

        enqueueSealedAutomaticReviews(snapshot: snapshot)
        if snapshot.state == .finished {
            finalizedElapsedTime = elapsedTime
            let allReps = completedSets.flatMap(\.reps)
            let average = allReps.isEmpty ? nil : allReps.map(\.duration).reduce(0, +) / Double(allReps.count)
            let movement = allReps.first.flatMap { first in allReps.last.map { $0.end - first.start } }
            result = WorkoutSetResult(id: sessionID, prescription: initialPrescription ?? prescription,
                reps: completedSetResults.map(\.reps).reduce(0, +), averageRepDuration: average,
                movementDuration: movement, interrupted: false, finishedAt: now)
            state = .complete
            automaticRecoveryProvisional = false
        }
    }

    func startSet(_ capture: CaptureModel) async {
        guard canStart(capture) else { return }
        aiRequestID = UUID(); aiLoading = false; aiError = nil
        busy = true
        defer { busy = false }
        resultBeforePreparation = latestSetResult
        restStartBeforePreparation = betweenSetStartedAt
        summaryURLBeforePreparation = summaryURL
        error = nil; result = nil; summaryURL = nil; latestSetResult = nil
        genericEventIDs = []; genericMetrics = [:]; profileLedger = .init(); profileMetrics = nil
        reps = 0; lastReceipt = nil; betweenSetStartedAt = nil
        repSpeedSeries = RepSpeedSeries()
        liveRepSpeedMPS = nil; liveSpeedDegradationPercent = nil
        liveRIR = nil; cachedRIRProfile = nil; cachedRIRPrescription = nil
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
        await beginClassification()
        do {
            if countingMode == .generic {
                try await genericSession.start(side: .right, metricsEnabled: true,
                                               directory: sessionDirectory)
                runningGeneric = true
            } else if let selectedProfile {
                try await profileEngine.start(profile: selectedProfile,
                    recorder: makeProfileRecorder(), motionActive: capture.motionUpdatesActive,
                    sideVerified: true, noOtherRecording: !capture.recordingActive,
                    setupConfirmed: true, metricsConfiguration: .cyclicDevicePath3D)
                runningGeneric = false
            } else {
                throw V2Error.invalidLifecycle("No bundled profile is available for this exercise. Use Generic movement.")
            }
            await refresh()
        } catch {
            self.error = error.localizedDescription
            await freezeClassification(interrupted: true)
            restoreAfterAbandonedSet()
        }
    }

    func start(_ capture: CaptureModel) async { await startSet(capture) }

    func ingest(_ sample: RawMotionSample) async {
        guard !automaticSets, workoutStarted else { return }
        firstSourceTime = firstSourceTime ?? sample.sourceTimestamp
        latestSourceTime = sample.sourceTimestamp
        guard [.preparing, .active, .finalizing].contains(state) else { return }
        lastReceipt = sample.receiptUptime
        if runningGeneric {
            do { try await genericSession.apply(.init(kind: .sample, raw: RawMotionEvent(sample))) }
            catch { self.error = error.localizedDescription }
            if state != .finalizing { await classifier?.ingest(sample) }
        } else {
            await profileEngine.ingest(sample)
        }
        await refresh()
    }

    func endSet() async {
        guard state == .active, !busy, let latestSourceTime else { return }
        busy = true
        defer { busy = false }
        await freezeClassification()
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
        guard !automaticSets, workoutStarted, !isRunning else { return }
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
        await freezeClassification()
        if runningGeneric {
            try? await genericSession.apply(.init(kind: .interrupt, interruption: .explicitCancellation))
        } else {
            await profileEngine.cancel()
        }
        restoreAfterAbandonedSet()
    }

    func motionUnavailable() async {
        guard !automaticSets else { return }
        await freezeClassification(interrupted: true)
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
        guard !automaticSets else { return }
        guard [.preparing, .active, .finalizing].contains(state),
              now - (lastReceipt ?? startedAtUptime) > 0.5 else { return }
        error = "Motion stopped arriving. Reconnect the AirPod and start a new set."
        await motionUnavailable()
    }

    func reset() {
        guard !isRunning, !automaticWorkoutActive else { return }
        classificationWatchdog?.cancel(); classificationWatchdog = nil
        let oldClassifier = classifier
        Task { await oldClassifier?.finish(now: ProcessInfo.processInfo.systemUptime) }
        classifier = nil; classificationCaptureID = nil; exerciseSuggestion = .init(); exerciseAnnotations = []
        repSpeedSeries = RepSpeedSeries()
        aiRequestID = UUID(); aiLoading = false; aiError = nil; aiInput = nil
        aiInputSetID = nil; automaticAIInputs = [:]; aiAdviceBySet = [:]; aiExerciseBySet = [:]
        liveRepSpeedMPS = nil; liveSpeedDegradationPercent = nil
        liveRIR = nil; cachedRIRProfile = nil; cachedRIRPrescription = nil
        state = .idle; result = nil; latestSetResult = nil; summaryURL = nil; error = nil
        reps = 0; learningMovement = false; session = nil; sessionURL = nil; completedSetResults = []; initialPrescription = nil
        frozenPrescription = nil; betweenSetStartedAt = nil; sessionStartedAtUptime = nil
        finalizedElapsedTime = nil
        automaticSnapshot = .init()
        automaticState = .idle
        automaticStatus = "Ready — begin when ready"
        automaticRecoveryProvisional = false
        automaticSetPrescriptions = [:]
        automaticPrescriptionTimeline = []
        automaticResultIDs = [:]
        automaticReviewedSetIDs = []
        automaticPostSetID = nil
        automaticPostSetCycleCount = 0
    }

    private func prepareAutomaticProjection() {
        sessionID = UUID()
        initialPrescription = prescription
        session = WorkoutSessionReducer(
            prescription: prescription,
            policy: WorkoutPolicy(version: "automatic-schema9-projection", inactivitySeconds: 10)
        )
        sessionStartedAtUptime = ProcessInfo.processInfo.systemUptime
        finalizedElapsedTime = nil
        result = nil
        latestSetResult = nil
        completedSetResults = []
        summaryURL = nil
        sessionURL = nil
        reps = 0
        state = .preparing
        betweenSetStartedAt = nil
        firstSourceTime = nil
        latestSourceTime = nil
        automaticSetPrescriptions = [:]
        automaticPrescriptionTimeline = [(-Double.infinity, prescription)]
        automaticResultIDs = [:]
        automaticReviewedSetIDs = []
        automaticPostSetID = nil
        automaticPostSetCycleCount = 0
        automaticRecoveryProvisional = false
    }

    private func rememberAutomaticPrescription(_ value: WorkoutPrescription, at time: Double?) {
        guard value.isValid else { return }
        let timestamp = time ?? automaticPrescriptionTimeline.last?.time ?? -Double.infinity
        if let last = automaticPrescriptionTimeline.last, last.time == timestamp {
            automaticPrescriptionTimeline[automaticPrescriptionTimeline.count - 1] = (timestamp, value)
        } else {
            automaticPrescriptionTimeline.append((timestamp, value))
        }
    }

    private func automaticPrescription(at time: Double) -> WorkoutPrescription {
        automaticPrescriptionTimeline.last(where: { $0.time <= time + 1e-9 })?.value
            ?? initialPrescription ?? prescription
    }

    private func automaticVelocityProfile(
        set: SessionSet,
        record: AutoSetRecord,
        snapshot: AutoWorkoutSnapshot
    ) -> SetVelocityProfile? {
        guard record.baselineMeanSpeed != nil else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.cycles.map { ($0.id, $0) })
        let evidence = record.cycleIDs.compactMap { byID[$0] }
        guard evidence.count == record.cycleIDs.count, let first = evidence.first,
              evidence.allSatisfy({
                  $0.sourceEpoch == first.sourceEpoch && $0.learningEpoch == first.learningEpoch &&
                  $0.templateHash == first.templateHash
              }) else { return nil }
        return SetVelocityProfile(set: set, genericMetrics: snapshot.metrics)
    }

    private func automaticResult(
        for set: SessionSet,
        record: AutoSetRecord,
        snapshot: AutoWorkoutSnapshot,
        metrics: [String: GenericCycleMetrics],
        now: Date
    ) -> WorkoutSetResult {
        let id = automaticResultIDs[set.id] ?? UUID()
        automaticResultIDs[set.id] = id
        let age = snapshot.timestamp.map { max(0, $0 - record.end) } ?? 0
        let date = now.addingTimeInterval(-age)
        let profile = automaticVelocityProfile(set: set, record: record, snapshot: snapshot)
        let automaticRIR = profile.flatMap {
            history.automaticRIR(for: set.prescription.exercise, completedReps: record.count,
                                 velocityProfile: $0, loadLB: set.prescription.loadLB)
        }
        let coach = WorkoutCoach.evaluate(velocityProfile: profile, reps: record.count,
            prescription: set.prescription, rirEstimate: automaticRIR,
            signalUsable: profile != nil)
        let setMetrics = record.cycleIDs.compactMap { metrics[$0] }.filter { $0.status == .available }
        let means = setMetrics.compactMap(\.meanSpeed).filter { $0.isFinite && $0 > 0 }
        let peaks = setMetrics.compactMap(\.peakSpeed).filter { $0.isFinite && $0 > 0 }
        var value = WorkoutSetResult(id: id, prescription: set.prescription, reps: record.count,
            averageRepDuration: set.averageDuration,
            movementDuration: max(0, set.end - set.start), interrupted: false,
            finishedAt: date, slowdownPercent: coach.slowdownPercent,
            averageSpeedMPS: means.isEmpty ? nil : means.reduce(0, +) / Double(means.count),
            peakSpeedMPS: peaks.max(), coaching: coach)
        value.nextSetPlan = WorkoutCoach.nextSetPlan(for: value)
        if record.status == .sealed {
            automaticAIInputs[id] = AISetRequest(prescription: set.prescription,
                reps: set.reps.map { AIRepSummary(rep: $0, generic: metrics[$0.id]) },
                speedDegradationPercent: profile?.velocityLossPercent,
                speedMeasurement: "whole-rep 3D device speed", signalUsable: profile != nil,
                interrupted: false)
            value.aiAdvice = aiAdviceBySet[id]
        }
        return value
    }

    private func applyAutomaticLive(
        set: SessionSet,
        record: AutoSetRecord,
        snapshot: AutoWorkoutSnapshot,
        metrics: [String: GenericCycleMetrics]
    ) {
        if aiLoading { aiRequestID = UUID(); aiLoading = false }
        reps = record.count
        learningMovement = false
        state = .active
        automaticRecoveryProvisional = false
        updateAutomaticSummaryMetrics(for: set, record: record, snapshot: snapshot, metrics: metrics)
    }

    private func updateAutomaticSummaryMetrics(
        for set: SessionSet?,
        record: AutoSetRecord?,
        snapshot: AutoWorkoutSnapshot,
        metrics: [String: GenericCycleMetrics]
    ) {
        guard let set, let record else {
            repSpeedSeries = RepSpeedSeries()
            liveRepSpeedMPS = nil
            liveSpeedDegradationPercent = nil
            liveRIR = nil
            coaching = WorkoutCoach.evaluate(velocityProfile: nil, reps: reps,
                                               prescription: activePrescription,
                                               signalUsable: false)
            return
        }
        let speeds: [Double?] = record.cycleIDs.map { id in
            guard let metric = metrics[id], metric.status == .available else { return nil }
            return metric.meanSpeed
        }
        let epochs = record.cycleIDs.map { metrics[$0]?.learningEpoch ?? 0 }
        let activeEpoch = epochs.last ?? 0
        repSpeedSeries = RepSpeedSeries(speeds: speeds, epochs: epochs,
                                        activeEpoch: activeEpoch, wholeCycle: true)
        liveRepSpeedMPS = speeds.compactMap { $0 }.last
        let profile = automaticVelocityProfile(set: set, record: record, snapshot: snapshot)
        liveSpeedDegradationPercent = profile?.velocityLossPercent
        liveRIR = profile.flatMap {
            history.automaticRIR(for: set.prescription.exercise, completedReps: record.count,
                                 velocityProfile: $0, loadLB: set.prescription.loadLB)
        }
        coaching = WorkoutCoach.evaluate(velocityProfile: profile, reps: record.count,
            prescription: set.prescription, rirEstimate: liveRIR, signalUsable: profile != nil)
    }

    private func enqueueSealedAutomaticReviews(snapshot: AutoWorkoutSnapshot) {
        guard let session else { return }
        let records = Dictionary(uniqueKeysWithValues: snapshot.sets.map { ($0.id, $0) })
        for (index, set) in session.sets.enumerated() {
            guard records[set.id]?.status == .sealed,
                  !automaticReviewedSetIDs.contains(set.id) else { continue }
            automaticReviewedSetIDs.insert(set.id)
            guard !pendingSetReviews.contains(where: { $0.sessionID == sessionID && $0.id == set.id }),
                  !history.contains(sessionID: sessionID, sourceSetID: set.id),
                  let record = records[set.id] else { continue }
            let profile = automaticVelocityProfile(set: set, record: record, snapshot: snapshot)
            let estimate = profile.flatMap {
                history.automaticRIR(for: set.prescription.exercise, completedReps: record.count,
                                     velocityProfile: $0, loadLB: set.prescription.loadLB)
            }
            let preceding = index > 0 ? session.sets[index - 1] : nil
            pendingSetReviews.append(SetReviewDraft(sessionID: sessionID, set: set,
                detectedReps: record.count,
                velocityProfile: profile, automaticRIR: estimate,
                precedingSetID: preceding?.id,
                precedingRestSeconds: preceding.map { max(0, set.start - $0.end) }))
        }
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
        learningMovement = runningGeneric && snapshot.setState == .active && snapshot.generic?.templateHash == nil
        let currentPrescription = frozenPrescription ?? prescription
        let velocity = session?.current.flatMap {
            runningGeneric ? SetVelocityProfile(set: $0, genericMetrics: Array(genericMetrics.values)) :
                SetVelocityProfile(set: $0, metrics: profileMetrics)
        }
        liveRepSpeedMPS = latestFinalizedRepSpeed()
        let currentReps = session?.current?.reps ?? []
        let activeEpoch = snapshot.generic?.learningEpoch ?? 0
        if let prior = classificationPatternEpoch, prior != activeEpoch {
            await classifier?.patternChanged(now: ProcessInfo.processInfo.systemUptime)
        }
        classificationPatternEpoch = activeEpoch
        if let index = exerciseAnnotations.firstIndex(where: { $0.captureID == classificationCaptureID }),
           let setID = session?.current?.id {
            exerciseAnnotations[index].setID = setID
        }
        let chartSpeeds: [Double?] = currentReps.map { rep in
            if runningGeneric {
                let metric = genericMetrics[rep.id]
                return metric?.status == .available ? metric?.meanSpeed : nil
            }
            return profileMetrics?.reps.first(where: { $0.id == rep.id && $0.status == .available })?.meanLiftingSpeed
        }
        let chartEpochs = currentReps.map { runningGeneric ? (genericMetrics[$0.id]?.learningEpoch ?? activeEpoch) : 0 }
        let series = RepSpeedSeries(speeds: chartSpeeds, epochs: chartEpochs,
                                   activeEpoch: activeEpoch, wholeCycle: runningGeneric)
        if repSpeedSeries != series { repSpeedSeries = series }
        liveSpeedDegradationPercent = velocity?.velocityLossPercent
        let signalUsable = snapshot.quality == .usable && snapshot.isRecovering != true
        if velocity != cachedRIRProfile || cachedRIRHistoryCount != history.sets.count ||
            cachedRIRPrescription != currentPrescription {
            liveRIR = velocity.flatMap {
                history.automaticRIR(for: currentPrescription.exercise, completedReps: reps,
                    velocityProfile: $0, loadLB: currentPrescription.loadLB)
            }
            cachedRIRProfile = velocity
            cachedRIRHistoryCount = history.sets.count
            cachedRIRPrescription = currentPrescription
        }
        coaching = WorkoutCoach.evaluate(velocityProfile: velocity, reps: reps,
            prescription: currentPrescription, rirEstimate: signalUsable ? liveRIR : nil,
            signalUsable: signalUsable)
        state = snapshot.setState
        if correctionChangesPrescription {
            liveRIR = nil
            coaching = .init(state: .unavailable, slowdownPercent: nil,
                explanation: "Exercise corrected. Previous exercise-specific advice is unavailable.", evidenceIsValid: false)
        }
        if state == .interrupted {
            coaching = .init(state: .unavailable, slowdownPercent: nil,
                             explanation: "The set ended before coaching evidence could be finalized.",
                             evidenceIsValid: false)
        }
        guard [.complete, .interrupted].contains(state), latestSetResult == nil, !finishing,
              let frozenPrescription else { return }
        await freezeClassification(interrupted: state == .interrupted)
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
        let acceptedIDs = Set(accepted.map(\.id))
        let availableGenericMetrics = genericMetrics.values.filter {
            acceptedIDs.contains($0.id) && $0.status == .available
        }
        let availableProfileMetrics = (profileMetrics?.reps ?? []).filter {
            acceptedIDs.contains($0.id) && $0.status == .available
        }
        let meanSpeeds: [Double?] = runningGeneric
            ? availableGenericMetrics.map(\.meanSpeed)
            : availableProfileMetrics.map(\.meanLiftingSpeed)
        let validMeanSpeeds = meanSpeeds.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        completed.averageSpeedMPS = validMeanSpeeds.isEmpty
            ? nil : validMeanSpeeds.reduce(0, +) / Double(validMeanSpeeds.count)
        let peakSpeeds: [Double?] = runningGeneric
            ? availableGenericMetrics.map(\.peakSpeed)
            : availableProfileMetrics.map(\.peakLiftingSpeed)
        completed.peakSpeedMPS = peakSpeeds.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }.max()
        completed.nextSetPlan = completed.interrupted ? WorkoutCoach.nextSetPlan(for: completed) :
            (loadPrediction().map { WorkoutCoach.nextSetPlan(from: $0) }
                ?? WorkoutCoach.nextSetPlan(for: completed))
        let profileByID = Dictionary((profileMetrics?.reps ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let repSummaries = accepted.map { rep in
            runningGeneric ? AIRepSummary(rep: rep, generic: genericMetrics[rep.id])
                           : AIRepSummary(rep: rep, profile: profileByID[rep.id])
        }
        let degradation = completed.slowdownPercent.flatMap { $0.isFinite ? ($0 * 10).rounded() / 10 : nil }
        aiInput = AISetRequest(prescription: frozenPrescription, reps: repSummaries,
            speedDegradationPercent: degradation,
            speedMeasurement: runningGeneric ? "whole-rep 3D device speed" : "lifting-phase 3D device speed",
            signalUsable: signalUsable, interrupted: completed.interrupted)
        aiInputSetID = completed.id
        if correctionChangesPrescription {
            completed.nextSetPlan = .init(action: .noRecommendation, title: "No load recommendation",
                explanation: "Exercise corrected. Review the set before using exercise-specific advice.")
        }
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
        if let bundle { latestRecordingDirectory = bundle.directory }
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
    func analyzeLatestSet(model: String, apiKey: String) async {
        guard canAnalyzeLatestSet, let set = latestSetResult, var input = aiInput,
              !set.interrupted, set.reps > 0 else { return }
        let requestID = UUID()
        aiRequestID = requestID; aiLoading = true; aiError = nil
        if let sourceID = completedSets.last?.id,
           let confirmed = history.sets.first(where: { $0.sessionID == sessionID && $0.sourceSetID == sourceID }) {
            input.prescription.exercise = confirmed.exercise
            input.confirmedReps = confirmed.reps
            input.confirmedLoadLB = confirmed.loadLB
            if confirmed.rirValueSource == .userEntered { input.confirmedRIR = confirmed.repsInReserve }
        }
        if let annotation = exerciseAnnotations.first(where: { $0.setID == completedSets.last?.id }),
           let exercise = annotation.confirmedLabel?.exercise {
            if input.prescription.exercise != exercise { input.confirmedRIR = nil }
            input.prescription.exercise = exercise
        }
        defer { if aiRequestID == requestID { aiLoading = false } }
        do {
            let advice = try await analyzeAI(input, model, apiKey)
            try Task.checkCancellation()
            guard aiRequestID == requestID, latestSetResult?.id == set.id, !isRunning,
                  !automaticRecoveryProvisional else { return }
            aiAdviceBySet[set.id] = advice
            aiExerciseBySet[set.id] = input.prescription.exercise
            latestSetResult?.aiAdvice = advice
            if let index = completedSetResults.firstIndex(where: { $0.id == set.id }) {
                completedSetResults[index].aiAdvice = advice
            }
            saveSession(interrupted: false, recordingDirectory: summaryURL?.deletingLastPathComponent().path)
            if let summaryURL, let latestSetResult {
                try JSONEncoder().encode(latestSetResult).write(to: summaryURL, options: .atomic)
            }
        } catch is CancellationError { }
        catch { if aiRequestID == requestID { aiError = error.localizedDescription } }
    }

    func useAIAdvice() {
        guard !isRunning, let set = latestSetResult, let next = set.aiAdvice?.nextSet,
              !automaticRecoveryProvisional, prescription.exercise == latestAIExercise else { return }
        applyNextSet(loadLB: next.loadLB, reps: next.reps, rir: next.targetRIR)
    }

    func isNextSetSelected(loadLB: Double, reps: Int, rir: Int) -> Bool {
        prescription.loadLB == loadLB && prescription.minimumReps == reps &&
            prescription.maximumReps == reps && prescription.targetRIR == rir
    }

    private func applyNextSet(loadLB: Double, reps: Int, rir: Int) {
        guard !isRunning, session?.current == nil else { return }
        var next = prescription
        next.loadLB = loadLB
        next.minimumReps = reps; next.maximumReps = reps
        next.targetRIR = rir
        guard next.isValid else { return }
        prescription = next
        session?.apply(.selection(next))
    }

    private func saveSession(interrupted: Bool, recordingDirectory: String?) {
        guard let session, let initialPrescription else { return }
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            let archive = WorkoutSessionArchive(exerciseAnnotations: exerciseAnnotations.isEmpty ? nil : exerciseAnnotations,
                schemaVersion: 1, sessionID: sessionID,
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
                                     velocityProfile: $0, loadLB: set.prescription.loadLB)
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
        repSpeedSeries = RepSpeedSeries()
        liveRepSpeedMPS = nil
        liveSpeedDegradationPercent = nil
        liveRIR = nil
        learningMovement = false
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

    private func latestFinalizedRepSpeed() -> Double? {
        guard let repID = session?.current?.reps.last?.id else { return nil }
        let speed: Double?
        if runningGeneric {
            let metric = genericMetrics[repID]
            speed = metric?.status == .available ? metric?.meanSpeed : nil
        } else {
            speed = profileMetrics?.reps.last(where: {
                $0.id == repID && $0.status == .available
            })?.meanLiftingSpeed
        }
        guard let speed, speed.isFinite, speed > 0 else { return nil }
        return speed
    }

}

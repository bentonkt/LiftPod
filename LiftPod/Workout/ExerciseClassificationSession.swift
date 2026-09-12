import Foundation
import CryptoKit

extension ExerciseLabel {
    var exercise: V2Exercise { V2Exercise(rawValue: title)! }
}

/// Isolated from the rep actor. Only score calculation can queue; input/filter order never changes.
actor ExerciseClassificationSession {
    struct Update: Sendable {
        let captureID: UUID
        let state: StableExerciseState
        let prediction: ExercisePrediction?
        var loggingError: String?
    }
    private struct Window: Sendable {
        let epoch: Int
        let generation: Int
        let start: Double
        let end: Double
        let samples: [[Double]]
    }
    private struct LogRecord: Codable {
        var version = 1
        let captureID: UUID
        let at: Double
        let prediction: ExercisePrediction?
        let state: StableExerciseState
        let averagedScores: [Double]
        let evidenceCount: Int
        let agreement: Int
        let candidate: ExerciseLabel?
        let inferenceMilliseconds: Double?
    }
    let captureID: UUID
    private let model: PortableExerciseModel
    private let publish: @Sendable (Update) async -> Void
    private var stream = V2StreamingResampler()
    private var filter = ExerciseFeatures()
    private var samples: [(Double,[Double])] = []
    private var count = 0
    private var epoch: Int?
    private var generation = 0
    private var running = false
    private var pending: Window?
    private var policy = ExerciseLabelPolicy()
    private var active = true
    private var writer: FileHandle?
    private var lastPublished: StableExerciseState?
    private var loggingError: String?

    init(captureID: UUID, directory: URL, now: Double,
         publish: @escaping @Sendable (Update) async -> Void) throws {
        self.captureID = captureID; self.publish = publish
        guard let url = Bundle.main.url(forResource: "exercise-portable-model", withExtension: "json") else {
            throw ClassifierError.invalidModel
        }
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == ExerciseModelProvenance.portableHash else { throw ClassifierError.invalidModel }
        guard let schemaURL = Bundle.main.url(forResource: "exercise-feature-schema", withExtension: "json") else {
            throw ClassifierError.invalidModel
        }
        let schemaHash = SHA256.hash(data: try Data(contentsOf: schemaURL)).map { String(format: "%02x", $0) }.joined()
        guard schemaHash == ExerciseModelProvenance.schemaHash else { throw ClassifierError.invalidModel }
        model = try JSONDecoder().decode(PortableExerciseModel.self, from: data).validated()
        policy.start(now: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("exercise-\(captureID.uuidString).jsonl")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw ClassifierError.invalidInput }
        writer = try FileHandle(forWritingTo: log)
    }
    func ingest(_ raw: RawMotionSample) async {
        guard active else { return }
        do {
            guard raw.sensorLocation == .rightHeadphone else { throw ClassifierError.invalidInput }
            let step = try stream.append(raw)
            if step.discontinuity != nil { resetStream(now: raw.receiptUptime) }
            for frame in step.samples {
                if let epoch, epoch != frame.epoch { resetStream(now: raw.receiptUptime) }
                epoch = frame.epoch
                let a = frame.userAcceleration, g = frame.rotationRate, v = frame.gravity
                let filtered = try filter.filter([a.x,a.y,a.z,g.x,g.y,g.z,v.x,v.y,v.z])
                samples.append((frame.sourceTimestamp, filtered)); count += 1
                if samples.count > 200 { samples.removeFirst() }
                policy.sample(source: frame.sourceTimestamp, now: raw.receiptUptime)
                if count >= 200, (count - 200) % 25 == 0 {
                    let window = Window(epoch: frame.epoch, generation: generation,
                        start: samples[0].0, end: frame.sourceTimestamp, samples: samples.map(\.1))
                    if running { pending = window } else { launch(window) }
                }
            }
        } catch { resetStream(now: raw.receiptUptime); policy.unavailable("invalidInput") }
        await emit(at: raw.receiptUptime)
    }
    private func resetStream(now: Double) {
        generation += 1; pending = nil; samples = []; count = 0; epoch = nil; filter = .init()
        policy.discontinuity(now: now)
    }
    private func launch(_ window: Window) {
        running = true
        let model = model
        Task.detached(priority: .userInitiated) { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            let result = Result { try model.predict(ExerciseFeatures.extract(window.samples)) }
            let end = ProcessInfo.processInfo.systemUptime
            await self?.complete(window, result: result, at: end, duration: (end-start)*1000)
        }
    }
    private func complete(_ window: Window, result: Result<[Double], Error>, at: Double, duration: Double) async {
        // Keep the slot owned through the publish await: actor reentrancy must
        // only replace pending, never start a second worker during completion.
        if active, window.generation == generation, window.epoch == epoch {
            switch result {
            case .success(let scores):
                let prediction = ExercisePrediction(captureID: captureID, epoch: window.epoch,
                    windowStart: window.start, windowEnd: window.end, completedAt: at, scores: scores)
                policy.accept(prediction)
                await emit(at: at, prediction: prediction, duration: duration)
            case .failure: policy.unavailable("inferenceFailure"); await emit(at: at)
            }
        }
        running = false
        if active, let next = pending { pending = nil; launch(next) }
    }
    func tick(now: Double) async {
        guard active else { return }
        policy.tick(now: now)
        if policy.state.reason == "inferenceTimeout" { generation += 1; pending = nil }
        await emit(at: now)
    }
    func patternChanged(now: Double) async {
        guard active else { return }
        generation += 1; pending = nil; policy.resetEvidence(reason: "patternChanged")
        await emit(at: now)
    }
    func confirm(_ label: ExerciseLabel, now: Double) async {
        guard active else { return }
        generation += 1; pending = nil; policy.confirm(label, now: now)
        await emit(at: now)
    }
    func finish(now: Double, interrupted: Bool = false) async -> StableExerciseState {
        if interrupted { policy.unavailable("staleInput") }
        active = false; generation += 1; pending = nil; policy.finish()
        await emit(at: now)
        do { try writer?.synchronize(); try writer?.close() } catch { loggingError = error.localizedDescription }
        writer = nil
        return policy.state
    }
    private func emit(at: Double, prediction: ExercisePrediction? = nil, duration: Double? = nil) async {
        guard lastPublished != policy.state || prediction != nil else { return }
        lastPublished = policy.state
        do {
            let record = LogRecord(captureID: captureID, at: at, prediction: prediction, state: policy.state,
                averagedScores: policy.average, evidenceCount: policy.vectors.count, agreement: policy.agreement,
                candidate: policy.candidate, inferenceMilliseconds: duration)
            var data = try JSONEncoder().encode(record); data.append(10); try writer?.write(contentsOf: data)
        } catch { loggingError = error.localizedDescription }
        await publish(Update(captureID: captureID, state: policy.state, prediction: prediction, loggingError: loggingError))
    }
}

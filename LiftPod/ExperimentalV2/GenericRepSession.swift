import Foundation
import CryptoKit
import simd

struct GenericSessionConfiguration: Codable, Equatable, Sendable {
    var schemaVersion = 8
    let setID: UUID
    let sensorSide: ExperimentalSensorSide
    let detector: GenericRepConfiguration
    let metricsEnabled: Bool
    var metricsConfiguration: RepMetricsConfiguration = .cyclicDevicePath3D
    var contentHash: String { GenericHash.of(self) }
}

struct GenericSessionInput: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case sample, end, interrupt, marker }
    let kind: Kind
    var raw: RawMotionEvent?
    var timestamp: Double?
    var interruption: V2SetInterruption?
    var marker: V2SyncMarker?
}

struct GenericSessionTransaction: Codable, Equatable, Sendable {
    let sequence: Int
    let input: GenericSessionInput
    let outputHash: String
    let decision: GenericLearningDecision?
}

struct GenericSessionManifest: Codable, Equatable, Sendable {
    var schemaVersion = 8
    let configurationHash: String
    let transactionCount: Int
    let rawSampleCount: Int
    let state: V2SetState
    let interruption: V2SetInterruption?
    let committedCount: Int
    let templates: [GenericPattern]
    let summaryHash: String
}

/// One writer/reader, owned by a session actor or sequential replay. JSONL is
/// append-only; scans use bounded chunks, never loading a whole set into RAM.
final class GenericFrameHistory: @unchecked Sendable {
    let url: URL
    private let writer: FileHandle
    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        writer = try FileHandle(forWritingTo: url)
    }
    deinit { try? writer.close() }
    func append(_ frame: GenericMotionFrame) throws {
        var data = try GenericHash.data(frame); data.append(10); try writer.write(contentsOf: data)
    }
    func scan(from start: Double, through end: Double, _ consume: (GenericMotionFrame) throws -> Void) throws {
        try writer.synchronize()
        try Self.lines(url) { data in
            let frame = try JSONDecoder().decode(GenericMotionFrame.self, from: data)
            if frame.time >= start, frame.time <= end { try consume(frame) }
        }
    }
    static func lines(_ url: URL, _ consume: (Data) throws -> Void) throws {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var pending = Data()
        while let chunk = try reader.read(upToCount: 65536), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                if !line.isEmpty { try consume(line) }
            }
            guard pending.count < 4_000_000 else { throw V2Error.recordingFailure("oversized JSONL record") }
        }
        guard pending.isEmpty else { throw V2Error.recordingFailure("truncated JSONL record") }
    }
}

/// All decisions depend only on the frozen config and ordered explicit inputs.
/// Recorder and replay use this SAME processor; stored authorizations are never inputs.
struct GenericRepProcessor: Sendable {
    let configuration: GenericSessionConfiguration
    let history: GenericFrameHistory
    private var resampler = V2StreamingResampler()
    private var features = GenericFeaturePipeline()
    private var detector: GenericCycleDetector
    private var recoveryUntil: Double?
    private var endTimestamp: Double?
    private var lastTimestamp: Double?
    private var sourceEpoch: Int?
    private var sequence = 0
    private(set) var state: V2SetState = .active
    private(set) var interruption: V2SetInterruption?
    private(set) var events: [GenericCycleEvent] = []
    private(set) var metrics: [GenericCycleMetrics] = []
    private(set) var templates: [GenericPattern] = []
    private(set) var decision: GenericLearningDecision?
    private var quality: SignalQualityState = .usable
    private var detail = "Learning movement…"

    init(configuration: GenericSessionConfiguration, history: GenericFrameHistory) throws {
        guard configuration.schemaVersion == 8 else { throw V2Error.invalidLifecycle("unknown generic schema") }
        _ = try configuration.detector.validated(); _ = try configuration.metricsConfiguration.validated()
        guard configuration.metricsConfiguration == .cyclicDevicePath3D else { throw V2Error.invalidLifecycle("unsupported generic estimator") }
        self.configuration = configuration; self.history = history
        detector = .init(setID: configuration.setID, configuration: configuration.detector)
    }

    var snapshot: V2ProcessorSnapshot {
        var generic = GenericRepSnapshot(state: recoveryUntil == nil ? detector.state : .recovering,
            learningEpoch: detector.learningEpoch, templateHash: detector.pattern?.contentHash,
            phase: detector.phase, candidateCount: detector.candidateCount,
            events: Array(events.suffix(12)), metrics: Array(metrics.suffix(12)), detail: detail)
        if state == .complete, events.isEmpty { generic.detail = "Pattern not established: three matching cycles are required." }
        let eligible = metrics.filter { $0.learningEpoch == detector.learningEpoch && $0.status == .available }
            .compactMap(\.meanSpeed).filter { $0 >= 0.05 }.prefix(3)
        if eligible.count == 3 { generic.baselineMeanSpeed = eligible.reduce(0,+)/3 }
        return .init(ingestSequence: sequence-1, setState: state, quality: quality,
                     detectorPhase: recoveryUntil == nil ? .ready : .recovering, committedCount: events.count,
                     reference: nil, filteredSignal: nil, landmarks: .init(), recentEvents: [],
                     streamVersion: V2StreamingResampler.version, qualityDetail: detail,
                     isRecovering: recoveryUntil != nil, generic: generic)
    }

    mutating func apply(_ input: GenericSessionInput) throws {
        guard state == .active || state == .finalizing else { throw V2Error.invalidLifecycle("generic session already finished") }
        sequence += 1; decision = nil
        switch input.kind {
        case .sample:
            guard let sample = input.raw?.sample else { throw V2Error.invalidLifecycle("missing sample") }
            guard configuration.sensorSide.matches(sample.sensorLocation) else { stop(.wrongSensorSide); return }
            let step: V2StreamStep
            do { step = try resampler.append(sample) }
            catch V2StreamFailure.backwardClock { stop(.backwardSourceClock); return }
            catch { stop(.invalidInput); return }
            lastTimestamp = sample.sourceTimestamp
            if let notice = step.discontinuity {
                reset(at: sample.sourceTimestamp)
                quality = notice.state; detail = notice.reason
            }
            for uniform in step.samples { try process(uniform) }
            if state == .finalizing, let endTimestamp, sample.sourceTimestamp >= endTimestamp+0.60-1e-9 {
                try resolveMetrics(at: sample.sourceTimestamp, force: true)
                state = .complete
            }
        case .end:
            guard state == .active, let time = input.timestamp, time.isFinite,
                  lastTimestamp.map({ abs($0-time) < 1e-6 }) ?? true else { throw V2Error.invalidLifecycle("invalid generic end boundary") }
            state = .finalizing; endTimestamp = time
            if lastTimestamp == nil { state = .complete }
        case .interrupt:
            guard let reason = input.interruption else { throw V2Error.invalidLifecycle("missing interruption") }
            stop(reason)
        case .marker:
            guard let marker = input.marker, marker.estimatedSessionSourceTime.isFinite,
                  marker.receiptUptime.isFinite else { throw V2Error.invalidLifecycle("invalid marker") }
        }
    }

    private mutating func reset(at time: Double) {
        features.reset(); detector.discontinuity(at: time)
        decision = detector.latestDecision
        recoveryUntil = time + V2StreamingResampler.recoveryDuration
        for i in metrics.indices where metrics[i].status == .pending {
            metrics[i].status = .unavailable; metrics[i].reason = .invalidInterval; metrics[i].finalizedAt = time
        }
    }

    private mutating func process(_ uniform: ResampledMotionSample) throws {
        if sourceEpoch != nil, sourceEpoch != uniform.epoch, recoveryUntil == nil { reset(at: uniform.sourceTimestamp) }
        sourceEpoch = uniform.epoch
        guard let frame = features.observe(uniform) else {
            reset(at: uniform.sourceTimestamp); quality = .degraded; detail = "Recovering from invalid orientation"; return
        }
        try history.append(frame)
        if let until = recoveryUntil {
            guard frame.time >= until-1e-9 else { return }
            recoveryUntil = nil; quality = .usable
        }
        if endTimestamp.map({ frame.time <= $0+0.40+1e-9 }) ?? true {
            if let cycle = detector.observe(frame, departureAllowed: state == .active) {
                try authorize(cycle, at: frame.time)
            }
            if let update = detector.latestDecision {
                decision = update
                if let pattern = update.pattern {
                    templates.append(pattern)
                    detector.beginBackfill()
                    // The history prefix and authorization time are fixed before
                    // scanning. Later samples cannot leak into template fitting.
                    let start = detector.epochStart ?? pattern.learnedFrom[0]
                    var rebuilt = detector
                    var recovered: [GenericTraversal] = []
                    try history.scan(from: start, through: frame.time) { historical in
                        guard historical.sample.epoch == pattern.sourceEpoch else { return }
                        if let cycle = rebuilt.backfill(historical, departureAllowed: endTimestamp.map({ historical.time <= $0 }) ?? true) {
                            recovered.append(cycle)
                        }
                    }
                    detector = rebuilt
                    for cycle in recovered { try authorize(cycle, at: frame.time) }
                }
            }
        }
        detail = detector.pattern == nil ? (detector.learningEpoch == 0 ? "Learning movement…" : "Learning new movement…") :
            (detector.state == .unmatched ? "Pattern lost—waiting for a complete matching cycle" : "Counting repeated movement · experimental")
        try resolveMetrics(at: frame.time, force: false)
    }

    private mutating func authorize(_ cycle: GenericTraversal, at time: Double) throws {
        guard let pattern = detector.pattern,
              cycle.start >= (detector.epochStart ?? cycle.start),
              endTimestamp.map({ cycle.completion <= $0+1e-9 }) ?? true,
              events.last.map({ cycle.start >= $0.completionTimestamp-0.021 }) ?? true else { return }
        let id = "\(configuration.setID.uuidString)-\(pattern.sourceEpoch)-\(cycle.start.bitPattern)-\(cycle.completion.bitPattern)"
        guard !events.contains(where: { $0.id == id }) else { return }
        var event = GenericCycleEvent(id: id, setID: configuration.setID, sourceEpoch: pattern.sourceEpoch,
            learningEpoch: pattern.learningEpoch, templateHash: pattern.contentHash,
            startTimestamp: cycle.start, completionTimestamp: cycle.completion,
            detectionTimestamp: cycle.detected, authorizationTimestamp: time, matchCost: cycle.cost)
        var owned: [GenericMotionFrame] = []
        try history.scan(from:cycle.start,through:cycle.completion) { frame in
            if frame.sample.epoch == pattern.sourceEpoch { owned.append(frame) }
        }
        if let physical = GenericPhysicalPhases.identify(owned) {
            event.turnaroundTimestamp = physical.turnaround
            event.outwardEndTimestamp = physical.outwardEnd
            event.returnStartTimestamp = physical.returnStart
            event.turnaroundPauseDuration = physical.pause
        }
        if let previous = events.last, previous.learningEpoch == event.learningEpoch,
           cycle.start-previous.completionTimestamp >= 0.20 {
            var quietStart: Double?, quietEnd: Double?, valid = true
            try history.scan(from:previous.completionTimestamp,through:cycle.start) { frame in
                if !frame.moving { quietStart = quietStart ?? frame.time; quietEnd = frame.time }
                else { valid = false }
            }
            if valid, let a = quietStart, let b = quietEnd, b-a >= 0.20 { event.precedingPauseDuration = b-a }
        }
        events.append(event)
        if configuration.metricsEnabled { metrics.append(.init(id: id, learningEpoch: pattern.learningEpoch)) }
    }

    private mutating func resolveMetrics(at time: Double, force: Bool) throws {
        for i in metrics.indices where metrics[i].status == .pending {
            guard let event = events.first(where: { $0.id == metrics[i].id }),
                  force || time >= event.completionTimestamp+0.60-1e-9 else { continue }
            var estimator = DevicePathMetrics(configuration: configuration.metricsConfiguration)
            try history.scan(from: event.startTimestamp-0.50, through: min(time,event.completionTimestamp+0.60)) { frame in
                if frame.sample.epoch == event.sourceEpoch { estimator.observePreparedGeneric(frame) }
            }
            metrics[i] = estimator.estimateGeneric(event, at: time)
        }
    }

    private mutating func stop(_ reason: V2SetInterruption) {
        state = .interrupted; interruption = reason; recoveryUntil = nil
        quality = .invalidInput; detail = "Set interrupted: \(reason.rawValue)"
        for i in metrics.indices where metrics[i].status == .pending {
            metrics[i].status = .unavailable; metrics[i].reason = .interrupted; metrics[i].finalizedAt = lastTimestamp
        }
    }
}

actor GenericRepSession {
    private var processor: GenericRepProcessor?
    private var folder: URL?
    private var transactionWriter: FileHandle?
    private var rawWriter: FileHandle?
    private var transactionCount = 0
    private var rawCount = 0
    private(set) var completedBundle: V2SessionBundleURLs?
    var snapshot: V2ProcessorSnapshot? { processor?.snapshot }

    func start(side: ExperimentalSensorSide, metricsEnabled: Bool, directory: URL? = nil) throws {
        guard processor == nil || processor?.state == .complete || processor?.state == .interrupted else { throw V2Error.invalidLifecycle("generic set already active") }
        let config = GenericSessionConfiguration(setID: UUID(), sensorSide: side, detector: .init(), metricsEnabled: metricsEnabled)
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExperimentalV2Sessions")
        let folder = root.appendingPathComponent("generic-v8-\(config.setID.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try GenericHash.data(config).write(to: folder.appendingPathComponent("generic-configuration.json"), options: .atomic)
        processor = try .init(configuration: config, history: GenericFrameHistory(url: folder.appendingPathComponent("prepared-motion.jsonl")))
        self.folder = folder; transactionCount = 0; rawCount = 0; completedBundle = nil
        let transactions = folder.appendingPathComponent("processor-transactions.jsonl")
        let raw = folder.appendingPathComponent("raw-motion.csv")
        FileManager.default.createFile(atPath: transactions.path, contents: nil)
        FileManager.default.createFile(atPath: raw.path, contents: Data((CSVRecorder.header+"\n").utf8))
        transactionWriter = try FileHandle(forWritingTo: transactions)
        rawWriter = try FileHandle(forWritingTo: raw); try rawWriter?.seekToEnd()
    }

    func apply(_ input: GenericSessionInput) throws {
        guard var processor else { throw V2Error.invalidLifecycle("generic session not started") }
        do {
            if input.kind == .sample, let sample = input.raw?.sample {
                try rawWriter?.write(contentsOf: Data((CSVRecorder.row(for: sample)+"\n").utf8)); rawCount += 1
            }
            try processor.apply(input)
            let transaction = GenericSessionTransaction(sequence: transactionCount, input: input,
                outputHash: GenericHash.of(processor.snapshot), decision: processor.decision)
            var bytes = try GenericHash.data(transaction); bytes.append(10)
            try transactionWriter?.write(contentsOf: bytes); transactionCount += 1
            self.processor = processor
            if processor.state == .complete || processor.state == .interrupted { try finish() }
        } catch {
            if let lifecycle = error as? V2Error, case .invalidLifecycle = lifecycle { throw error }
            if processor.state == .active || processor.state == .finalizing {
                try? processor.apply(.init(kind: .interrupt, interruption: .recordingFailure))
            }
            self.processor = processor; completedBundle = nil
            throw error
        }
    }

    private func finish() throws {
        guard let processor, let folder else { return }
        let summary = GenericSessionSummary(events: processor.events, metrics: processor.metrics, snapshot: processor.snapshot)
        let manifest = GenericSessionManifest(configurationHash: processor.configuration.contentHash,
            transactionCount: transactionCount, rawSampleCount: rawCount, state: processor.state,
            interruption: processor.interruption, committedCount: processor.events.count,
            templates: processor.templates, summaryHash: GenericHash.of(summary))
        try transactionWriter?.synchronize(); try rawWriter?.synchronize()
        try transactionWriter?.close(); try rawWriter?.close(); transactionWriter = nil; rawWriter = nil
        try GenericHash.data(summary).write(to: folder.appendingPathComponent("summary.json"), options: .atomic)
        try GenericHash.data(manifest).write(to: folder.appendingPathComponent("v8-analysis-manifest.json"), options: .atomic)
        try GenericHash.data(processor.configuration).write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        completedBundle = .init(directory: folder, rawCSV: folder.appendingPathComponent("raw-motion.csv"),
            transactions: folder.appendingPathComponent("processor-transactions.jsonl"), metadata: folder.appendingPathComponent("metadata.json"),
            summary: folder.appendingPathComponent("summary.json"), manifest: folder.appendingPathComponent("v8-analysis-manifest.json"),
            profile: folder.appendingPathComponent("generic-configuration.json"))
    }
}

struct GenericSessionSummary: Codable, Equatable, Sendable {
    let events: [GenericCycleEvent]
    let metrics: [GenericCycleMetrics]
    let snapshot: V2ProcessorSnapshot
}

struct GenericReplayVerifier {
    func verify(directory: URL) throws -> V2ReplayResult {
        let decoder = JSONDecoder()
        let config = try decoder.decode(GenericSessionConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("generic-configuration.json")))
        let manifest = try decoder.decode(GenericSessionManifest.self, from: Data(contentsOf: directory.appendingPathComponent("v8-analysis-manifest.json")))
        let saved = try decoder.decode(GenericSessionSummary.self, from: Data(contentsOf: directory.appendingPathComponent("summary.json")))
        guard manifest.schemaVersion == 8, manifest.configurationHash == config.contentHash,
              manifest.summaryHash == GenericHash.of(saved), manifest.state == .complete else {
            return .init(passed: false, mismatchSequence: nil, field: "genericManifest")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("generic-replay-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var processor = try GenericRepProcessor(configuration: config, history: GenericFrameHistory(url: scratch))
        var sequence = 0, rawCount = 0
        var mismatch: V2ReplayResult?
        var rawHash = SHA256()
        rawHash.update(data: Data((CSVRecorder.header+"\n").utf8))
        try GenericFrameHistory.lines(directory.appendingPathComponent("processor-transactions.jsonl")) { line in
            guard mismatch == nil else { return }
            let transaction = try decoder.decode(GenericSessionTransaction.self, from: line)
            guard transaction.sequence == sequence else { mismatch = .init(passed:false,mismatchSequence:sequence,field:"sequence"); return }
            try processor.apply(transaction.input)
            if transaction.input.kind == .sample, let raw = transaction.input.raw?.sample {
                rawCount += 1; rawHash.update(data: Data((CSVRecorder.row(for: raw)+"\n").utf8))
            }
            guard transaction.outputHash == GenericHash.of(processor.snapshot), transaction.decision == processor.decision else {
                mismatch = .init(passed:false,mismatchSequence:sequence,field:"regeneratedGenericOutput"); return
            }
            sequence += 1
        }
        if let mismatch { return mismatch }
        var savedRawHash = SHA256()
        let rawReader = try FileHandle(forReadingFrom: directory.appendingPathComponent("raw-motion.csv")); defer { try? rawReader.close() }
        while let chunk = try rawReader.read(upToCount: 65536), !chunk.isEmpty { savedRawHash.update(data: chunk) }
        let regenerated = GenericSessionSummary(events:processor.events,metrics:processor.metrics,snapshot:processor.snapshot)
        guard sequence == manifest.transactionCount, rawCount == manifest.rawSampleCount,
              processor.state == manifest.state, processor.interruption == manifest.interruption,
              processor.events.count == manifest.committedCount, processor.templates == manifest.templates,
              regenerated == saved, rawHash.finalize() == savedRawHash.finalize() else {
            return .init(passed:false,mismatchSequence:nil,field:"genericSummary")
        }
        return .init(passed:true,mismatchSequence:nil,field:nil)
    }
}

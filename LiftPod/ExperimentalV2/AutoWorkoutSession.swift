import Foundation
import CryptoKit

struct AutoWorkoutProcessor {
    let configuration: AutoWorkoutConfiguration
    private var resampler = V2StreamingResampler()
    private var engine: AutoPatternEngine
    private var coordinator: AutoSetCoordinator
    private var metrics: AutoWorkoutMetrics
    private var lastMetricUpdate = -Double.infinity
    private var sourceTimeOffset = 0.0
    private var awaitingResumedClock = false
    private(set) var latestFrame: GenericMotionFrame?
    private(set) var latestEvidence: AutoEvidenceBatch?
    private(set) var evidenceBatches: [AutoEvidenceBatch] = []
    var evidenceHash: String? { evidenceBatches.isEmpty ? nil : GenericHash.of(evidenceBatches) }
    private(set) var snapshot: AutoWorkoutSnapshot

    init(configuration: AutoWorkoutConfiguration) throws {
        self.configuration = try configuration.validated()
        engine = .init(configuration: configuration)
        coordinator = .init(configuration: configuration)
        metrics = .init(configuration: configuration)
        snapshot = coordinator.snapshot
    }

    mutating func apply(_ input: AutoWorkoutInput) throws {
        latestFrame = nil; latestEvidence = nil; evidenceBatches = []
        if input.kind == .sample {
            guard [.connecting,.running].contains(snapshot.state), let raw = input.raw?.sample else {
                throw V2Error.invalidLifecycle("automatic sample outside active capture")
            }
            guard configuration.side.matches(raw.sensorLocation) else {
                try apply(.init(kind:.suspend,timestamp:snapshot.timestamp ?? raw.sourceTimestamp,reason:"Sensor side changed"))
                return
            }
            if awaitingResumedClock {
                if let previous = snapshot.timestamp, raw.sourceTimestamp + sourceTimeOffset <= previous {
                    sourceTimeOffset = previous + 0.02 - raw.sourceTimestamp
                }
                awaitingResumedClock = false
            }
            let step: V2StreamStep
            do { step = try resampler.append(raw) }
            catch {
                try apply(.init(kind:.suspend,timestamp:snapshot.timestamp ?? raw.sourceTimestamp,reason:"Invalid motion clock or sample"))
                return
            }
            if step.discontinuity != nil { engine.discontinuity(at:raw.sourceTimestamp + sourceTimeOffset) }
            for native in step.samples {
                // Preserve raw clocks in the journal; project resumed sensor clocks
                // onto the monotonic workout timeline without bridging the gap.
                let sample = ResampledMotionSample(sourceTimestamp:native.sourceTimestamp + sourceTimeOffset,
                    sessionTime:native.sessionTime,sensorSide:native.sensorSide,
                    userAcceleration:native.userAcceleration,rotationRate:native.rotationRate,
                    gravity:native.gravity,attitude:native.attitude,
                    interpolationStatus:native.interpolationStatus,epoch:native.epoch)
                let batch = engine.observe(sample)
                latestEvidence = batch; evidenceBatches.append(batch); latestFrame = engine.latestPreparedFrame
                if let frame = latestFrame { metrics.observe(frame) }
                coordinator.consume(batch)
            }
        } else if input.kind == .clock {
            guard let time = input.timestamp, time.isFinite else { throw V2Error.invalidLifecycle("invalid automatic clock") }
            // Missing callbacks are unknown coverage, never evidence of rest.
            if [.connecting,.running].contains(snapshot.state), time-(snapshot.timestamp ?? time) >= 1 {
                try coordinator.command(.init(kind:.suspend,timestamp:time,reason:input.reason ?? "Motion stream stopped"))
                engine.discontinuity(at:time)
            }
        } else {
            try coordinator.command(input)
            let time = input.timestamp ?? snapshot.timestamp ?? 0
            switch input.kind {
            case .pause, .endSet: engine.boundary(at:time)
            case .suspend, .finish: engine.discontinuity(at:time)
            case .resume:
                resampler = .init()
                awaitingResumedClock = true
                engine.discontinuity(at:time)
            default: break
            }
        }
        let previousMetrics = snapshot.metrics
        snapshot = coordinator.snapshot
        let time = snapshot.timestamp ?? input.timestamp ?? 0
        let force = [.finish,.pause,.suspend,.correction,.endSet].contains(input.kind)
        if force || time-lastMetricUpdate >= 0.1-1e-9 {
            snapshot.metrics = metrics.update(cycles:snapshot.cycles,sets:snapshot.sets,at:time,force:force)
            lastMetricUpdate = time
        } else { snapshot.metrics = previousMetrics }
        for i in snapshot.sets.indices { snapshot.sets[i].baselineMeanSpeed = metrics.baselines[snapshot.sets[i].id] }
    }
}

struct AutoWorkoutTransaction: Codable, Equatable {
    let sequence: Int
    let configurationHash: String
    let input: AutoWorkoutInput
    let evidenceHash: String?
    let outputHash: String
}

struct AutoWorkoutManifest: Codable, Equatable {
    let schemaVersion: Int
    let configurationHash: String
    let transactionCount: Int
    let summaryHash: String
}

/// A compact per-input checkpoint; the final manifest also hashes the full ledger.
private struct AutoWorkoutCheckpoint: Encodable {
    let state: AutoWorkoutState
    let timestamp: Double?
    let status: String
    let sets: [AutoSetRecord]
    let cycleCount: Int
    let lastCycle: AutoCycleEvidence?
    let intervalCount: Int
    let lastInterval: AutoTimelineInterval?
    let metricsCount: Int
    let candidateCount: Int
    let restStartedAt: Double?
    let availabilityReason: String?
    init(_ s: AutoWorkoutSnapshot) {
        state=s.state;timestamp=s.timestamp;status=s.status;sets=s.sets
        cycleCount=s.cycles.count;lastCycle=s.cycles.last
        intervalCount=s.intervals.count;lastInterval=s.intervals.last
        metricsCount=s.metrics.count;candidateCount=s.candidateCount
        restStartedAt=s.restStartedAt;availabilityReason=s.availabilityReason
    }
}

actor AutoWorkoutSession {
    private var processor: AutoWorkoutProcessor?
    private var transactions: FileHandle?
    private var rawWriter: FileHandle?
    private var sequence = 0
    private(set) var directory: URL?
    var snapshot: AutoWorkoutSnapshot { processor?.snapshot ?? .init() }
    var exportURLs: [URL] {
        guard let directory else { return [] }
        return ["auto-configuration.json","processor-transactions.jsonl","raw-motion.csv","summary.json","auto-manifest.json"]
            .map { directory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath:$0.path) }
    }
    deinit { try? transactions?.close();try? rawWriter?.close() }

    static var storageRoot: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AutoWorkouts")
    }

    func start(configuration: AutoWorkoutConfiguration, root: URL? = nil) throws {
        guard processor == nil || processor?.snapshot.state == .finished else { throw V2Error.invalidLifecycle("automatic workout already open") }
        let folder = (root ?? Self.storageRoot).appendingPathComponent("auto-v9-\(configuration.workoutID.uuidString)")
        try open(configuration:configuration,folder:folder)
    }

    private func open(configuration: AutoWorkoutConfiguration, folder: URL) throws {
        guard !FileManager.default.fileExists(atPath:folder.path) else { throw V2Error.recordingFailure("workout directory already exists") }
        let next = try AutoWorkoutProcessor(configuration:configuration)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var journalHandle: FileHandle?, rawHandle: FileHandle?
        do {
            try GenericHash.data(configuration).write(to:folder.appendingPathComponent("auto-configuration.json"),options:.atomic)
            let journal=folder.appendingPathComponent("processor-transactions.jsonl")
            let raw=folder.appendingPathComponent("raw-motion.csv")
            try Data().write(to:journal)
            try Data((CSVRecorder.header+"\n").utf8).write(to:raw)
            journalHandle=try FileHandle(forWritingTo:journal)
            rawHandle=try FileHandle(forWritingTo:raw)
            try rawHandle?.seekToEnd()
        } catch {
            try? journalHandle?.close();try? rawHandle?.close()
            try? FileManager.default.removeItem(at:folder)
            throw error
        }
        try? transactions?.close();try? rawWriter?.close()
        transactions=journalHandle;rawWriter=rawHandle
        processor=next;directory=folder;sequence=0
    }

    func apply(_ requested: AutoWorkoutInput) throws {
        guard var next = processor else { throw V2Error.invalidLifecycle("automatic workout not started") }
        var input = requested
        // UI commands acquire their effective cutoff in this serialized owner,
        // after any already accepted samples, rather than from a throttled view.
        if input.kind != .sample && input.kind != .clock && input.timestamp == nil {
            input.timestamp = next.snapshot.timestamp ?? 0
        }
        try next.apply(input)
        let tx=AutoWorkoutTransaction(sequence:sequence,configurationHash:GenericHash.of(next.configuration),input:input,
            evidenceHash:next.evidenceHash,outputHash:GenericHash.of(AutoWorkoutCheckpoint(next.snapshot)))
        do {
            guard let directory else { throw V2Error.recordingFailure("missing workout directory") }
            if transactions == nil {
                transactions=try FileHandle(forWritingTo:directory.appendingPathComponent("processor-transactions.jsonl"))
                try transactions?.seekToEnd()
            }
            if rawWriter == nil {
                rawWriter=try FileHandle(forWritingTo:directory.appendingPathComponent("raw-motion.csv"))
                try rawWriter?.seekToEnd()
            }
            if let raw=input.raw?.sample { try rawWriter?.write(contentsOf:Data((CSVRecorder.row(for:raw)+"\n").utf8)) }
            var data=try GenericHash.data(tx);data.append(10);try transactions?.write(contentsOf:data)
            processor=next;sequence+=1
            if input.kind != .sample || sequence % 50 == 0 { try transactions?.synchronize();try rawWriter?.synchronize() }
            if next.snapshot.state == .finished || [.pause,.suspend,.correction].contains(input.kind) { try checkpoint() }
            if next.snapshot.state == .finished { try transactions?.close();try rawWriter?.close();transactions=nil;rawWriter=nil }
        } catch {
            // Do not publish an unjournaled count after a write failure.
            if var current=processor {
                try? current.apply(.init(kind:.suspend,timestamp:current.snapshot.timestamp ?? 0,reason:"Recording failed"))
                processor=current
            }
            throw error
        }
    }

    private func checkpoint() throws {
        guard let processor,let directory else { return }
        try GenericHash.data(processor.snapshot).write(to:directory.appendingPathComponent("summary.json"),options:.atomic)
        let manifest=AutoWorkoutManifest(schemaVersion:9,configurationHash:GenericHash.of(processor.configuration),
            transactionCount:sequence,summaryHash:GenericHash.of(processor.snapshot))
        try GenericHash.data(manifest).write(to:directory.appendingPathComponent("auto-manifest.json"),options:.atomic)
    }

    /// Keep the interrupted original intact; write the verified prefix into a
    /// new recovery bundle before accepting an explicit user Resume command.
    func recover(from original: URL, root: URL? = nil) throws {
        guard processor == nil || processor?.snapshot.state == .finished else { throw V2Error.invalidLifecycle("finish current workout before recovery") }
        let config=try JSONDecoder().decode(AutoWorkoutConfiguration.self,from:Data(contentsOf:original.appendingPathComponent("auto-configuration.json")))
        let recovered=(root ?? Self.storageRoot).appendingPathComponent("auto-v9-\(config.workoutID.uuidString)-recovered-\(UUID().uuidString)")
        let sourceJournal = original.appendingPathComponent("processor-transactions.jsonl")
        let readable = try FileHandle(forReadingFrom:sourceJournal)
        try readable.close()
        var checkedAnchor = false
        try AutoWorkoutReplay.lines(sourceJournal,allowPartialTail:true) { data in
            guard !checkedAnchor else { return }
            checkedAnchor = true
            let first = try JSONDecoder().decode(AutoWorkoutTransaction.self,from:data)
            guard first.configurationHash == GenericHash.of(config) else {
                throw V2Error.recordingFailure("automatic configuration does not match journal")
            }
        }
        try open(configuration:config,folder:recovered)
        var invalid=false
        try AutoWorkoutReplay.lines(original.appendingPathComponent("processor-transactions.jsonl"),allowPartialTail:true) { data in
            guard !invalid else { return }
            do {
                let tx=try JSONDecoder().decode(AutoWorkoutTransaction.self,from:data)
                guard tx.sequence == self.sequence, tx.configurationHash == GenericHash.of(config), var candidate=self.processor else { invalid=true;return }
                try candidate.apply(tx.input)
                guard tx.outputHash == GenericHash.of(AutoWorkoutCheckpoint(candidate.snapshot)),
                      tx.evidenceHash == candidate.evidenceHash else { invalid=true;return }
            } catch { invalid=true;return }
            let tx=try JSONDecoder().decode(AutoWorkoutTransaction.self,from:data)
            try self.apply(tx.input)
        }
        if processor?.snapshot.state != .finished {
            try apply(.init(kind:.suspend,timestamp:processor?.snapshot.timestamp ?? 0,reason:invalid ? "Recovered verified prefix; damaged tail excluded" : "Recovered interrupted workout"))
        }
        try Data(original.standardizedFileURL.path.utf8).write(to:recovered.appendingPathComponent("recovery-source.txt"),options:.atomic)
    }

    static func recoverableDirectory() -> URL? {
        let folders=(try? FileManager.default.contentsOfDirectory(at:storageRoot,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
        let recoveredSources = Set(folders.compactMap {
            try? String(contentsOf:$0.appendingPathComponent("recovery-source.txt"),encoding:.utf8)
        })
        return folders.filter { folder in
            guard !recoveredSources.contains(folder.standardizedFileURL.path) else { return false }
            guard FileManager.default.fileExists(atPath:folder.appendingPathComponent("auto-configuration.json").path) else { return false }
            if let data=try? Data(contentsOf:folder.appendingPathComponent("summary.json")),
               let summary=try? JSONDecoder().decode(AutoWorkoutSnapshot.self,from:data),summary.state == .finished { return false }
            return true
        }.sorted { a,b in
            let ad=(try? a.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd=(try? b.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad>bd
        }.first
    }
}

enum AutoWorkoutReplay {
    static func verify(directory: URL) throws -> Bool {
        let decoder=JSONDecoder()
        let config=try decoder.decode(AutoWorkoutConfiguration.self,from:Data(contentsOf:directory.appendingPathComponent("auto-configuration.json")))
        let manifest=try decoder.decode(AutoWorkoutManifest.self,from:Data(contentsOf:directory.appendingPathComponent("auto-manifest.json")))
        let summary=try decoder.decode(AutoWorkoutSnapshot.self,from:Data(contentsOf:directory.appendingPathComponent("summary.json")))
        guard manifest.schemaVersion == 9,manifest.configurationHash == GenericHash.of(config),manifest.summaryHash == GenericHash.of(summary) else { return false }
        var p=try AutoWorkoutProcessor(configuration:config),sequence=0,valid=true
        let raw=try FileHandle(forReadingFrom:directory.appendingPathComponent("raw-motion.csv"));defer { try? raw.close() }
        // Hash reconstructed CSV without retaining the whole workout in memory.
        var csv=Data((CSVRecorder.header+"\n").utf8)
        var reconstructed=CryptoKit.SHA256();reconstructed.update(data:csv)
        try lines(directory.appendingPathComponent("processor-transactions.jsonl")) { data in
            guard valid else { return }
            let tx=try decoder.decode(AutoWorkoutTransaction.self,from:data)
            guard tx.sequence == sequence, tx.configurationHash == GenericHash.of(config) else { valid=false;return }
            try p.apply(tx.input)
            valid=tx.outputHash == GenericHash.of(AutoWorkoutCheckpoint(p.snapshot)) && tx.evidenceHash == p.evidenceHash
            if let sample=tx.input.raw?.sample { csv=Data((CSVRecorder.row(for:sample)+"\n").utf8);reconstructed.update(data:csv) }
            sequence+=1
        }
        var saved=CryptoKit.SHA256()
        while let data=try raw.read(upToCount:65536),!data.isEmpty { saved.update(data:data) }
        return valid && sequence == manifest.transactionCount && p.snapshot == summary && reconstructed.finalize() == saved.finalize()
    }

    static func lines(_ url: URL, allowPartialTail: Bool = false, _ consume: (Data) throws -> Void) throws {
        let file=try FileHandle(forReadingFrom:url);defer { try? file.close() }
        var pending=Data()
        while let data=try file.read(upToCount:65536),!data.isEmpty {
            pending.append(data)
            while let nl=pending.firstIndex(of:10) {
                let line=Data(pending[..<nl]);pending.removeSubrange(...nl)
                try consume(line)
            }
            guard pending.count < 4*1024*1024 else { throw V2Error.recordingFailure("oversized automatic journal record") }
        }
        if !allowPartialTail && !pending.isEmpty { throw V2Error.recordingFailure("truncated automatic journal record") }
    }
}

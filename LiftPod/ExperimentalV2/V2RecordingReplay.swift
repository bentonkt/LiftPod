import CryptoKit
import Foundation

enum V2ProcessorBoundary: String, Codable, Sendable { case start, end }

struct V2ProcessorTransaction: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let processorVersion: String
    let ingestSequence: Int
    let boundary: V2ProcessorBoundary?
    let input: RawMotionEvent?
    let output: V2ProcessorSnapshot
    let uniformSamples: [ResampledMotionSample]
    let profileID: String
    let profileHash: String
    let outputHash: String

    init(schemaVersion: Int, processorVersion: String, ingestSequence: Int,
         boundary: V2ProcessorBoundary?, input: RawMotionEvent?, output: V2ProcessorSnapshot,
         uniformSamples: [ResampledMotionSample], profileID: String, profileHash: String,
         outputHash: String? = nil) {
        self.schemaVersion = schemaVersion; self.processorVersion = processorVersion
        self.ingestSequence = ingestSequence; self.boundary = boundary; self.input = input
        self.output = output; self.uniformSamples = uniformSamples
        self.profileID = profileID; self.profileHash = profileHash
        self.outputHash = outputHash ?? Self.hash(output)
    }

    static func hash(_ output: V2ProcessorSnapshot) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(output) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct V2SyncMarker: Codable, Sendable, Equatable {
    let name: String
    let estimatedSessionSourceTime: Double
    let receiptUptime: Double
    let ingestSequence: Int
}

struct V2AnalysisManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let completionState: V2SetState
    let failureReason: V2SetInterruption?
    let descriptor: V2SetDescriptor
    let exercise: V2Exercise
    let scenarioLabel: String
    let profiles: [V2DSPProfile]
    let dspHashes: [String]
    let processingConfiguration: V2DSPIdentity
    let sourceToReceiptClockOffset: Double?
    let transactionCount: Int
    let rawSampleCount: Int
    let committedRepCount: Int
    let processingP95: Double
    let maximumRecordingQueueLag: Int
    let referenceMeasurements: V2ReferenceMeasurements?
    let syncMarkers: [V2SyncMarker]
}

struct V2SessionSummary: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let processorVersion: String
    let descriptor: V2SetDescriptor
    let state: V2SetState
    let committedCount: Int
    let candidates: [V2CycleEvidence]
}

struct V2SessionMetadata: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let setID: UUID
    let createdUTC: Date
}

struct V2SessionBundleURLs: Sendable, Equatable {
    let directory: URL
    let rawCSV: URL
    let transactions: URL
    let metadata: URL
    let summary: URL
    let manifest: URL
    let profile: URL
}

enum V2RecordingQueueError: Error, Equatable { case overflow, terminated }

actor V2BoundedRecordingQueue<Element: Sendable> {
    private let capacity: Int
    private var elements: [Element] = []
    private var terminated = false
    init(capacity: Int = 512) { self.capacity = capacity }
    func enqueue(_ element: Element) throws {
        guard !terminated else { throw V2RecordingQueueError.terminated }
        guard elements.count < capacity else { throw V2RecordingQueueError.overflow }
        elements.append(element)
    }
    func dequeue() -> Element? { elements.isEmpty ? nil : elements.removeFirst() }
    func terminate() { terminated = true }
    var count: Int { elements.count }
}

actor V2SessionRecorder: V2RecordingSink {
    private let root: URL
    private var descriptor: V2SetDescriptor?
    private var profile: V2DSPProfile?
    private var raw: [RawMotionSample] = []
    private var transactions: [V2ProcessorTransaction] = []
    private var markers: [V2SyncMarker] = []
    private var finalized: V2SessionBundleURLs?

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = directory ?? support.appendingPathComponent("ExperimentalV2Sessions", isDirectory: true)
    }

    func start(descriptor: V2SetDescriptor, profile: V2DSPProfile) throws {
        guard self.descriptor == nil else { throw V2Error.recordingFailure("recorder is already active") }
        self.descriptor = descriptor; self.profile = try profile.validated()
        raw = []; transactions = []; markers = []; finalized = nil
    }

    func appendRaw(_ sample: RawMotionSample) throws {
        guard descriptor != nil else { throw V2Error.recordingFailure("recorder is not active") }
        raw.append(sample)
    }

    func appendTransaction(_ transaction: V2ProcessorTransaction) throws {
        guard descriptor != nil, transaction.ingestSequence == transactions.count else {
            throw V2Error.recordingFailure("transaction sequence is not contiguous")
        }
        transactions.append(transaction)
    }

    func addMarker(_ marker: V2SyncMarker) throws {
        guard descriptor != nil else { throw V2Error.recordingFailure("recorder is not active") }
        markers.append(marker)
    }

    func finalize(state: V2SetState, failure: V2SetInterruption?, snapshot: V2ProcessorSnapshot,
                  reference: V2ReferenceMeasurements?) throws -> V2SessionBundleURLs? {
        if let finalized { return finalized }
        guard let descriptor, let profile else { return nil }
        let isV6 = profile.identity.profileVersion == "experimental-v6"
        let schema = isV6 ? 6 : 2
        let processor = isV6 ? "rep-analysis-v6" : "rep-analysis-v2"
        let end = V2ProcessorTransaction(schemaVersion: schema, processorVersion: processor,
                                         ingestSequence: transactions.count, boundary: .end, input: nil,
                                         output: snapshot, uniformSamples: [], profileID: profile.profileID,
                                         profileHash: profile.contentHash)
        transactions.append(end)
        let prefix = isV6 ? "experimental-v6" : "experimental-v2"
        let folder = root.appendingPathComponent("\(prefix)-\(descriptor.setID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = V2SessionBundleURLs(
            directory: folder, rawCSV: folder.appendingPathComponent("raw-motion.csv"),
            transactions: folder.appendingPathComponent("processor-transactions.jsonl"),
            metadata: folder.appendingPathComponent("metadata.json"),
            summary: folder.appendingPathComponent("summary.json"),
            manifest: folder.appendingPathComponent("\(isV6 ? "v6" : "v2")-analysis-manifest.json"),
            profile: folder.appendingPathComponent("\(prefix)-profile.json")
        )
        let clockOffset = raw.first.map { $0.receiptUptime - $0.sourceTimestamp }
        let manifest = V2AnalysisManifest(
            schemaVersion: schema, completionState: state, failureReason: failure, descriptor: descriptor,
            exercise: descriptor.exercise, scenarioLabel: descriptor.hardwareSetupIdentifier,
            profiles: [profile], dspHashes: [profile.contentHash], processingConfiguration: profile.identity,
            sourceToReceiptClockOffset: clockOffset, transactionCount: transactions.count,
            rawSampleCount: raw.count, committedRepCount: snapshot.committedCount,
            processingP95: 0, maximumRecordingQueueLag: 0,
            referenceMeasurements: reference, syncMarkers: markers
        )
        let summary = V2SessionSummary(schemaVersion: schema, processorVersion: processor,
                                       descriptor: descriptor, state: state,
                                       committedCount: snapshot.committedCount, candidates: snapshot.recentEvents)
        let metadata = V2SessionMetadata(schemaVersion: schema, setID: descriptor.setID, createdUTC: Date())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let lineEncoder = JSONEncoder(); lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let csv = ([CSVRecorder.header] + raw.map(CSVRecorder.row(for:))).joined(separator: "\n") + "\n"
        let jsonl = try transactions.map { String(decoding: try lineEncoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try publish(Data(csv.utf8), to: urls.rawCSV)
        try publish(Data(jsonl.utf8), to: urls.transactions)
        try publish(try encoder.encode(metadata), to: urls.metadata)
        try publish(try encoder.encode(summary), to: urls.summary)
        try publish(try encoder.encode(manifest), to: urls.manifest)
        try publish(try encoder.encode(profile), to: urls.profile)
        finalized = urls
        self.descriptor = nil; self.profile = nil
        return urls
    }

    private func publish(_ data: Data, to url: URL) throws {
        let partial = url.appendingPathExtension("partial")
        try data.write(to: partial, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) { throw V2Error.recordingFailure("destination exists") }
        try FileManager.default.moveItem(at: partial, to: url)
    }
}

struct V2ReplayArchive: Sendable {
    let manifest: V2AnalysisManifest
    let profile: V2DSPProfile
    let transactions: [V2ProcessorTransaction]

    static func load(from directory: URL) throws -> Self {
        let decoder = JSONDecoder()
        let isV6 = FileManager.default.fileExists(atPath: directory.appendingPathComponent("v6-analysis-manifest.json").path)
        let manifest = try decoder.decode(V2AnalysisManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent(isV6 ? "v6-analysis-manifest.json" : "v2-analysis-manifest.json")))
        let profile = try decoder.decode(V2DSPProfile.self,
            from: Data(contentsOf: directory.appendingPathComponent(isV6 ? "experimental-v6-profile.json" : "experimental-v2-profile.json")))
        let data = try Data(contentsOf: directory.appendingPathComponent("processor-transactions.jsonl"))
        let transactions = try data.split(separator: 0x0A).map {
            try decoder.decode(V2ProcessorTransaction.self, from: Data($0))
        }
        return .init(manifest: manifest, profile: profile, transactions: transactions)
    }
}

struct V2ReplayResult: Sendable, Equatable {
    let passed: Bool
    let mismatchSequence: Int?
    let field: String?
}

struct V2ReplayVerifier: Sendable {
    func verify(_ archive: V2ReplayArchive) -> V2ReplayResult {
        let manifest = archive.manifest
        guard [2, 6].contains(manifest.schemaVersion) else { return fail(nil, "schemaVersion") }
        guard manifest.completionState == .complete else { return fail(nil, "completionState") }
        guard manifest.rawSampleCount > 0, manifest.transactionCount > 0 else { return fail(nil, "nonempty recording") }
        guard manifest.transactionCount == archive.transactions.count else { return fail(nil, "transactionCount") }
        guard archive.transactions.enumerated().allSatisfy({ $0.offset == $0.element.ingestSequence }) else {
            return fail(nil, "ingestSequence")
        }
        guard archive.transactions.first?.boundary == .start,
              archive.transactions.last?.boundary == .end else { return fail(nil, "boundaries") }
        guard archive.transactions.dropLast().allSatisfy({ $0.input != nil }),
              archive.transactions.dropLast().dropFirst().allSatisfy({ $0.boundary == nil }),
              archive.transactions.last?.input == nil,
              archive.transactions.count - 1 == manifest.rawSampleCount else { return fail(nil, "inputCount") }
        guard let valid = try? archive.profile.validated(), valid.contentHash == manifest.descriptor.dspContentHash,
              manifest.dspHashes == [valid.contentHash], manifest.profiles == [valid],
              manifest.processingConfiguration == valid.identity else { return fail(nil, "profileHash") }
        var raw: [RawMotionSample] = []
        var uniformCount = 0
        let expectedSchema = valid.identity.profileVersion == "experimental-v6" ? 6 : 2
        let expectedProcessor = expectedSchema == 6 ? "rep-analysis-v6" : "rep-analysis-v2"
        for transaction in archive.transactions {
            guard transaction.schemaVersion == expectedSchema,
                  transaction.processorVersion == expectedProcessor,
                  transaction.profileID == valid.profileID,
                  transaction.profileHash == valid.contentHash else {
                return fail(transaction.ingestSequence, "profileVersion")
            }
            guard transaction.outputHash == V2ProcessorTransaction.hash(transaction.output) else {
                return fail(transaction.ingestSequence, "output")
            }
            guard finite(transaction) else { return fail(transaction.ingestSequence, "finiteDSPFields") }
            if transaction.input == nil, transaction.boundary != .end {
                return fail(transaction.ingestSequence, "inputEvent")
            }
            if let input = transaction.input {
                raw.append(input.sample)
                guard let result = try? V2UniformSourceResampler().resample(raw, profile: valid) else {
                    return fail(transaction.ingestSequence, "resampling")
                }
                let expected = Array(result.samples.dropFirst(uniformCount))
                guard equal(expected, transaction.uniformSamples) else {
                    return fail(transaction.ingestSequence, "uniformSamples")
                }
                uniformCount = result.samples.count
            }
        }
        return .init(passed: true, mismatchSequence: nil, field: nil)
    }

    private func equal(_ left: [ResampledMotionSample], _ right: [ResampledMotionSample]) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { a, b in
            a.sensorSide == b.sensorSide && a.interpolationStatus == b.interpolationStatus && a.epoch == b.epoch &&
            close(a.sourceTimestamp, b.sourceTimestamp) && close(a.sessionTime, b.sessionTime) &&
            close(a.userAcceleration.x, b.userAcceleration.x) && close(a.userAcceleration.y, b.userAcceleration.y) &&
            close(a.userAcceleration.z, b.userAcceleration.z) && close(a.rotationRate.x, b.rotationRate.x) &&
            close(a.rotationRate.y, b.rotationRate.y) && close(a.rotationRate.z, b.rotationRate.z) &&
            close(a.gravity.x, b.gravity.x) && close(a.gravity.y, b.gravity.y) && close(a.gravity.z, b.gravity.z) &&
            close(a.attitude.w, b.attitude.w) && close(a.attitude.x, b.attitude.x) &&
            close(a.attitude.y, b.attitude.y) && close(a.attitude.z, b.attitude.z)
        }
    }

    private func close(_ left: Double, _ right: Double) -> Bool {
        left.isFinite && right.isFinite && abs(left - right) <= 1e-9
    }

    private func finite(_ transaction: V2ProcessorTransaction) -> Bool {
        let values = transaction.uniformSamples.flatMap { sample in
            [sample.sourceTimestamp, sample.sessionTime, sample.userAcceleration.x, sample.userAcceleration.y,
             sample.userAcceleration.z, sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z,
             sample.gravity.x, sample.gravity.y, sample.gravity.z, sample.attitude.w, sample.attitude.x,
             sample.attitude.y, sample.attitude.z]
        }
        return values.allSatisfy(\.isFinite) && (transaction.output.filteredSignal?.isFinite ?? true)
    }

    private func fail(_ sequence: Int?, _ field: String) -> V2ReplayResult {
        .init(passed: false, mismatchSequence: sequence, field: field)
    }
}

struct V2HumanReview: Codable, Sendable, Equatable {
    let observedCount: Int?
    let committedCount: Int
    let notes: String
    let createdUTC: Date
}

struct V2HumanReviewWriter: Sendable {
    func save(_ review: V2HumanReview, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("review-\(UUID().uuidString).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(review).write(to: url, options: .withoutOverwriting)
        return url
    }
}

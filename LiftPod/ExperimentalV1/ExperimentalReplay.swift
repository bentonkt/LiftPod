import Foundation

struct RawMotionEvent: Codable, Sendable, Equatable {
    let index: UInt64
    let sourceTimestamp: Double
    let receiptUptime: Double
    let sensorLocation: String
    let userAcceleration: ExperimentalVector3
    let gravity: ExperimentalVector3
    let rotationRate: ExperimentalVector3
    let attitude: ExperimentalQuaternion
    let roll: Double
    let pitch: Double
    let yaw: Double

    init(_ sample: RawMotionSample) {
        index = sample.index
        sourceTimestamp = sample.sourceTimestamp
        receiptUptime = sample.receiptUptime
        sensorLocation = sample.sensorLocation.csvValue
        userAcceleration = .init(x: sample.userAccelerationX, y: sample.userAccelerationY, z: sample.userAccelerationZ)
        gravity = .init(x: sample.gravityX, y: sample.gravityY, z: sample.gravityZ)
        rotationRate = .init(x: sample.rotationRateX, y: sample.rotationRateY, z: sample.rotationRateZ)
        attitude = .init(w: sample.quaternionW, x: sample.quaternionX,
                         y: sample.quaternionY, z: sample.quaternionZ)
        roll = sample.roll; pitch = sample.pitch; yaw = sample.yaw
    }

    var sample: RawMotionSample {
        RawMotionSample(index: index, sourceTimestamp: sourceTimestamp, receiptUptime: receiptUptime,
                        sensorLocation: Self.location(sensorLocation),
                        userAccelerationX: userAcceleration.x, userAccelerationY: userAcceleration.y,
                        userAccelerationZ: userAcceleration.z,
                        gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z,
                        rotationRateX: rotationRate.x, rotationRateY: rotationRate.y, rotationRateZ: rotationRate.z,
                        quaternionW: attitude.w, quaternionX: attitude.x, quaternionY: attitude.y, quaternionZ: attitude.z,
                        roll: roll, pitch: pitch, yaw: yaw)
    }

    private static func location(_ text: String) -> HeadphoneSensorLocation {
        switch text {
        case HeadphoneSensorLocation.leftHeadphone.csvValue: return .leftHeadphone
        case HeadphoneSensorLocation.rightHeadphone.csvValue: return .rightHeadphone
        case HeadphoneSensorLocation.default.csvValue: return .default
        default:
            if text.hasPrefix("Unknown ("), text.hasSuffix(")"),
               let raw = Int(text.dropFirst(9).dropLast()) { return .unknown(rawValue: raw) }
            return .default
        }
    }
}

struct ReplayTransaction: Codable, Sendable, Equatable {
    let ingestSequence: Int
    let inputEvent: RawMotionEvent
    let resultingOutput: DetectionSnapshot
    let qualityState: SignalQualityState
    let detectorPhase: DetectorPhase
    let provisionalCandidateIDs: [String]
    let stableExerciseState: StableExerciseSelection
    let detectorVersion: String
    let sourceFilename: String
    let expectedSensorSide: ExperimentalSensorSide
    let configuration: ExperimentalV1Configuration
    let neutralReference: NeutralReference?
}

struct ReplayTrace: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let detectorVersion: String
    let sourceFilename: String
    let expectedSensorSide: ExperimentalSensorSide
    let selection: StableExerciseSelection
    let configuration: ExperimentalV1Configuration
    let transactions: [ReplayTransaction]

    static func decodeJSONL(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        let lines = data.split(separator: 0x0A).filter { !$0.isEmpty }
        guard let firstLine = lines.first else { throw ExperimentalV1Error.emptyInput }
        let transactions = try lines.map { try decoder.decode(ReplayTransaction.self, from: Data($0)) }
        let first = try decoder.decode(ReplayTransaction.self, from: Data(firstLine))
        return Self(schemaVersion: 1, detectorVersion: first.detectorVersion,
                    sourceFilename: first.sourceFilename, expectedSensorSide: first.expectedSensorSide,
                    selection: first.stableExerciseState, configuration: first.configuration,
                    transactions: transactions)
    }
}

struct ReplayVerificationResult: Sendable, Equatable {
    let passed: Bool
    let mismatchTransaction: Int?
    let context: String?
}

struct ExperimentalReplayVerifier: Sendable {
    func verify(_ trace: ReplayTrace) -> ReplayVerificationResult {
        var samples: [RawMotionSample] = []
        let processor = ExperimentalV1Processor()
        for transaction in trace.transactions {
            guard transaction.ingestSequence == samples.count else {
                return .init(passed: false, mismatchTransaction: transaction.ingestSequence,
                             context: "ingestSequence expected \(samples.count)")
            }
            samples.append(transaction.inputEvent.sample)
            let input = ExperimentalProcessorInput(samples: samples, sourceFilename: trace.sourceFilename,
                                                   selection: trace.selection,
                                                   expectedSensorSide: trace.expectedSensorSide,
                                                   configuration: trace.configuration)
            guard let actual = try? processor.analyze(input).snapshot else {
                return .init(passed: false, mismatchTransaction: transaction.ingestSequence,
                             context: "processor rejected transaction")
            }
            if actual.committedCount != transaction.resultingOutput.committedCount {
                return .init(passed: false, mismatchTransaction: transaction.ingestSequence,
                             context: "committedCount expected \(transaction.resultingOutput.committedCount), actual \(actual.committedCount)")
            }
            if actual.quality != transaction.resultingOutput.quality {
                return .init(passed: false, mismatchTransaction: transaction.ingestSequence,
                             context: "quality expected \(transaction.resultingOutput.quality.rawValue), actual \(actual.quality.rawValue)")
            }
            if actual != transaction.resultingOutput {
                return .init(passed: false, mismatchTransaction: transaction.ingestSequence,
                             context: "detection snapshot differs")
            }
        }
        return .init(passed: true, mismatchTransaction: nil, context: nil)
    }
}

struct ExperimentalExportURLs: Sendable, Equatable {
    let summary: URL
    let replayTrace: URL
}

struct ExperimentalV1Exporter: Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("ExperimentalV1", isDirectory: true)
    }

    func export(summary: ExperimentalAnalysisResult, trace: ReplayTrace) throws -> ExperimentalExportURLs {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "experimental-v1-\(Self.utcTimestamp())-\(UUID().uuidString)"
        let summaryURL = directory.appendingPathComponent(base + "-summary.json")
        let traceURL = directory.appendingPathComponent(base + "-replay.jsonl")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let summaryData = try encoder.encode(summary)
        let lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let traceData = Data(try trace.transactions.map {
            String(decoding: try lineEncoder.encode($0), as: UTF8.self)
        }.joined(separator: "\n").appending("\n").utf8)
        try publish(summaryData, to: summaryURL)
        do { try publish(traceData, to: traceURL) }
        catch { try? FileManager.default.removeItem(at: summaryURL); throw error }
        return ExperimentalExportURLs(summary: summaryURL, replayTrace: traceURL)
    }

    private func publish(_ data: Data, to finalURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: finalURL.path) else { throw CocoaError(.fileWriteFileExists) }
        let temporary = finalURL.appendingPathExtension("partial")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize(); try handle.close()
            try FileManager.default.moveItem(at: temporary, to: finalURL)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    private static func utcTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}

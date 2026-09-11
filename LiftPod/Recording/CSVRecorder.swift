import Foundation

enum CSVRecorderError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already active."
        case .notRecording: "No recording is active."
        }
    }
}
struct CompletedRecording: Sendable, Equatable {
    let url: URL
    let sampleCount: Int
}

protocol MotionRecording: Sendable {
    func start() async throws
    func append(_ sample: RawMotionSample) async throws -> Int
    func stop() async throws -> CompletedRecording?
}

actor CSVRecorder: MotionRecording {
    static let header = "index,source_timestamp,receipt_uptime,sensor_location,user_acceleration_x,user_acceleration_y,user_acceleration_z,gravity_x,gravity_y,gravity_z,rotation_rate_x,rotation_rate_y,rotation_rate_z,quaternion_w,quaternion_x,quaternion_y,quaternion_z,roll,pitch,yaw"

    private let directory: URL
    private let batchSize: Int
    private var fileHandle: FileHandle?
    private var temporaryURL: URL?
    private var finalURL: URL?
    private var pendingRows: [String] = []
    private var writtenCount = 0

    init(directory: URL? = nil, batchSize: Int = 256) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("RawCaptures", isDirectory: true)
        }
        self.batchSize = batchSize
    }

    func start() throws {
        guard fileHandle == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = Self.utcTimestamp()
        let baseName = "motion-\(timestamp)-\(UUID().uuidString)"
        let temporaryURL = directory.appendingPathComponent(baseName).appendingPathExtension("partial")
        let finalURL = directory.appendingPathComponent(baseName).appendingPathExtension("csv")

        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: Data((Self.header + "\n").utf8))
            self.fileHandle = handle
            self.temporaryURL = temporaryURL
            self.finalURL = finalURL
            pendingRows.removeAll(keepingCapacity: true)
            writtenCount = 0
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func append(_ sample: RawMotionSample) throws -> Int {
        guard fileHandle != nil else { throw CSVRecorderError.notRecording }
        pendingRows.append(Self.row(for: sample))
        writtenCount += 1
        if pendingRows.count >= batchSize {
            try flush()
        }
        return writtenCount
    }

    func stop() throws -> CompletedRecording? {
        guard let handle = fileHandle, let temporaryURL, let finalURL else { return nil }
        do {
            try flush()
            try handle.synchronize()
            try handle.close()
            fileHandle = nil
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            let result = CompletedRecording(url: finalURL, sampleCount: writtenCount)
            clearSession()
            return result
        } catch {
            try? handle.close()
            fileHandle = nil
            try? FileManager.default.removeItem(at: temporaryURL)
            clearSession()
            throw error
        }
    }

    private func flush() throws {
        guard !pendingRows.isEmpty, let fileHandle else { return }
        let data = Data((pendingRows.joined(separator: "\n") + "\n").utf8)
        try fileHandle.write(contentsOf: data)
        pendingRows.removeAll(keepingCapacity: true)
    }

    private func clearSession() {
        temporaryURL = nil
        finalURL = nil
        pendingRows.removeAll(keepingCapacity: true)
        writtenCount = 0
    }

    static func row(for sample: RawMotionSample) -> String {
        [
            String(sample.index),
            number(sample.sourceTimestamp),
            number(sample.receiptUptime),
            escape(sample.sensorLocation.csvValue),
            number(sample.userAccelerationX),
            number(sample.userAccelerationY),
            number(sample.userAccelerationZ),
            number(sample.gravityX),
            number(sample.gravityY),
            number(sample.gravityZ),
            number(sample.rotationRateX),
            number(sample.rotationRateY),
            number(sample.rotationRateZ),
            number(sample.quaternionW),
            number(sample.quaternionX),
            number(sample.quaternionY),
            number(sample.quaternionZ),
            number(sample.roll),
            number(sample.pitch),
            number(sample.yaw)
        ].joined(separator: ",")
    }

    static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func utcTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}

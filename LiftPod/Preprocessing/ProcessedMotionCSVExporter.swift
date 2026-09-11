import Foundation

struct ProcessedMotionCSVEncoder: Sendable {
    static let header = "index,source_timestamp,delta_time,sensor_location,gravity_magnitude_g,gyroscope_magnitude_rad_s,vertical_acceleration_raw_m_s2,vertical_acceleration_corrected_m_s2,vertical_acceleration_filtered_m_s2,is_calibration_sample"

    func encode(_ result: PreprocessingResult) -> Data {
        var output = Self.header + "\n"
        for frame in result.frames {
            output += row(for: frame) + "\n"
        }
        return Data(output.utf8)
    }

    func row(for frame: ProcessedMotionFrame) -> String {
        [
            String(frame.index),
            number(frame.sourceTimestamp),
            number(frame.deltaTime),
            CSVRecorder.escape(frame.sensorLocation.csvValue),
            number(frame.gravityMagnitudeG),
            number(frame.gyroscopeMagnitudeRadiansPerSecond),
            number(frame.verticalAccelerationRawMetersPerSecondSquared),
            number(frame.verticalAccelerationCorrectedMetersPerSecondSquared),
            number(frame.verticalAccelerationFilteredMetersPerSecondSquared),
            frame.isCalibrationSample ? "true" : "false"
        ].joined(separator: ",")
    }

    private func number(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

actor ProcessedMotionCSVExporter {
    private let directory: URL
    private let encoder: ProcessedMotionCSVEncoder

    init(directory: URL? = nil, encoder: ProcessedMotionCSVEncoder = ProcessedMotionCSVEncoder()) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("ProcessedCaptures", isDirectory: true)
        }
        self.encoder = encoder
    }

    func export(_ result: PreprocessingResult) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = "processed-motion-\(Self.utcTimestamp())-\(UUID().uuidString)"
        let temporaryURL = directory.appendingPathComponent(basename).appendingPathExtension("partial")
        let finalURL = directory.appendingPathComponent(basename).appendingPathExtension("csv")
        let data = encoder.encode(result)

        do {
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            return finalURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func utcTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}

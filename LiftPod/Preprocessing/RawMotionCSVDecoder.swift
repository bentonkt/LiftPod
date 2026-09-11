import Foundation

enum RawMotionCSVError: LocalizedError, Sendable, Equatable {
    case emptyFile
    case malformedCSV(line: Int, reason: String)
    case missingColumns([String])
    case emptyDataset
    case invalidRow(line: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            "The selected CSV file is empty."
        case let .malformedCSV(line, reason):
            "Malformed CSV at line \(line): \(reason)."
        case let .missingColumns(columns):
            "The CSV is missing required columns: \(columns.joined(separator: ", "))."
        case .emptyDataset:
            "The CSV contains a header but no motion samples."
        case let .invalidRow(line, reason):
            "Invalid CSV row at line \(line): \(reason)."
        }
    }
}

struct CSVRecord: Sendable, Equatable {
    let fields: [String]
    let line: Int
}

struct StrictCSVParser: Sendable {
    func parse(_ text: String) throws -> [CSVRecord] {
        guard !text.isEmpty else { throw RawMotionCSVError.emptyFile }

        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let characters = Array(normalizedText)
        var records: [CSVRecord] = []
        var fields: [String] = []
        var field = ""
        var index = 0
        var line = 1
        var recordStartLine = 1
        var inQuotes = false
        var closedQuote = false
        var fieldStarted = false

        func isNewline(_ character: Character) -> Bool {
            character == "\n" || character == "\r"
        }

        func finishField() {
            fields.append(field)
            field = ""
            closedQuote = false
            fieldStarted = false
        }

        func finishRecord() {
            finishField()
            records.append(CSVRecord(fields: fields, line: recordStartLine))
            fields = []
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    closedQuote = true
                } else {
                    field.append(character)
                    if character == "\n" {
                        line += 1
                    } else if character == "\r" {
                        if index + 1 < characters.count, characters[index + 1] == "\n" {
                            field.append("\n")
                            index += 1
                        }
                        line += 1
                    }
                }
                index += 1
                continue
            }

            if closedQuote {
                if character == "," {
                    finishField()
                } else if isNewline(character) {
                    finishRecord()
                    if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                        index += 1
                    }
                    line += 1
                    recordStartLine = line
                } else {
                    throw RawMotionCSVError.malformedCSV(line: line, reason: "unexpected character after a closing quote")
                }
                index += 1
                continue
            }

            if character == "," {
                finishField()
            } else if isNewline(character) {
                finishRecord()
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
                line += 1
                recordStartLine = line
            } else if character == "\"" {
                guard !fieldStarted, field.isEmpty else {
                    throw RawMotionCSVError.malformedCSV(line: line, reason: "quote found inside an unquoted field")
                }
                inQuotes = true
                fieldStarted = true
            } else {
                field.append(character)
                fieldStarted = true
            }
            index += 1
        }

        if inQuotes {
            throw RawMotionCSVError.malformedCSV(line: line, reason: "unterminated quoted field")
        }
        if !fields.isEmpty || fieldStarted || closedQuote || !field.isEmpty {
            finishRecord()
        }
        guard !records.isEmpty else { throw RawMotionCSVError.emptyFile }
        return records
    }
}

struct RawMotionCSVDecoder: Sendable {
    static let requiredColumns = CSVRecorder.header.split(separator: ",").map(String.init)

    func decode(data: Data) throws -> [RawMotionSample] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RawMotionCSVError.malformedCSV(line: 1, reason: "file is not valid UTF-8")
        }
        return try decode(text: text)
    }

    func decode(text: String) throws -> [RawMotionSample] {
        let records = try StrictCSVParser().parse(text)
        let header = records[0].fields
        var columnIndices: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            guard columnIndices[name] == nil else {
                throw RawMotionCSVError.malformedCSV(line: records[0].line, reason: "duplicate header column '\(name)'")
            }
            columnIndices[name] = index
        }
        let missing = Self.requiredColumns.filter { columnIndices[$0] == nil }
        guard missing.isEmpty else { throw RawMotionCSVError.missingColumns(missing) }
        guard records.count > 1 else { throw RawMotionCSVError.emptyDataset }

        return try records.dropFirst().map { record in
            func value(_ name: String) throws -> String {
                guard let column = columnIndices[name], column < record.fields.count else {
                    throw RawMotionCSVError.invalidRow(line: record.line, reason: "missing value for '\(name)'")
                }
                return record.fields[column]
            }

            func number(_ name: String) throws -> Double {
                let raw = try value(name)
                guard let parsed = Double(raw), parsed.isFinite else {
                    throw RawMotionCSVError.invalidRow(line: record.line, reason: "'\(name)' is not a finite number")
                }
                return parsed
            }

            let rawIndex = try value("index")
            guard let callbackIndex = UInt64(rawIndex) else {
                throw RawMotionCSVError.invalidRow(line: record.line, reason: "'index' is not a valid unsigned integer")
            }

            return RawMotionSample(
                index: callbackIndex,
                sourceTimestamp: try number("source_timestamp"),
                receiptUptime: try number("receipt_uptime"),
                sensorLocation: try sensorLocation(from: value("sensor_location"), line: record.line),
                userAccelerationX: try number("user_acceleration_x"),
                userAccelerationY: try number("user_acceleration_y"),
                userAccelerationZ: try number("user_acceleration_z"),
                gravityX: try number("gravity_x"),
                gravityY: try number("gravity_y"),
                gravityZ: try number("gravity_z"),
                rotationRateX: try number("rotation_rate_x"),
                rotationRateY: try number("rotation_rate_y"),
                rotationRateZ: try number("rotation_rate_z"),
                quaternionW: try number("quaternion_w"),
                quaternionX: try number("quaternion_x"),
                quaternionY: try number("quaternion_y"),
                quaternionZ: try number("quaternion_z"),
                roll: try number("roll"),
                pitch: try number("pitch"),
                yaw: try number("yaw")
            )
        }
    }

    private func sensorLocation(from value: String, line: Int) throws -> HeadphoneSensorLocation {
        switch value {
        case HeadphoneSensorLocation.leftHeadphone.description:
            return .leftHeadphone
        case HeadphoneSensorLocation.rightHeadphone.description:
            return .rightHeadphone
        case HeadphoneSensorLocation.default.description:
            return .default
        default:
            guard value.hasPrefix("Unknown ("), value.hasSuffix(")"),
                  let rawValue = Int(value.dropFirst(9).dropLast()) else {
                throw RawMotionCSVError.invalidRow(line: line, reason: "'sensor_location' is not recognized")
            }
            return .unknown(rawValue: rawValue)
        }
    }
}

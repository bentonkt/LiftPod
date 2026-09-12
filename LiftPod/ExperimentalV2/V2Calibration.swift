import Foundation

struct V2CalibrationDemonstration: Codable, Sendable, Equatable {
    let exercise: V2Exercise
    let sequenceNumber: Int
    let samples: [ResampledMotionSample]
    let cueStartTimestamp: Double
    let turnaroundCueTimestamp: Double
    let returnCueTimestamp: Double
    let endTimestamp: Double

    func validated(expectedSide: ExperimentalSensorSide) throws -> Self {
        guard samples.count >= 100,
              cueStartTimestamp < turnaroundCueTimestamp,
              turnaroundCueTimestamp < returnCueTimestamp,
              returnCueTimestamp < endTimestamp,
              samples.allSatisfy({ $0.sensorSide == expectedSide && $0.epoch == samples.first?.epoch }),
              samples.enumerated().dropFirst().allSatisfy({
                  abs($0.element.sourceTimestamp - samples[$0.offset - 1].sourceTimestamp - 0.02) <= 1e-9
              }),
              samples.flatMap({ V2FeatureExtractor().channels(for: $0) }).allSatisfy(\.isFinite) else {
            throw V2Error.invalidCalibration("demonstration is incomplete or discontinuous")
        }
        return self
    }
}

struct V2GuidedCalibrator: Sendable {
    func calibrate(_ demonstrations: [V2CalibrationDemonstration], cutoff: Double = 4,
                   side: ExperimentalSensorSide = .right, setupIdentifier: String) throws -> V2DSPProfile {
        guard demonstrations.count == 3,
              Set(demonstrations.map(\.sequenceNumber)).count == 3,
              let exercise = demonstrations.first?.exercise,
              demonstrations.allSatisfy({ $0.exercise == exercise }) else {
            throw V2Error.invalidCalibration("exactly three demonstrations of one exercise are required")
        }
        guard [2.0, 3, 4, 5, 6].contains(cutoff) else {
            throw V2Error.invalidCalibration("unsupported filter cutoff")
        }
        let valid = try demonstrations.map { try $0.validated(expectedSide: side) }
        guard valid.allSatisfy({ demo in
            demo.samples.contains { $0.userAcceleration.magnitude > 0.06 || $0.rotationRate.magnitude > 0.6 }
        }) else { throw V2Error.invalidCalibration("observable motion is required") }

        if exercise != .overheadPress, let gravity = coherentGravity(valid) {
            let local = V2LocalCycleConfiguration(
                startLower: -gravity.span * 0.20, startUpper: gravity.span * 0.20,
                leaveStart: gravity.span * 0.22, apexLower: gravity.span * 0.85,
                leaveApex: gravity.span * 0.70, trainedSpan: gravity.span,
                minimumOutboundExcursion: gravity.span * 0.80,
                minimumReturnExcursion: gravity.span * 0.68, minimumReturnFraction: 0.85,
                maximumPositiveBottomOffsetFraction: 0.20, maximumDeeperReturnFraction: 0.50,
                returnSettlingDuration: 0.08, gyroscopeQuietThreshold: 0.35,
                reversalDisplacementFraction: 0.02
            )
            let axis: ExperimentalAxis = [ExperimentalAxis.x, .y, .z][gravity.axis]
            let reference = V2ReferenceConfiguration(rawLower: gravity.reference - gravity.span * 0.20,
                                                     rawUpper: gravity.reference + gravity.span * 0.20)
            return try V2DSPProfile(
                profileID: "local-cycle-v2-calibrated-\(exerciseID(exercise))",
                identity: .init(profileVersion: "experimental-v2", exercise: exercise,
                                expectedSensorSide: side, setupIdentifier: setupIdentifier,
                                sampleRate: 50, signalSource: .gravity, projectionAxis: axis,
                                polarity: gravity.polarity, filter: V2DSPFilter.coefficients(cutoff: cutoff),
                                reference: reference, localCycle: local, templateConfiguration: .init(),
                                timing: .init(), positiveTemplates: [], negativeTemplates: [], kind: .localCycle),
                validationStatus: .generatedUnvalidated,
                descriptiveNotes: "Generated experimental gravity profile."
            ).validated()
        }
        return try templateProfile(valid, cutoff: cutoff, side: side, setupIdentifier: setupIdentifier)
    }

    private func coherentGravity(_ demos: [V2CalibrationDemonstration]) -> (axis: Int, polarity: Double, span: Double, reference: Double)? {
        var spansByAxis = [[Double]](repeating: [], count: 3)
        var startsByAxis = [[Double]](repeating: [], count: 3)
        for demo in demos {
            let start = demo.samples.filter { $0.sourceTimestamp <= demo.cueStartTimestamp + 0.20 }
            let top = demo.samples.filter { abs($0.sourceTimestamp - demo.turnaroundCueTimestamp) <= 0.10 }
            guard !start.isEmpty, !top.isEmpty else { return nil }
            for axis in 0..<3 {
                let first = start.map { vector($0.gravity, axis) }.reduce(0, +) / Double(start.count)
                let last = top.map { vector($0.gravity, axis) }.reduce(0, +) / Double(top.count)
                startsByAxis[axis].append(first); spansByAxis[axis].append(last - first)
            }
        }
        let medians = spansByAxis.map { V2ReferenceAcquirer.percentile($0.map(abs), 0.5) }
        guard let axis = medians.indices.max(by: { medians[$0] < medians[$1] }), medians[axis] >= 0.20 else { return nil }
        let signedMedian = V2ReferenceAcquirer.percentile(spansByAxis[axis], 0.5)
        let polarity = signedMedian >= 0 ? 1.0 : -1.0
        let span = abs(signedMedian)
        guard spansByAxis[axis].allSatisfy({ $0 * polarity > 0 && abs(abs($0) - span) <= span * 0.30 }) else { return nil }
        return (axis, polarity, span, V2ReferenceAcquirer.percentile(startsByAxis[axis], 0.5) * polarity)
    }

    private func templateProfile(_ demos: [V2CalibrationDemonstration], cutoff: Double,
                                 side: ExperimentalSensorSide, setupIdentifier: String) throws -> V2DSPProfile {
        let filter = V2DSPFilter.coefficients(cutoff: cutoff)
        let extractor = V2FeatureExtractor()
        let rawFeatures = demos.map { extractor.filtered($0.samples, coefficients: filter) }
        let all = rawFeatures.flatMap { $0 }
        let scales = (0..<10).map { channel -> Double in
            let values = all.map { $0[channel] }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            return max(channel <= 2 || channel == 9 ? 0.05 : 0.10, sqrt(variance))
        }
        let templates = zip(demos, rawFeatures).map { demo, features in
            let frames = extractor.sixtyFourFrames(features)
            let duration = demo.endTimestamp - demo.cueStartTimestamp
            func frame(_ time: Double) -> Int {
                min(63, max(0, Int(((time - demo.cueStartTimestamp) / max(duration, 1e-9) * 63).rounded())))
            }
            var marks = [0, max(1, frame((demo.cueStartTimestamp + demo.turnaroundCueTimestamp) / 2)),
                         frame(demo.turnaroundCueTimestamp), frame(demo.returnCueTimestamp), 63]
            for index in 1..<marks.count { marks[index] = max(marks[index], marks[index - 1] + 1) }
            marks[4] = 63
            return V2Template(frames: frames, landmarks: marks, duration: duration,
                              channelScales: scales, negativeSubtype: nil)
        }
        let exercise = demos[0].exercise
        return try V2DSPProfile(
            profileID: "rep-analysis-v2-template-\(exerciseID(exercise))",
            identity: .init(profileVersion: "experimental-v2", exercise: exercise,
                            expectedSensorSide: side, setupIdentifier: setupIdentifier,
                            sampleRate: 50, signalSource: .userAcceleration, projectionAxis: .y, polarity: 1,
                            filter: filter, reference: .init(), localCycle: .init(), templateConfiguration: .init(),
                            timing: .init(), positiveTemplates: templates, negativeTemplates: [], kind: .fullCycleTemplate),
            validationStatus: .generatedUnvalidated,
            descriptiveNotes: "Generated experimental full-cycle template profile."
        ).validated()
    }

    private func vector(_ value: ExperimentalVector3, _ axis: Int) -> Double { axis == 0 ? value.x : axis == 1 ? value.y : value.z }
    private func exerciseID(_ value: V2Exercise) -> String { value.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") }
}

enum V2DSPFilter {
    static func coefficients(cutoff: Double, sampleRate: Double = 50) -> BiquadConfiguration {
        if cutoff == 4, sampleRate == 50 { return .v2Fixed4Hz }
        let k = tan(.pi * cutoff / sampleRate)
        let norm = 1 / (1 + sqrt(2) * k + k * k)
        return .init(b0: k * k * norm, b1: 2 * k * k * norm, b2: k * k * norm,
                     a1: 2 * (k * k - 1) * norm, a2: (1 - sqrt(2) * k + k * k) * norm)
    }
}

actor V2ProfileStore {
    private let directory: URL
    private var activeHashes = Set<String>()

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("ExperimentalV2Profiles", isDirectory: true)
    }

    func freeze(_ profile: V2DSPProfile) { activeHashes.insert(profile.contentHash) }
    func release(_ profile: V2DSPProfile) { activeHashes.remove(profile.contentHash) }

    func save(_ profile: V2DSPProfile) throws -> URL {
        let valid = try profile.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(valid.profileID)-\(valid.contentHash).json")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let temporary = url.appendingPathExtension("partial")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(valid).write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: url)
        return url
    }

    func importProfile(_ data: Data) throws -> V2DSPProfile {
        var profile = try JSONDecoder().decode(V2DSPProfile.self, from: data)
        profile = try profile.validated()
        profile.validationStatus = .importedUnvalidated
        _ = try save(profile)
        return profile
    }

    func exportData(_ profile: V2DSPProfile) throws -> Data {
        let valid = try profile.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(valid)
    }

    func loadAll() -> [V2DSPProfile] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).compactMap {
            guard let data = try? Data(contentsOf: $0),
                  let profile = try? JSONDecoder().decode(V2DSPProfile.self, from: data),
                  let valid = try? profile.validated() else { return nil }
            return valid
        }
    }
}

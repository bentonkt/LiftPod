import Foundation

/// Model ordering is frozen independently of profile names and detector configuration.
enum ExerciseLabel: String, Codable, CaseIterable, Sendable {
    case bentOverRow = "bent_over_row", bicepsCurl = "biceps_curl", chestPress = "chest_press"
    case externalRotation = "external_rotation", gobletSquat = "goblet_squat", lateralRaise = "lateral_raise"
    case lunge, overheadPress = "overhead_press", overheadTricepsExtension = "overhead_triceps_extension", rdl
    var title: String {
        switch self {
        case .bentOverRow: "Bent Over Rows"
        case .bicepsCurl: "Biceps Curl"
        case .chestPress: "Chest Press"
        case .externalRotation: "External Rotation"
        case .gobletSquat: "Goblet Squat"
        case .lateralRaise: "Lateral Raise"
        case .lunge: "Lunge"
        case .overheadPress: "Overhead Press"
        case .overheadTricepsExtension: "Overhead Triceps Extension"
        case .rdl: "RDL"
        }
    }
}

struct ExercisePrediction: Codable, Sendable, Equatable {
    static let modelID = "b448587fb60de0574439e982a9923aa8a491d0c1e6fd228b0b005e14f26d87c2"
    static let schema = "device-frame-summary-v1"
    let captureID: UUID
    let epoch: Int
    let windowStart: Double
    let windowEnd: Double
    let completedAt: Double
    let scores: [Double]
    var modelID = Self.modelID
    var featureSchema = Self.schema
    var valid: Bool {
        scores.count == 10 && scores.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        abs(scores.reduce(0,+) - 1) < 1e-6 && windowStart.isFinite && windowEnd.isFinite &&
        completedAt.isFinite && windowEnd > windowStart && modelID == Self.modelID && featureSchema == Self.schema
    }
}

struct StableExerciseState: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case idle, warmingUp, gatheringEvidence, recognized, unknown, unavailable }
    var status: Status = .idle
    var label: ExerciseLabel?
    var manual = false
    var evidenceTime: Double?
    var lastFreshResult: Double?
    var reason = "idle"
    var policyVersion = "auto-label-policy-v1"
    var title: String {
        if manual, let label { return "Confirmed: \(label.title)" }
        switch status {
        case .idle: return "Ready"
        case .warmingUp, .gatheringEvidence: return "Detecting exercise…"
        case .recognized: return "Suggested: \(label?.title ?? "Unknown")"
        case .unknown: return "Other / not sure"
        case .unavailable: return "Signal unavailable"
        }
    }
}

struct SetExerciseAnnotation: Codable, Sendable, Equatable {
    let captureID: UUID
    var setID: String?
    var predictedLabel: ExerciseLabel?
    var confirmedLabel: ExerciseLabel?
    var state: StableExerciseState
    var correctionTime: Double?
    var modelID = ExercisePrediction.modelID
}

/// Pure state machine. Source time drives windows; injected receipt time drives watchdogs.
struct ExerciseLabelPolicy: Sendable {
    private(set) var state = StableExerciseState()
    private(set) var vectors: [[Double]] = []
    private(set) var average: [Double] = []
    private(set) var agreement = 0
    private(set) var candidate: ExerciseLabel?
    private var lastRecognized: ExerciseLabel?
    private var lastEnd: Double?
    private var firstSource: Double?
    private var startedAt = 0.0
    private var failureAt: Double?
    private var failures = 0
    private var lastReceipt: Double?
    private var expectedAt: Double?
    private var stopped = false

    mutating func start(now: Double) {
        self = Self(); startedAt = now
        state.status = .warmingUp; state.reason = "warmup"
    }
    mutating func sample(source: Double, now: Double) {
        guard !stopped else { return }
        let firstValid = firstSource == nil
        firstSource = firstSource ?? source; lastReceipt = now
        if source - (firstSource ?? source) >= 3.98 - 1e-8 { expectedAt = expectedAt ?? now }
        if !state.manual && state.label == nil && (state.status != .unavailable || firstValid) {
            state.status = source - (firstSource ?? source) >= 6 ? .unknown :
                (expectedAt == nil ? .warmingUp : .gatheringEvidence)
            state.reason = state.status == .unknown ? "insufficientAgreement" : "warmup"
        }
    }
    mutating func resetEvidence(reason: String) {
        vectors = []; average = []; agreement = 0; candidate = nil; lastEnd = nil
        failures = 0; failureAt = nil
        if !state.manual { state.label = nil; state.status = .gatheringEvidence; state.reason = reason }
    }
    mutating func discontinuity(now: Double) {
        let manual = state.manual ? state.label : nil
        start(now: now)
        if let manual { confirm(manual, now: now) } else { unavailable("staleInput") }
    }
    mutating func unavailable(_ reason: String) {
        resetEvidence(reason: reason)
        if !state.manual { state.status = .unavailable; state.reason = reason }
    }
    static func qualified(_ scores: [Double]) -> ExerciseLabel? {
        guard scores.count == 10 else { return nil }
        let order = scores.indices.sorted { scores[$0] > scores[$1] }
        guard scores[order[0]] >= 0.90, scores[order[0]] - scores[order[1]] >= 0.20 else { return nil }
        return ExerciseLabel.allCases[order[0]]
    }
    mutating func accept(_ prediction: ExercisePrediction) {
        guard !stopped else { return }
        guard prediction.valid else { unavailable("invalidPrediction"); return }
        if let lastEnd, prediction.windowEnd <= lastEnd { return }
        if let lastEnd, prediction.windowEnd - lastEnd > 0.55 { resetEvidence(reason: "predictionGap") }
        lastEnd = prediction.windowEnd
        state.lastFreshResult = prediction.completedAt
        if state.manual { return }
        vectors.append(prediction.scores); if vectors.count > 5 { vectors.removeFirst() }
        average = (0..<10).map { index in vectors.reduce(0) { $0 + $1[index] } / Double(vectors.count) }
        let winner = Self.qualified(prediction.scores)
        if winner != nil, winner == candidate { agreement += 1 }
        else { candidate = winner; agreement = winner == nil ? 0 : 1 }
        let supported = winner != nil && winner == Self.qualified(average)
        if state.label != nil && (!supported || state.label != winner) {
            failures += 1; failureAt = failureAt ?? prediction.completedAt
            if failures >= 2 { state.label = nil; state.status = .unknown }
            state.reason = winner == nil ? "ambiguousScores" : "conflictingWinner"
        } else { failures = 0; failureAt = nil }
        if supported, let winner {
            let required = lastRecognized != nil && lastRecognized != winner ? 5 : 3
            if agreement >= required && vectors.count >= 3 {
                state.label = winner; state.status = .recognized; state.reason = "agreement"
                state.evidenceTime = prediction.windowEnd; lastRecognized = winner
                failures = 0; failureAt = nil
            }
        }
        if state.label == nil && state.status != .unknown {
            state.status = prediction.windowEnd - (firstSource ?? prediction.windowStart) >= 6 ? .unknown : .gatheringEvidence
            state.reason = "insufficientAgreement"
        }
    }
    mutating func tick(now: Double) {
        guard !stopped else { return }
        if now - (lastReceipt ?? startedAt) > 0.5 { unavailable("staleInput"); return }
        if let origin = state.lastFreshResult ?? expectedAt, now - origin >= 1.5 {
            unavailable("inferenceTimeout"); return
        }
        if !state.manual, let failureAt, now - failureAt >= 0.5 {
            state.label = nil; state.status = .unknown; state.reason = "conflictingWinner"
        }
    }
    mutating func confirm(_ label: ExerciseLabel, now: Double) {
        guard !stopped else { return }
        resetEvidence(reason: "manualOverride")
        state.label = label; state.manual = true; state.status = .recognized
        state.reason = "manualOverride"; state.evidenceTime = now
    }
    mutating func finish() { stopped = true }
}

enum ClassifierError: Error { case invalidInput, invalidModel }

/// Float64 training-compatible features. Filter state belongs to the continuous epoch, not a window.
struct ExerciseFeatures: Sendable {
    private var d1 = [Double](repeating: 0, count: 9)
    private var d2 = [Double](repeating: 0, count: 9)
    private var initialized = false
    mutating func filter(_ x: [Double]) throws -> [Double] {
        guard x.count == 9, x.allSatisfy(\.isFinite) else { throw ClassifierError.invalidInput }
        let b = [0.04613180209331292, 0.09226360418662584, 0.04613180209331292]
        let a = [-1.3072850288493234, 0.49181223722257517]
        let gain = b.reduce(0,+) / (1 + a.reduce(0,+))
        var y = x
        for i in 0..<9 {
            if !initialized {
                y[i] = x[i] * gain; d1[i] = y[i] - b[0] * x[i]; d2[i] = b[2] * x[i] - a[1] * y[i]
            } else {
                y[i] = b[0] * x[i] + d1[i]
                d1[i] = b[1] * x[i] - a[0] * y[i] + d2[i]
                d2[i] = b[2] * x[i] - a[1] * y[i]
            }
        }
        initialized = true; return y
    }
    private static let hann = (0..<200).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 199) }
    private static let cosines = (0...100).map { k in (0..<200).map { cos(2 * Double.pi * Double(k * $0) / 200) } }
    private static let sines = (0...100).map { k in (0..<200).map { sin(2 * Double.pi * Double(k * $0) / 200) } }
    static func extract(_ window: [[Double]]) throws -> [Double] {
        guard window.count == 200, window.allSatisfy({ $0.count == 9 && $0.allSatisfy(\.isFinite) }) else {
            throw ClassifierError.invalidInput
        }
        var channels = (0..<9).map { j in window.map { $0[j] } }
        channels.append(window.map { sqrt($0[0]*$0[0] + $0[1]*$0[1] + $0[2]*$0[2]) })
        channels.append(window.map { sqrt($0[3]*$0[3] + $0[4]*$0[4] + $0[5]*$0[5]) })
        let gravity = window.map { sqrt($0[6]*$0[6] + $0[7]*$0[7] + $0[8]*$0[8]) }
        guard gravity.allSatisfy({ $0 >= 0.5 }) else { throw ClassifierError.invalidInput }
        channels.append(window.enumerated().map { i, x in -(x[0]*x[6] + x[1]*x[7] + x[2]*x[8]) / gravity[i] })
        let means = channels.map { $0.reduce(0,+) / 200 }
        let centered = channels.enumerated().map { i, v in v.map { $0 - means[i] } }
        var result: [Double] = []
        func percentile(_ sorted: [Double], _ q: Double) -> Double {
            let p = 199 * q; let i = Int(p); return sorted[i] + (sorted[min(i+1,199)] - sorted[i]) * (p - Double(i))
        }
        for i in channels.indices {
            let v = channels[i], sorted = v.sorted()
            result += [means[i], sqrt(centered[i].reduce(0) { $0 + $1*$1 } / 200),
                       sqrt(v.reduce(0) { $0 + $1*$1 } / 200), sorted[0], sorted[199],
                       percentile(sorted,0.75) - percentile(sorted,0.25)]
        }
        for base in [0,3,6] {
            for (i,j) in [(0,1),(0,2),(1,2)] {
                let a = centered[base+i], b = centered[base+j]
                let denom = sqrt(a.reduce(0) { $0+$1*$1 }) * sqrt(b.reduce(0) { $0+$1*$1 })
                result.append(denom > 1e-10 ? zip(a,b).reduce(0) { $0+$1.0*$1.1 } / denom : 0)
            }
        }
        for i in [0,1,2,3,4,5,9,10,11] {
            let v = centered[i], weighted = zip(v,hann).map(*)
            let power = (0...100).map { k -> Double in
                var real = 0.0, imaginary = 0.0
                for n in 0..<200 { real += weighted[n] * cosines[k][n]; imaginary += weighted[n] * sines[k][n] }
                return real*real + imaginary*imaginary
            }
            let total = power.dropFirst().reduce(0,+)
            for (low,high) in [(1,3),(3,6),(6,12),(12,32)] {
                result.append(total > 1e-12 ? power[low..<high].reduce(0,+) / total : 0)
            }
            let zero = v.reduce(0) { $0+$1*$1 }
            var maximum = -Double.infinity
            for lag in 13...100 {
                var sum = 0.0
                for n in 0..<(200-lag) { sum += v[n] * v[n+lag] }
                maximum = max(maximum,sum)
            }
            result.append(zero > 1e-12 ? maximum / zero : 0)
        }
        guard result.count == 126, result.allSatisfy(\.isFinite) else { throw ClassifierError.invalidInput }
        return result
    }
}

struct PortableExerciseModel: Codable, Sendable {
    let type: String
    let labels: [String]
    let mean: [Double]
    let scale: [Double]
    let coefficients: [[Double]]
    let intercept: [Double]
    func validated() throws -> Self {
        guard type == "standardized_multinomial_logistic", labels == ExerciseLabel.allCases.map(\.rawValue),
              mean.count == 126, scale.count == 126, coefficients.count == 10, intercept.count == 10,
              mean.allSatisfy(\.isFinite), scale.allSatisfy({ $0.isFinite && $0 > 0 }),
              coefficients.allSatisfy({ $0.count == 126 && $0.allSatisfy(\.isFinite) }), intercept.allSatisfy(\.isFinite)
        else { throw ClassifierError.invalidModel }
        return self
    }
    func predict(_ features: [Double]) throws -> [Double] {
        guard features.count == 126, features.allSatisfy(\.isFinite) else { throw ClassifierError.invalidInput }
        let x = (0..<126).map { (features[$0] - mean[$0]) / scale[$0] }
        let logits = (0..<10).map { j in zip(x,coefficients[j]).reduce(intercept[j]) { $0 + $1.0*$1.1 } }
        guard let maximum = logits.max(), maximum.isFinite else { throw ClassifierError.invalidInput }
        let exps = logits.map { exp($0 - maximum) }, total = exps.reduce(0,+)
        let scores = exps.map { $0 / total }
        guard scores.allSatisfy(\.isFinite) else { throw ClassifierError.invalidInput }
        return scores
    }
}

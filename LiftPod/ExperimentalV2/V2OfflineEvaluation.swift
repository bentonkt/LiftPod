import Foundation

enum V2TrialSplit: String, Codable, Sendable, CaseIterable { case fit, validation, evaluation }
enum V2AnnotationCompleteness: String, Codable, Sendable { case complete, incomplete, abandoned }

struct V2TrialAnnotation: Codable, Sendable, Equatable {
    let completionTimestamp: Double
    let completeness: V2AnnotationCompleteness
    let negativeSubtype: String?
}

struct V2EvaluationTrial: Codable, Sendable, Equatable {
    let trialID: String
    let participantPseudonym: String
    let setupSessionID: String
    let split: V2TrialSplit
    let exercise: V2Exercise
    let inputs: [RawMotionEvent]
    let annotations: [V2TrialAnnotation]
    let negativeExampleDuration: Double
    let transitionScript: Bool
    let cadenceGroup: String?
}

struct V2ProfileCandidateConfiguration: Codable, Sendable, Equatable {
    let maximumDTWCost: Double
    let minimumNegativeMargin: Double
    let cutoff: Double
    let warpingBandFraction: Double
    let phaseEvidenceRatio: Double
}

struct V2ConfidenceInterval: Codable, Sendable, Equatable { let lower: Double; let upper: Double }

struct V2EvaluationMetrics: Codable, Sendable, Equatable {
    let truePositives: Int; let falsePositives: Int; let falseNegatives: Int
    let precision: Double; let recall: Double; let f1: Double
    let meanAbsoluteCountError: Double; let exactCountTrialRate: Double
    let doubleCounts: Int; let partialOrAbandonedTriggers: Int; let transitionFalseReps: Int
    let negativeEventRatePerMinute: Double; let firstRepRecall: Double; let lastRepRecall: Double
    let meanDetectionLatency: Double; let trialCount: Int; let annotationCount: Int
    let precisionInterval: V2ConfidenceInterval; let recallInterval: V2ConfidenceInterval
    let negativeSubtypeBreakdown: [String: Int]
}

struct V2OfflineEvaluator: Sendable {
    func validateTrials(_ trials: [V2EvaluationTrial], trainingTrialIDs: Set<String> = []) throws {
        let ids = trials.map(\.trialID)
        guard Set(ids).count == ids.count else { throw V2Error.invalidCalibration("duplicate trial IDs") }
        let setupGroups = Dictionary(grouping: trials, by: \.setupSessionID)
        guard setupGroups.values.allSatisfy({ Set($0.map(\.split)).count == 1 }) else {
            throw V2Error.invalidCalibration("setup session split leakage")
        }
        let byID = Dictionary(uniqueKeysWithValues: trials.map { ($0.trialID, $0) })
        guard trainingTrialIDs.allSatisfy({ byID[$0]?.split == .fit }) else {
            throw V2Error.invalidCalibration("training data must come only from fitting trials")
        }
        let fitting = trials.filter { $0.split == .fit }
        guard ["normal", "slow", "fast"].allSatisfy({ group in fitting.contains { $0.cadenceGroup == group } }) else {
            throw V2Error.invalidCalibration("missing cadence groups")
        }
        guard fitting.contains(where: { $0.negativeExampleDuration > 0 || $0.annotations.contains { $0.completeness != .complete } }) else {
            throw V2Error.invalidCalibration("missing negative examples")
        }
    }

    func candidateGrid() -> [V2ProfileCandidateConfiguration] {
        [2.0, 3, 4, 5, 6].flatMap { cutoff in
            [0.05, 0.10, 0.20, 0.40].flatMap { cost in
                [0.05, 0.10, 0.20].map { margin in
                    .init(maximumDTWCost: cost, minimumNegativeMargin: margin, cutoff: cutoff,
                          warpingBandFraction: 0.20, phaseEvidenceRatio: 0.85)
                }
            }
        }
    }

    func medoidIndex(_ examples: [[[Double]]]) -> Int? {
        guard !examples.isEmpty else { return nil }
        var scores = Array(repeating: 0.0, count: examples.count)
        for left in examples.indices {
            let leftValues = examples[left].flatMap { $0 }
            for right in examples.indices {
                let rightValues = examples[right].flatMap { $0 }
                for index in 0..<min(leftValues.count, rightValues.count) {
                    let delta = leftValues[index] - rightValues[index]
                    scores[left] += delta * delta
                }
            }
        }
        var best = 0
        for index in scores.indices.dropFirst() where scores[index] < scores[best] { best = index }
        return best
    }

    func select(validationScores: [(profile: V2DSPProfile, metrics: V2EvaluationMetrics)],
                eligible: (V2DSPProfile, V2EvaluationMetrics) -> Bool) -> V2DSPProfile? {
        let candidates = validationScores.filter { eligible($0.profile, $0.metrics) }
        guard let best = candidates.map(\.metrics.f1).max() else { return nil }
        return candidates.filter { best - $0.metrics.f1 <= 0.005 }.sorted {
            complexity($0.profile) == complexity($1.profile)
                ? $0.profile.contentHash < $1.profile.contentHash
                : complexity($0.profile) < complexity($1.profile)
        }.first?.profile
    }

    func metrics(trials: [V2EvaluationTrial], candidates: [String: [V2CycleEvidence]],
                 tolerance: Double = 0.40) -> V2EvaluationMetrics {
        var tp = 0, fp = 0, fn = 0, partial = 0, transitions = 0, doubles = 0
        var exact = 0, totalError = 0.0, negativeDuration = 0.0
        var firstHits = 0, firstTotal = 0, lastHits = 0, lastTotal = 0
        var latencies: [Double] = [], subtype: [String: Int] = [:]
        for trial in trials {
            let complete = trial.annotations.filter { $0.completeness == .complete }.sorted { $0.completionTimestamp < $1.completionTimestamp }
            let incomplete = trial.annotations.filter { $0.completeness != .complete }
            let detected = (candidates[trial.trialID] ?? []).filter(\.committed).sorted { $0.completionTimestamp < $1.completionTimestamp }
            let matches = optimalMatches(detected.map(\.completionTimestamp), complete.map(\.completionTimestamp), tolerance: tolerance)
            tp += matches.count; fp += detected.count - matches.count; fn += complete.count - matches.count
            totalError += Double(abs(detected.count - complete.count)); if detected.count == complete.count { exact += 1 }
            doubles += max(0, detected.count - Set(matches.map(\.1)).count - incomplete.count)
            for match in matches { latencies.append(detected[match.0].detectionTimestamp - complete[match.1].completionTimestamp) }
            if !complete.isEmpty {
                firstTotal += 1; lastTotal += 1
                if matches.contains(where: { $0.1 == 0 }) { firstHits += 1 }
                if matches.contains(where: { $0.1 == complete.count - 1 }) { lastHits += 1 }
            }
            for candidate in detected where incomplete.contains(where: { abs($0.completionTimestamp - candidate.completionTimestamp) <= tolerance }) {
                partial += 1
                let name = incomplete.min(by: { abs($0.completionTimestamp - candidate.completionTimestamp) < abs($1.completionTimestamp - candidate.completionTimestamp) })?.negativeSubtype ?? "unspecified"
                subtype[name, default: 0] += 1
            }
            if trial.transitionScript { transitions += detected.count }
            negativeDuration += max(0, trial.negativeExampleDuration)
        }
        let precision = ratio(tp, tp + fp), recall = ratio(tp, tp + fn)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        return .init(truePositives: tp, falsePositives: fp, falseNegatives: fn,
                     precision: precision, recall: recall, f1: f1,
                     meanAbsoluteCountError: ratio(totalError, Double(trials.count)),
                     exactCountTrialRate: ratio(exact, trials.count), doubleCounts: doubles,
                     partialOrAbandonedTriggers: partial, transitionFalseReps: transitions,
                     negativeEventRatePerMinute: negativeDuration == 0 ? 0 : Double(fp) / (negativeDuration / 60),
                     firstRepRecall: ratio(firstHits, firstTotal), lastRepRecall: ratio(lastHits, lastTotal),
                     meanDetectionLatency: latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count),
                     trialCount: trials.count, annotationCount: trials.flatMap(\.annotations).count,
                     precisionInterval: wilson(successes: tp, total: tp + fp),
                     recallInterval: wilson(successes: tp, total: tp + fn), negativeSubtypeBreakdown: subtype)
    }

    private func optimalMatches(_ candidates: [Double], _ annotations: [Double], tolerance: Double) -> [(Int, Int)] {
        struct State { var count = 0; var error = 0.0; var pairs: [(Int, Int)] = [] }
        var dp = Array(repeating: Array(repeating: State(), count: annotations.count + 1), count: candidates.count + 1)
        func better(_ left: State, _ right: State) -> State {
            left.count != right.count ? (left.count > right.count ? left : right) : (left.error <= right.error ? left : right)
        }
        for i in 0...candidates.count { for j in 0...annotations.count where i > 0 || j > 0 {
            var best = i > 0 ? dp[i - 1][j] : dp[i][j - 1]
            if j > 0 { best = better(best, dp[i][j - 1]) }
            if i > 0, j > 0 {
                let error = abs(candidates[i - 1] - annotations[j - 1])
                if error <= tolerance {
                    var matched = dp[i - 1][j - 1]; matched.count += 1; matched.error += error
                    matched.pairs.append((i - 1, j - 1)); best = better(best, matched)
                }
            }
            dp[i][j] = best
        }}
        return dp[candidates.count][annotations.count].pairs
    }

    private func complexity(_ profile: V2DSPProfile) -> Int { profile.identity.kind == .localCycle ? 0 : 2 }
    private func ratio(_ numerator: Int, _ denominator: Int) -> Double { denominator == 0 ? 0 : Double(numerator) / Double(denominator) }
    private func ratio(_ numerator: Double, _ denominator: Double) -> Double { denominator == 0 ? 0 : numerator / denominator }
    private func wilson(successes: Int, total: Int) -> V2ConfidenceInterval {
        guard total > 0 else { return .init(lower: 0, upper: 0) }
        let z = 1.959963984540054, n = Double(total), p = Double(successes) / n
        let center = (p + z * z / (2 * n)) / (1 + z * z / n)
        let margin = z * sqrt((p * (1 - p) + z * z / (4 * n)) / n) / (1 + z * z / n)
        return .init(lower: max(0, center - margin), upper: min(1, center + margin))
    }
}

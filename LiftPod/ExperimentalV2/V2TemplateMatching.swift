import Foundation

struct V2FeatureExtractor: Sendable {
    static let channelCount = 10

    func channels(for sample: ResampledMotionSample) -> [Double] {
        let gravityNorm = max(sample.gravity.magnitude, 1e-9)
        let physicalUp = -(sample.userAcceleration.x * sample.gravity.x +
                           sample.userAcceleration.y * sample.gravity.y +
                           sample.userAcceleration.z * sample.gravity.z) / gravityNorm
        return [sample.userAcceleration.x, sample.userAcceleration.y, sample.userAcceleration.z,
                sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z,
                sample.gravity.x, sample.gravity.y, sample.gravity.z, physicalUp]
    }

    func filtered(_ samples: [ResampledMotionSample], coefficients: BiquadConfiguration) -> [[Double]] {
        var filters = (0..<Self.channelCount).map { _ in ScalarBiquadFilter(coefficients: coefficients) }
        return samples.map { sample in
            channels(for: sample).enumerated().map { index, value in filters[index].process(value) }
        }
    }

    func sixtyFourFrames(_ input: [[Double]]) -> [[Double]] {
        guard !input.isEmpty else { return [] }
        if input.count == 1 { return Array(repeating: input[0], count: 64) }
        return (0..<64).map { frame in
            let position = Double(frame) * Double(input.count - 1) / 63
            let lower = Int(position.rounded(.down)); let upper = min(input.count - 1, lower + 1)
            let fraction = position - Double(lower)
            return (0..<Self.channelCount).map {
                input[lower][$0] + (input[upper][$0] - input[lower][$0]) * fraction
            }
        }
    }
}

struct V2DTWResult: Sendable, Equatable {
    let cost: Double
    let path: [(Int, Int)]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.cost == rhs.cost && lhs.path.elementsEqual(rhs.path, by: ==) }
}

struct V2DynamicTimeWarping: Sendable {
    private struct Cell { var cost = Double.infinity; var length = 0; var previous: (Int, Int)? }

    func compare(candidate: [[Double]], template: [[Double]], scales: [Double], bandFraction: Double) -> V2DTWResult? {
        guard candidate.count == 64, template.count == 64, scales.count == 10 else { return nil }
        let band = min(12, Int(floor(64 * bandFraction)))
        var cells = Array(repeating: Array(repeating: Cell(), count: 64), count: 64)
        for row in 0..<64 {
            for column in max(0, row - band)...min(63, row + band) {
                let distance = zip(zip(candidate[row], template[column]), scales).reduce(0.0) {
                    let delta = ($1.0.0 - $1.0.1) / max($1.1, 1e-12)
                    return $0 + delta * delta
                } / 10
                if row == 0, column == 0 {
                    cells[row][column] = Cell(cost: distance, length: 1, previous: nil)
                    continue
                }
                // Ordering is the deterministic tie-break: diagonal, vertical, horizontal.
                let predecessors = [(row - 1, column - 1), (row - 1, column), (row, column - 1)]
                    .filter { $0.0 >= 0 && $0.1 >= 0 && cells[$0.0][$0.1].cost.isFinite }
                guard let selected = predecessors.min(by: {
                    let left = cells[$0.0][$0.1].cost
                    let right = cells[$1.0][$1.1].cost
                    return left < right
                }) else { continue }
                let previous = cells[selected.0][selected.1]
                cells[row][column] = Cell(cost: previous.cost + distance,
                                          length: previous.length + 1, previous: selected)
            }
        }
        let final = cells[63][63]
        guard final.cost.isFinite, final.length > 0 else { return nil }
        var path: [(Int, Int)] = []; var cursor: (Int, Int)? = (63, 63)
        while let point = cursor { path.append(point); cursor = cells[point.0][point.1].previous }
        return V2DTWResult(cost: final.cost / Double(final.length), path: path.reversed())
    }
}

struct V2TemplateMatch: Sendable, Equatable {
    let accepted: Bool
    let positiveCost: Double
    let nearestNegativeCost: Double?
    let mappedLandmarks: [Int]
    let rejectionReason: V2RejectionReason?
}

struct V2FullCycleTemplateMatcher: Sendable {
    let profile: V2DSPProfile

    func evaluate(samples: [ResampledMotionSample]) -> V2TemplateMatch {
        let identity = profile.identity
        let extractor = V2FeatureExtractor()
        let candidate = extractor.sixtyFourFrames(extractor.filtered(samples, coefficients: identity.filter))
        guard candidate.count == 64 else { return rejected(.ambiguousTemplate) }
        let dtw = V2DynamicTimeWarping()
        let positiveResults = identity.positiveTemplates.compactMap { template in
            dtw.compare(candidate: candidate, template: template.frames, scales: template.channelScales,
                        bandFraction: identity.templateConfiguration.warpingBandFraction).map { (template, $0) }
        }
        guard let best = positiveResults.min(by: { $0.1.cost < $1.1.cost }) else { return rejected(.ambiguousTemplate) }
        let negativeCost = identity.negativeTemplates.compactMap {
            dtw.compare(candidate: candidate, template: $0.frames, scales: $0.channelScales,
                        bandFraction: identity.templateConfiguration.warpingBandFraction)?.cost
        }.min()
        let mapped = best.0.landmarks.map { landmark in
            best.1.path.filter { $0.1 == landmark }.map(\.0).min() ?? landmark
        }
        let config = identity.templateConfiguration
        let startCost = frameDistance(candidate[0], best.0.frames[0], scales: best.0.channelScales)
        let endCost = frameDistance(candidate[63], best.0.frames[63], scales: best.0.channelScales)
        let duration = (samples.last?.sourceTimestamp ?? 0) - (samples.first?.sourceTimestamp ?? 0)
        let mappedTime = mapped.map { duration * Double($0) / 63 }
        let rejection: V2RejectionReason?
        if best.1.cost > config.maximumCost { rejection = .templateCost }
        else if let negativeCost, negativeCost - best.1.cost < config.minimumNegativeMargin { rejection = .negativeMargin }
        else if startCost > config.endpointLimit || endCost > config.endpointLimit { rejection = .endpointMismatch }
        else if !zip(mapped, mapped.dropFirst()).allSatisfy({ $0 < $1 }) { rejection = .invalidOrdering }
        else if mappedTime.count != 5 ||
                    mappedTime[2] - mappedTime[0] < identity.timing.minimumPhaseDuration ||
                    mappedTime[4] - mappedTime[2] < identity.timing.minimumPhaseDuration ||
                    mappedTime[3] - mappedTime[1] > identity.timing.maximumTurnaroundPause {
            rejection = .invalidDuration
        }
        else if !phaseEvidence(candidate: candidate, template: best.0) { rejection = .phaseEvidence }
        else { rejection = nil }
        return .init(accepted: rejection == nil, positiveCost: best.1.cost,
                     nearestNegativeCost: negativeCost, mappedLandmarks: mapped, rejectionReason: rejection)
    }

    private func phaseEvidence(candidate: [[Double]], template: V2Template) -> Bool {
        let ratio = profile.identity.templateConfiguration.phaseEvidenceRatio
        let legs = [(template.landmarks[0], template.landmarks[2]),
                    (template.landmarks[2], template.landmarks[4])]
        for (start, end) in legs {
            for channel in 0..<10 {
                let base = template.frames[start][channel]
                let deltas = (start...end).map { template.frames[$0][channel] - base }
                guard let signedPeak = deltas.max(by: { abs($0) < abs($1) }) else { continue }
                let scale = template.channelScales[channel]
                guard abs(signedPeak) / scale >= 0.25 else { continue }
                let sign = signedPeak >= 0 ? 1.0 : -1.0
                let templateValues = (start...end).map { max(0, sign * (template.frames[$0][channel] - base)) }
                let candidateBase = candidate[start][channel]
                let candidateValues = (start...end).map { max(0, sign * (candidate[$0][channel] - candidateBase)) }
                guard candidateValues.max() ?? 0 >= (templateValues.max() ?? 0) * ratio,
                      candidateValues.reduce(0, +) / Double(end - start + 1) >=
                        templateValues.reduce(0, +) / Double(end - start + 1) * ratio else { return false }
            }
        }
        return true
    }

    private func frameDistance(_ left: [Double], _ right: [Double], scales: [Double]) -> Double {
        zip(zip(left, right), scales).reduce(0.0) {
            let delta = ($1.0.0 - $1.0.1) / max($1.1, 1e-12)
            return $0 + delta * delta
        } / 10
    }

    private func rejected(_ reason: V2RejectionReason) -> V2TemplateMatch {
        .init(accepted: false, positiveCost: .infinity, nearestNegativeCost: nil,
              mappedLandmarks: [], rejectionReason: reason)
    }
}

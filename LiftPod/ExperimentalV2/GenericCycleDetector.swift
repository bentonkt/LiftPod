import Foundation

enum GenericPatternMath {
    static func normalized(_ input: [GenericMotionFrame]) -> [[Double]] {
        guard input.count > 1 else { return [] }
        return (0..<64).map { i in
            let p = Double(i) * Double(input.count - 1) / 63
            let lo = Int(p), hi = min(input.count - 1, lo + 1), f = p - Double(lo)
            return (0..<9).map { input[lo].features[$0] * (1-f) + input[hi].features[$0] * f }
        }
    }

    static func pattern(_ frames: [GenericMotionFrame], config: GenericRepConfiguration,
                        epoch: Int, frozenAt: Double, learnedFrom: [Double]) -> GenericPattern? {
        let values = normalized(frames)
        guard values.count == 64, let first = frames.first, let last = frames.last else { return nil }
        let means = (0..<9).map { c in values.reduce(0) { $0 + $1[c] } / 64 }
        let variances = (0..<9).map { c in values.reduce(0) { $0 + pow($1[c] - means[c], 2) } / 64 }
        let rms = (0..<3).map { g in sqrt(variances[(g*3)..<(g*3+3)].reduce(0,+) / 3) }
        let active = (0..<3).map { rms[$0] >= config.noiseFloors[$0] }
        guard active.contains(true), frames.filter(\.moving).count >= frames.count / 4 else { return nil }
        return .init(frames: values, scales: (0..<3).map { max(rms[$0], config.noiseFloors[$0]) },
                     activeGroups: active, duration: last.time-first.time, sourceEpoch: first.sample.epoch,
                     learningEpoch: epoch, learnedFrom: learnedFrom, frozenAt: frozenAt)
    }

    static func distance(_ a: [Double], _ b: [Double], pattern: GenericPattern) -> Double {
        var sum = 0.0, groups = 0.0
        for g in 0..<3 where pattern.activeGroups[g] {
            var d = 0.0
            for c in (g*3)..<(g*3+3) { d += pow((a[c]-b[c])/pattern.scales[g], 2) }
            let weight = pattern.groupWeights?[g] ?? 1
            sum += weight * d / 3; groups += weight
        }
        return sum / max(1e-9, groups)
    }

    /// Independent generic score: one ordered path, no magnitude folding or
    /// per-candidate amplitude normalization. Every template frame is visited.
    static func cost(_ values: [[Double]], pattern: GenericPattern) -> Double {
        guard values.count == 64 else { return .infinity }
        var previous = Array(repeating: Double.infinity, count: 65)
        previous[0] = 0
        for i in 0..<64 {
            var next = Array(repeating: Double.infinity, count: 65)
            for j in max(0,i-16)...min(63,i+16) {
                next[j+1] = distance(values[i], pattern.frames[j], pattern: pattern) +
                    min(previous[j], min(previous[j+1], next[j]))
            }
            previous = next
        }
        return previous[64] / 64
    }
}

struct GenericTraversal: Sendable {
    let start: Double
    let completion: Double
    let detected: Double
    let cost: Double
}

/// Ephemeral evidence metadata. Keeping it outside recorded session types
/// preserves every legacy replay encoding and hash.
struct GenericTraversalProgress: Equatable, Sendable {
    let lineage: UInt64
    let start: Double
    let observedAt: Double
    let meaningfulSections: Int
}

/// Streaming DTW with explicit hold/unmatched states. A cell owns a contiguous
/// traversal. Horizontal advances pay for ALL intervening template frames.
struct GenericPatternTracker: Sendable {
    private struct Cell: Sendable {
        var cost: Double
        var weight: Int
        var start: Double
        var samples: Int
        var coverage: UInt64
        var lineage: UInt64
        var node: UInt64
        var parent: UInt64?
    }
    let pattern: GenericPattern
    let config: GenericRepConfiguration
    private var cells = Array<Cell?>(repeating: nil, count: 64)
    private var pending: GenericTraversal?
    private var pendingDistance = Double.infinity
    private var worseFrames = 0
    private var quietSince: Double?
    private var unmatchedSince: Double?
    private var lastCompletion = -Double.infinity
    private var nextLineage: UInt64 = 0
    private var nextNode: UInt64 = 0
    private var selectedNode: UInt64?
    private(set) var phase: Int?
    private(set) var state: GenericTrackingState = .unmatched
    private(set) var progress: GenericTraversalProgress?

    init(pattern: GenericPattern, config: GenericRepConfiguration) {
        self.pattern = pattern; self.config = config
    }

    mutating func observe(_ frame: GenericMotionFrame, departureAllowed: Bool) -> GenericTraversal? {
        let t = frame.time
        let endpoint = GenericPatternMath.distance(frame.features, pattern.frames[63], pattern: pattern)
        if let p = pending {
            if endpoint < pendingDistance {
                pending = .init(start: p.start, completion: t, detected: t, cost: p.cost)
                pendingDistance = endpoint; worseFrames = 0
            } else { worseFrames += 1 }
            if worseFrames >= 3 || t - p.completion >= 0.12 {
                let result = pending!
                pending = nil; cells = Array(repeating: nil, count: 64)
                lastCompletion = result.completion; phase = nil
                selectedNode = nil
                progress = nil
                if departureAllowed { seed(frame) }
                return .init(start: result.start, completion: result.completion, detected: t, cost: result.cost)
            }
        }
        if !frame.moving {
            quietSince = quietSince ?? t
            // A quiet frame cannot advance through an unseen moving section.
            if phase != nil, t - quietSince! <= config.maximumPause { state = .holding; return nil }
        } else { quietSince = nil }
        let distances = pattern.frames.map { GenericPatternMath.distance(frame.features, $0, pattern: pattern) }
        var next = Array<Cell?>(repeating: nil, count: 64)
        for j in 0..<64 {
            var best: Cell?
            for step in 0...min(3,j) {
                guard var old = cells[j-step], t-old.start <= config.maximumCycleDuration else { continue }
                var increment = 0.0
                for k in (j-step)...j {
                    increment += distances[k]
                    if config.version == "generic-pattern-v1" || distances[k] <= config.maximumMatchCost * 3 {
                        old.coverage |= UInt64(1) << k
                    }
                }
                old.cost += increment; old.weight += step+1; old.samples += 1
                if best == nil || old.cost / Double(old.weight) < best!.cost / Double(best!.weight) { best = old }
            }
            if var best, best.cost / Double(best.weight) <= config.maximumMatchCost * 3 {
                best.parent = best.node
                nextNode &+= 1
                best.node = nextNode
                next[j] = best
            }
        }
        cells = next
        if departureAllowed, pending == nil, t >= lastCompletion, distances[0] <= config.maximumEndpointCost {
            // Keep an earlier coherent start rather than repeatedly resetting it.
            if cells[0] == nil { seed(frame) }
        }
        let viable = cells.indices.filter { cells[$0] != nil && distances[$0] <= config.maximumMatchCost * 4 }
        phase = viable.min {
            let a = cells[$0]!, b = cells[$1]!
            return a.cost / Double(a.weight) < b.cost / Double(b.weight)
        }
        if let phase, var cell = cells[phase], frame.moving {
            if let selectedNode, cell.parent != selectedNode {
                nextLineage &+= 1
                cell.lineage = nextLineage
                cells[phase] = cell
            }
            selectedNode = cell.node
            var sections = 0
            for section in 0..<8 {
                let range = (section * 8)..<(section * 8 + 8)
                let visited = range.contains { cell.coverage & (UInt64(1) << $0) != 0 }
                let dynamic = range.contains { index in
                    index > 0 && GenericPatternMath.distance(pattern.frames[index], pattern.frames[index - 1], pattern: pattern) > 0.01
                }
                if visited && dynamic { sections += 1 }
            }
            if sections > 0 {
                progress = .init(lineage: cell.lineage, start: cell.start,
                                 observedAt: t, meaningfulSections: sections)
            }
        }
        if phase != nil {
            unmatchedSince = nil; state = .tracking
        } else {
            progress = nil
            selectedNode = nil
            unmatchedSince = unmatchedSince ?? t; state = .unmatched
            if t-unmatchedSince! >= config.unmatchedDuration {
                cells = Array(repeating: nil, count: 64); phase = nil; pending = nil
            }
        }
        if pending == nil, let end = cells[63], end.coverage == UInt64.max,
           t-end.start >= max(config.minimumCycleDuration, pattern.duration * (config.version == "generic-pattern-v2" ? 0.75 : 0.55)),
           end.cost / Double(end.weight) <= config.maximumMatchCost,
           endpoint <= config.maximumEndpointCost {
            pending = .init(start: end.start, completion: t, detected: t, cost: end.cost / Double(end.weight))
            pendingDistance = endpoint; worseFrames = 0
        }
        return nil
    }

    private mutating func seed(_ frame: GenericMotionFrame) {
        nextLineage &+= 1
        nextNode &+= 1
        cells[0] = .init(cost: GenericPatternMath.distance(frame.features, pattern.frames[0], pattern: pattern),
                         weight: 1, start: frame.time, samples: 1, coverage: 1,
                         lineage: nextLineage, node: nextNode, parent: nil)
    }
}

struct GenericLearningDecision: Codable, Equatable, Sendable {
    let timestamp: Double
    let kind: String
    let learningEpoch: Int
    let pattern: GenericPattern?
}

/// Pure bounded discovery. The session owns append-only history and replays it
/// through install/backfill once a pattern freezes, before admitting live input.
struct GenericCycleDetector: Sendable {
    private struct Trial: Sendable {
        let pattern: GenericPattern
        let firstTwoCost: Double
        let thirdStart: Double
        var tracker: GenericPatternTracker
        var validated: GenericTraversal?
    }
    let setID: UUID
    let configuration: GenericRepConfiguration
    private var history: [GenericMotionFrame] = []
    private var trials: [Trial] = []
    private var lastDiscovery = -Double.infinity
    private var searchStart: Double?
    private var lastAccepted = -Double.infinity
    private(set) var learningEpoch = 0
    private(set) var epochStart: Double?
    private(set) var pattern: GenericPattern?
    private var tracker: GenericPatternTracker?
    private(set) var latestDecision: GenericLearningDecision?
    private(set) var state: GenericTrackingState = .learning
    var phase: Int? { tracker?.phase }
    var progress: GenericTraversalProgress? { tracker?.progress }
    var candidateCount: Int { trials.isEmpty ? 0 : 2 }
    var retainedFrameCount: Int { history.count }

    init(setID: UUID, configuration: GenericRepConfiguration) {
        self.setID = setID; self.configuration = configuration
    }

    mutating func discontinuity(at time: Double) {
        history.removeAll(); trials.removeAll(); tracker = nil; pattern = nil
        learningEpoch += 1; epochStart = time; searchStart = time
        lastAccepted = time; state = .recovering; latestDecision = .init(timestamp: time, kind: "sourceDiscontinuity", learningEpoch: learningEpoch, pattern: nil)
    }

    mutating func boundary(at time: Double) {
        history.removeAll(); trials.removeAll(); searchStart = time
        epochStart = time; lastAccepted = time
        tracker = pattern.map { .init(pattern: $0, config: configuration) }
        state = pattern == nil ? .learning : .unmatched
        latestDecision = .init(timestamp: time, kind: "ownershipBoundary", learningEpoch: learningEpoch, pattern: nil)
    }

    mutating func observe(_ frame: GenericMotionFrame, departureAllowed: Bool) -> GenericTraversal? {
        latestDecision = nil; epochStart = epochStart ?? frame.time
        history.append(frame)
        let cutoff = frame.time - configuration.historyDuration
        history.removeAll { $0.time < cutoff }
        var emitted: GenericTraversal?
        if tracker != nil {
            emitted = tracker?.observe(frame, departureAllowed: departureAllowed)
            state = tracker?.state ?? .learning
            if let emitted {
                lastAccepted = emitted.completion; trials.removeAll(); searchStart = emitted.completion
            }
        }
        if frame.moving, departureAllowed { searchStart = searchStart ?? frame.time }
        for i in trials.indices where trials[i].validated == nil {
            if let result = trials[i].tracker.observe(frame, departureAllowed: departureAllowed),
               result.start >= trials[i].thirdStart - 0.20,
               configuration.version == "generic-pattern-v1" || result.start <= trials[i].thirdStart + 0.20 {
                trials[i].validated = result
            }
        }
        let trialDeadline = configuration.maximumCycleDuration + 0.4
        // Ambiguous validated hypotheses must also expire; otherwise four old
        // alternatives can occupy the pool forever after the movement changes.
        trials.removeAll { frame.time - $0.thirdStart > trialDeadline }
        let validated = trials.filter { $0.validated != nil }.sorted {
            if abs($0.pattern.duration - $1.pattern.duration) > 0.15 { return $0.pattern.duration < $1.pattern.duration }
            return $0.firstTwoCost + $0.validated!.cost < $1.firstTwoCost + $1.validated!.cost
        }
        if let winner = validated.first {
            let competing = validated.dropFirst().contains {
                let ratio = $0.pattern.duration / winner.pattern.duration
                // Exact multiples represent the same primitive signed sequence.
                let harmonic = abs(ratio - ratio.rounded()) < 0.12
                return !harmonic && ratio > 1.3 &&
                    abs($0.validated!.cost - winner.validated!.cost) < configuration.ambiguityMargin
            }
            if !competing {
                let p = winner.pattern
                // Mere amplitude/tempo changes are not evidence of a new pattern.
                let structurallyNew = pattern.map { structuralCost(p, $0) > configuration.maximumMatchCost * 2 } ?? true
                if structurallyNew {
                    if pattern != nil { learningEpoch += 1; epochStart = p.learnedFrom.first }
                    let frozen = GenericPattern(frames: p.frames, scales: p.scales, activeGroups: p.activeGroups,
                        duration: p.duration, sourceEpoch: p.sourceEpoch, learningEpoch: learningEpoch,
                        learnedFrom: p.learnedFrom + [winner.validated!.completion], frozenAt: frame.time,
                        groupWeights: p.groupWeights)
                    pattern = frozen; tracker = .init(pattern: frozen, config: configuration)
                    state = .tracking; trials.removeAll()
                    latestDecision = .init(timestamp: frame.time, kind: "templateFrozen", learningEpoch: learningEpoch, pattern: frozen)
                    return nil // Session backfill now supplies the complete ordered ledger.
                }
                trials.removeAll()
            }
        }
        if departureAllowed, frame.time-lastDiscovery >= configuration.discoveryInterval - 1e-9,
           pattern == nil || frame.time-lastAccepted > (pattern?.duration ?? 0) * 1.5 {
            lastDiscovery = frame.time
            discover(at: frame.time)
        }
        return emitted
    }

    /// Install a fresh tracker before chronological history replay. This does
    /// not run learning again and cannot edit a previously authorized event.
    mutating func beginBackfill() {
        if let pattern { tracker = .init(pattern: pattern, config: configuration) }
    }
    mutating func backfill(_ frame: GenericMotionFrame, departureAllowed: Bool) -> GenericTraversal? {
        let value = tracker?.observe(frame, departureAllowed: departureAllowed)
        if let value { lastAccepted = value.completion; searchStart = value.completion }
        return value
    }

    private func structuralCost(_ a: GenericPattern, _ b: GenericPattern) -> Double {
        // Compare normalized shapes only for change detection, never counting.
        // This prevents a common scalar amplitude change from relearning.
        var values = a.frames
        for g in 0..<3 {
            for c in g*3..<(g*3+3) {
                let am = a.frames.reduce(0) { $0+$1[c] } / 64
                let bm = b.frames.reduce(0) { $0+$1[c] } / 64
                for i in 0..<64 { values[i][c] = bm + (values[i][c]-am)*b.scales[g]/a.scales[g] }
            }
        }
        return GenericPatternMath.cost(values, pattern: b)
    }

    /// Locally centered recurrence: quiet tails cannot correlate merely because
    /// they share an offset from an earlier moving window's mean.
    private func recurrence(_ a: [GenericMotionFrame], _ b: [GenericMotionFrame], group: Int) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for c in group*3..<(group*3+3) {
            let am = a.reduce(0) { $0 + $1.features[c] } / Double(a.count)
            let bm = b.reduce(0) { $0 + $1.features[c] } / Double(b.count)
            for i in a.indices {
                let av = a[i].features[c]-am, bv = b[i].features[c]-bm
                dot += av*bv; aa += av*av; bb += bv*bv
            }
        }
        let floor = configuration.noiseFloors[group]
        guard min(aa,bb) / Double(a.count*3) >= floor*floor else { return -1 }
        return dot / max(1e-9,sqrt(aa*bb))
    }

    private func repeatablePair(_ a: [GenericMotionFrame], _ b: [GenericMotionFrame], at time: Double) -> (GenericPattern, Double)? {
        guard var pa = GenericPatternMath.pattern(a, config: configuration, epoch: learningEpoch,
                frozenAt: time, learnedFrom: [a[0].time,b[0].time,b.last!.time]),
              var pb = GenericPatternMath.pattern(b, config: configuration, epoch: learningEpoch,
                frozenAt: time, learnedFrom: [a[0].time,b[0].time,b.last!.time]) else { return nil }
        var weights = [Double](repeating: 0, count: 3)
        for g in 0..<3 where pa.activeGroups[g] && pb.activeGroups[g] {
            var one = [Double](repeating: 0, count: 3); one[g] = 1
            pa.groupWeights = one; pb.groupWeights = one
            let error = max(GenericPatternMath.cost(pb.frames, pattern: pa), GenericPatternMath.cost(pa.frames, pattern: pb))
            // Agreement is measured without candidate amplitude normalization.
            // All supported groups subsequently share ONE ordered alignment.
            weights[g] = max(0, 1-error/configuration.maximumMatchCost)
        }
        guard weights.max() ?? 0 > 0 else { return nil }
        pa.groupWeights = weights; pb.groupWeights = weights
        let ab = GenericPatternMath.cost(pb.frames, pattern: pa)
        let ba = GenericPatternMath.cost(pa.frames, pattern: pb)
        guard max(ab,ba) <= configuration.maximumMatchCost else { return nil }
        let chosen = ab <= ba ? pa : pb
        guard GenericPatternMath.distance(chosen.frames[0], chosen.frames[63], pattern: chosen) <= configuration.maximumEndpointCost else { return nil }
        return (chosen,min(ab,ba))
    }

    private mutating func discoverRolling(at time: Double) {
        guard trials.count < 4 else { return }
        let owned = history.filter { $0.time >= max(epochStart ?? 0, searchStart ?? 0) }
        let sparse = stride(from: 0, to: owned.count, by: 5).map { owned[$0] }
        let maxLag = min(80,(sparse.count-1)/2)
        guard maxLag >= 7 else { return }
        var scores: [(lag: Int, value: Double)] = []
        for lag in 7...maxLag {
            let end = sparse.count-1, middle = end-lag, start = middle-lag
            let a = Array(sparse[start..<middle]), b = Array(sparse[middle..<end])
            let score = (0..<3).map { recurrence(a,b,group:$0) }.max() ?? -1
            scores.append((lag,score))
        }
        let peaks = scores.indices.filter { i in
            scores[i].value >= configuration.minimumCorrelation &&
            (i == 0 || scores[i].value > scores[i-1].value) &&
            (i == scores.count-1 ? scores[i].lag == 80 : scores[i].value >= scores[i+1].value)
        }.sorted {
            if scores[$0].value == scores[$1].value { return scores[$0].lag < scores[$1].lag }
            return scores[$0].value > scores[$1].value
        }
        // At most two periods × three split refinements per discovery tick.
        // Rolling endpoints naturally examine new phase offsets every 200 ms.
        for index in peaks.prefix(2) {
            let length = scores[index].lag*5
            let end = owned.count-1, start = end-2*length
            guard start >= 0 else { continue }
            if trials.contains(where: { abs($0.pattern.duration-Double(length)/50) < 0.15 }) { continue }
            var best: (GenericPattern,Double)?
            for offset in [0,-5,5] {
                let middle = end-length+offset
                guard middle-start >= 35, end-middle >= 35,
                      middle-start <= 400, end-middle <= 400 else { continue }
                if let candidate = repeatablePair(Array(owned[start...middle]),Array(owned[middle...end]),at:time),
                   best == nil || candidate.1 < best!.1 { best = candidate }
            }
            guard let (pattern,cost) = best else { continue }
            var trial = Trial(pattern:pattern,firstTwoCost:cost,thirdStart:time,
                tracker:.init(pattern:pattern,config:configuration))
            // Freeze before observing the third cycle. Never select a favorable
            // historical third snippet to validate a newly fitted pair.
            _ = trial.tracker.observe(owned[end],departureAllowed:true)
            trials.append(trial)
            if trials.count >= 4 { break }
        }
    }

    private mutating func discover(at time: Double) {
        if configuration.version == "generic-pattern-v2" {
            discoverRolling(at: time)
            return
        }
        guard trials.count < 4 else { return }
        let owned = history.filter { $0.time >= max(epochStart ?? 0, searchStart ?? 0) }
        // 10 Hz discovery; full 50 Hz frames are used for alignment/tracking.
        let sparse = stride(from: 0, to: owned.count, by: 5).map { owned[$0] }
        guard sparse.count >= 15 else { return }
        let maxLag = min(80, (sparse.count-1)/2)
        guard maxLag >= 7 else { return }
        guard let context = GenericPatternMath.pattern(owned, config: configuration, epoch: learningEpoch,
                                                      frozenAt: time, learnedFrom: []) else { return }
        var scores: [(lag: Int, score: Double)] = []
        for lag in 7...maxLag {
            let length = min(sparse.count-lag, lag*2)
            let start = sparse.count-length-lag
            var dot = 0.0, aa = 0.0, bb = 0.0
            for c in 0..<9 where context.activeGroups[c/3] {
                let mean = sparse.reduce(0) { $0+$1.features[c] } / Double(sparse.count)
                for i in 0..<length {
                    let a = (sparse[start+i].features[c]-mean)/context.scales[c/3]
                    let b = (sparse[start+i+lag].features[c]-mean)/context.scales[c/3]
                    dot += a*b; aa += a*a; bb += b*b
                }
            }
            scores.append((lag, dot / max(1e-9,sqrt(aa*bb))))
        }
        let peaks = scores.indices.filter { i in
            scores[i].score >= configuration.minimumCorrelation &&
            (i == 0 || scores[i].score > scores[i-1].score) &&
            (i == scores.count-1 || scores[i].score >= scores[i+1].score)
        }.sorted { scores[$0].score > scores[$1].score }
        for index in peaks.prefix(4) {
            let period = Double(scores[index].lag) * 0.1
            if trials.contains(where: { abs($0.pattern.duration-period) < 0.15 }) { continue }
            // The first two complete periods precede the validation interval.
            let start = owned[0].time
            let split = start+period, end = split+period
            guard end <= time + 0.021 else { continue }
            let a = owned.filter { $0.time >= start && $0.time <= split+0.001 }
            let b = owned.filter { $0.time >= split && $0.time <= end+0.001 }
            guard let pa = GenericPatternMath.pattern(a, config: configuration, epoch: learningEpoch,
                    frozenAt: time, learnedFrom: [start,split,end]),
                  let pb = GenericPatternMath.pattern(b, config: configuration, epoch: learningEpoch,
                    frozenAt: time, learnedFrom: [start,split,end]) else { continue }
            let ab = GenericPatternMath.cost(pb.frames, pattern: pa)
            let ba = GenericPatternMath.cost(pa.frames, pattern: pb)
            guard max(ab,ba) <= configuration.maximumMatchCost else { continue }
            let chosen = ab <= ba ? pa : pb
            var trial = Trial(pattern: chosen, firstTwoCost: min(ab,ba), thirdStart: end,
                              tracker: .init(pattern: chosen, config: configuration))
            // Only observations after the two training intervals validate a trial.
            for frame in owned where frame.time >= end {
                if let result = trial.tracker.observe(frame, departureAllowed: true) { trial.validated = result }
            }
            trials.append(trial)
            if trials.count >= 4 { break }
        }
        // Handling before a repeatable pattern must not poison learning forever.
        if trials.isEmpty, owned.count > 800 { searchStart = owned[0].time + 0.20 }
    }
}

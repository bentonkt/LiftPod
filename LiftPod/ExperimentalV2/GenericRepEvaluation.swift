import Foundation
import simd

/// Offline reporting only. Annotation timestamps must be independently supplied;
/// development detector outputs must be explicitly labeled as proxy references.
struct GenericRepEvaluation: Codable, Equatable, Sendable {
    let predictedCount: Int
    let referenceCount: Int
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int
    let exactCount: Bool
    let firstRecovered: Bool
    let lastRecovered: Bool
    let meanAuthorizationDelay: Double?
    let learningDelay: Double?
    let physicalBoundaryFraction: Double
    let pcaAutocorrelationCount: Int

    static func measure(events: [GenericCycleEvent], completions: [Double], samples: [ResampledMotionSample],
                        tolerance: Double = 0.35) -> Self {
        let expected = completions.sorted(), actual = events.sorted { $0.completionTimestamp < $1.completionTimestamp }
        var used: Set<Int> = [], matched: Set<Int> = []
        for (i,event) in actual.enumerated() {
            let candidates = expected.indices.filter { !used.contains($0) && abs(expected[$0]-event.completionTimestamp) <= tolerance }
            if let best = candidates.min(by: { abs(expected[$0]-event.completionTimestamp) < abs(expected[$1]-event.completionTimestamp) }) {
                used.insert(best); matched.insert(i)
            }
        }
        let delays = actual.map { $0.authorizationTimestamp-$0.completionTimestamp }
        return .init(predictedCount:actual.count,referenceCount:expected.count,truePositives:matched.count,
            falsePositives:actual.count-matched.count,falseNegatives:expected.count-matched.count,
            exactCount:actual.count == expected.count,firstRecovered:!expected.isEmpty && used.contains(0),
            lastRecovered:!expected.isEmpty && used.contains(expected.count-1),
            meanAuthorizationDelay:delays.isEmpty ? nil : delays.reduce(0,+)/Double(delays.count),
            learningDelay:actual.first.flatMap { event in samples.first.map { event.authorizationTimestamp-$0.sourceTimestamp } },
            physicalBoundaryFraction:actual.isEmpty ? 0 : Double(actual.filter { $0.turnaroundTimestamp != nil }.count)/Double(actual.count),
            pcaAutocorrelationCount:baseline(samples))
    }

    /// Untuned comparison baseline: filtered acceleration PC1, autocorrelation
    /// period, and signed local maxima separated by half that period. Its peaks
    /// do not claim to be physical completion boundaries.
    static func baseline(_ samples: [ResampledMotionSample]) -> Int {
        guard samples.count >= 105 else { return 0 }
        var feature = GenericFeaturePipeline()
        let vectors: [SIMD3<Double>] = samples.compactMap { sample in
            guard let f = feature.observe(sample) else { return nil }
            return .init(f.features[0],f.features[1],f.features[2])
        }
        guard vectors.count == samples.count else { return 0 }
        let mean = vectors.reduce(.zero,+)/Double(vectors.count)
        let centered = vectors.map { $0-mean }
        var axis = SIMD3<Double>(1,0.7,0.3)
        for _ in 0..<24 {
            let next = centered.reduce(SIMD3<Double>.zero) { $0+$1*simd_dot($1,axis) }
            guard simd_length(next) > 1e-9 else { return 0 }
            axis = simd_normalize(next)
        }
        let signal = centered.map { simd_dot($0,axis) }
        let maximum = signal.max() ?? 0
        guard maximum > 0.025 else { return 0 }
        var bestLag = 35, bestCorrelation = -1.0
        for lag in 35...min(400,signal.count/3) {
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in lag..<signal.count {
                ab += signal[i]*signal[i-lag]; aa += signal[i]*signal[i]; bb += signal[i-lag]*signal[i-lag]
            }
            let correlation = ab/max(1e-9,sqrt(aa*bb))
            if correlation > bestCorrelation { bestCorrelation = correlation; bestLag = lag }
        }
        guard bestCorrelation >= 0.65 else { return 0 }
        var selected: [Int] = []
        for i in 1..<(signal.count-1) where signal[i] > maximum*0.25 && signal[i] > signal[i-1] && signal[i] >= signal[i+1] {
            if let previous = selected.last, i-previous < bestLag/2 {
                if signal[i] > signal[previous] { selected[selected.count-1] = i }
            } else { selected.append(i) }
        }
        return selected.count
    }
}

import Foundation
import simd

/// Optional physical evidence, evaluated AFTER pattern authorization. Constant
/// orientation translations intentionally have no inferred physical turnaround.
enum GenericPhysicalPhases {
    struct Evidence {
        let turnaround: Double
        let outwardEnd: Double
        let returnStart: Double
        let pause: Double?
    }

    static func identify(_ frames: [GenericMotionFrame]) -> Evidence? {
        guard frames.count >= 35, let first = frames.first, let last = frames.last,
              V6VectorMath.angularDistance(first.sample.gravity,last.sample.gravity) <= 0.15 else { return nil }
        let rates = frames.compactMap { DevicePathMath.world($0.sample.rotationRate, attitude: $0.sample.attitude) }
        guard rates.count == frames.count else { return nil }
        // Fixed deterministic principal axis, used only to interpret a counted
        // interval. It cannot authorize or reject its pattern event.
        var axis = SIMD3<Double>(1,0.7,0.3)
        for _ in 0..<24 {
            let next = rates.reduce(SIMD3<Double>.zero) { $0 + $1 * simd_dot($1,axis) }
            guard simd_length(next) > 1e-9 else { return nil }
            axis = simd_normalize(next)
        }
        let total = rates.reduce(0.0) { $0 + simd_length_squared($1) }
        let along = rates.reduce(0.0) { $0 + pow(simd_dot($1,axis),2) }
        guard total > 0.1, along/total >= 0.80 else { return nil }
        var signed = rates.map { simd_dot($0,axis) }
        guard let firstMoving = signed.first(where: { abs($0) > 0.15 }) else { return nil }
        if firstMoving < 0 { signed = signed.map { -$0 } }
        let peak = signed.map(abs).max() ?? 0
        // A cycle starting halfway through an angular leg cannot supply honest
        // outward/return metrics just because it covers one waveform period.
        guard abs(signed[0]) <= max(0.15,peak*0.25),
              abs(signed.last!) <= max(0.15,peak*0.25) else { return nil }
        let positive = signed.indices.filter { signed[$0] > 0.15 }
        let negative = signed.indices.filter { signed[$0] < -0.15 }
        guard let p0 = positive.first, let p1 = positive.last,
              let n0 = negative.first, let n1 = negative.last,
              p1 < n0, frames[p1].time-frames[p0].time >= 0.20,
              frames[n1].time-frames[n0].time >= 0.20,
              let farthest = frames.indices.max(by: {
                  V6VectorMath.angularDistance(first.sample.gravity,frames[$0].sample.gravity) <
                  V6VectorMath.angularDistance(first.sample.gravity,frames[$1].sample.gravity)
              }), farthest >= p1, farthest <= n0,
              V6VectorMath.angularDistance(first.sample.gravity,frames[farthest].sample.gravity) >= 0.20 else { return nil }
        let quiet = frames[p1...n0].allSatisfy {
            $0.sample.rotationRate.magnitude <= 0.35 && $0.sample.userAcceleration.magnitude <= 0.025
        }
        let duration = frames[n0].time-frames[p1].time
        return .init(turnaround:frames[farthest].time,outwardEnd:frames[p1].time,returnStart:frames[n0].time,
                     pause:quiet && duration >= 0.20 ? duration : nil)
    }
}

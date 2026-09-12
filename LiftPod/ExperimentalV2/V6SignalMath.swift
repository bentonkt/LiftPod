import Foundation

enum V6VectorMath {
    static func dot(_ a: ExperimentalVector3, _ b: ExperimentalVector3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    static func scale(_ value: ExperimentalVector3, _ scalar: Double) -> ExperimentalVector3 {
        .init(x: value.x * scalar, y: value.y * scalar, z: value.z * scalar)
    }

    static func add(_ a: ExperimentalVector3, _ b: ExperimentalVector3) -> ExperimentalVector3 {
        .init(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    static func unit(_ value: ExperimentalVector3) -> ExperimentalVector3? {
        let magnitude = value.magnitude
        guard magnitude.isFinite, magnitude > 1e-9 else { return nil }
        return scale(value, 1 / magnitude)
    }

    static func angularDistance(_ a: ExperimentalVector3, _ b: ExperimentalVector3) -> Double {
        guard let left = unit(a), let right = unit(b) else { return .infinity }
        return acos(min(1, max(-1, dot(left, right))))
    }

    static func mean(_ values: [ExperimentalVector3]) -> ExperimentalVector3 {
        scale(values.reduce(.init(x: 0, y: 0, z: 0), add), 1 / Double(max(1, values.count)))
    }

    static func gravityPlaneAngle(
        from start: ExperimentalVector3,
        to current: ExperimentalVector3,
        axis: ExperimentalVector3
    ) -> Double? {
        guard let normal = unit(axis) else { return nil }
        func projected(_ value: ExperimentalVector3) -> ExperimentalVector3 {
            add(value, scale(normal, -dot(value, normal)))
        }
        let a = projected(start), b = projected(current)
        guard dot(a, a) > 1e-8, dot(b, b) > 1e-8 else { return nil }
        let cross = ExperimentalVector3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
        return atan2(dot(cross, normal), dot(a, b))
    }

    static func planarMagnitude(_ value: ExperimentalVector3, axis: ExperimentalVector3) -> Double {
        guard let normal = unit(axis) else { return 0 }
        let component = dot(value, normal)
        return sqrt(max(0, dot(value, value) - component * component))
    }
}
struct V6ContinuousAngle: Sendable {
    private(set) var previous: Double?
    private(set) var value = 0.0

    mutating func observe(_ wrapped: Double, maximumDelta: Double) -> Double? {
        guard wrapped.isFinite else { return nil }
        guard let previous else {
            self.previous = wrapped
            value = wrapped
            return value
        }
        let delta = atan2(sin(wrapped - previous), cos(wrapped - previous))
        guard abs(delta) <= maximumDelta else { return nil }
        value += delta
        self.previous = wrapped
        return value
    }
}

struct V6AxisEstimate: Sendable, Equatable {
    let axis: ExperimentalVector3
    let energyFraction: Double
    let coherence: Double
    let travel: Double
}

enum V6AxisEstimator {
    static func estimate(_ samples: [ResampledMotionSample], sampleRate: Double) -> V6AxisEstimate? {
        let observable = samples.map { sample -> ExperimentalVector3 in
            guard let gravity = V6VectorMath.unit(sample.gravity) else { return sample.rotationRate }
            return V6VectorMath.add(
                sample.rotationRate,
                V6VectorMath.scale(gravity, -V6VectorMath.dot(sample.rotationRate, gravity))
            )
        }
        let total = observable.reduce(0) { $0 + V6VectorMath.dot($1, $1) }
        let length = observable.reduce(0) { $0 + $1.magnitude }
        let signedSum = observable.reduce(.init(x: 0, y: 0, z: 0), V6VectorMath.add)
        guard total > 1e-9, length > 1e-9, var axis = V6VectorMath.unit(signedSum) else { return nil }
        for _ in 0..<24 {
            let product = observable.reduce(ExperimentalVector3(x: 0, y: 0, z: 0)) {
                V6VectorMath.add($0, V6VectorMath.scale($1, V6VectorMath.dot($1, axis)))
            }
            guard let next = V6VectorMath.unit(product) else { return nil }
            axis = next
        }
        if V6VectorMath.dot(axis, signedSum) < 0 { axis = V6VectorMath.scale(axis, -1) }
        let along = observable.reduce(0) { $0 + pow(V6VectorMath.dot($1, axis), 2) }
        return .init(axis: axis, energyFraction: along / total,
                     coherence: signedSum.magnitude / length, travel: length / sampleRate)
    }
}

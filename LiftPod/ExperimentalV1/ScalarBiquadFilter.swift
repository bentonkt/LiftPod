import Foundation

struct ScalarBiquadFilter: Sendable {
    let coefficients: BiquadConfiguration
    private(set) var delay1 = 0.0
    private(set) var delay2 = 0.0
    private(set) var initialized = false

    init(coefficients: BiquadConfiguration = .v1) {
        self.coefficients = coefficients
    }

    mutating func process(_ input: Double) -> Double {
        guard initialized else {
            let dcGain = (coefficients.b0 + coefficients.b1 + coefficients.b2) /
                (1 + coefficients.a1 + coefficients.a2)
            let output = input * dcGain
            delay1 = output - coefficients.b0 * input
            delay2 = coefficients.b2 * input - coefficients.a2 * output
            initialized = true
            return output
        }
        let output = coefficients.b0 * input + delay1
        delay1 = coefficients.b1 * input - coefficients.a1 * output + delay2
        delay2 = coefficients.b2 * input - coefficients.a2 * output
        return output
    }

    mutating func reset() {
        delay1 = 0
        delay2 = 0
        initialized = false
    }
}

import Foundation

struct SignalQualityTracker: Sendable {
    let configuration: ExperimentalV1Configuration
    let expectedSide: ExperimentalSensorSide
    private(set) var state: SignalQualityState = .warmingUp
    private(set) var epoch = 0
    private(set) var transitions: [QualityTransition] = []
    private var previousSourceTime: Double?
    private var previousReceiptTime: Double?
    private var recoveryStart: Double?

    init(configuration: ExperimentalV1Configuration = .init(), expectedSide: ExperimentalSensorSide = .right) {
        self.configuration = configuration
        self.expectedSide = expectedSide
    }

    mutating func observe(_ sample: RawMotionSample) {
        guard sample.sourceTimestamp.isFinite, sample.receiptUptime.isFinite else {
            breakStream(.invalidInput, at: previousSourceTime ?? 0, reason: "Non-finite timestamp")
            return
        }
        if let previousSourceTime {
            let sourceGap = sample.sourceTimestamp - previousSourceTime
            if abs(sourceGap) <= configuration.comparisonEpsilon { return }
            if sourceGap < 0 {
                breakStream(.invalidInput, at: sample.sourceTimestamp, reason: "Backward source timestamp")
                self.previousSourceTime = sample.sourceTimestamp
                self.previousReceiptTime = sample.receiptUptime
                return
            }
            if sourceGap > configuration.maximumInterpolationGap + configuration.comparisonEpsilon {
                let quality: SignalQualityState = sourceGap > configuration.degradedGapThreshold ? .degraded : .invalidInput
                breakStream(quality, at: sample.sourceTimestamp, reason: "Source-time discontinuity")
            }
        }
        if let previousReceiptTime,
           sample.receiptUptime - previousReceiptTime > configuration.receiptStalenessThreshold {
            breakStream(.stale, at: sample.sourceTimestamp, reason: "Receipt stream became stale")
        }
        guard expectedSide.matches(sample.sensorLocation) else {
            breakStream(.wrongSensorSide, at: sample.sourceTimestamp, reason: "Unexpected sensor side")
            previousSourceTime = sample.sourceTimestamp; previousReceiptTime = sample.receiptUptime
            return
        }
        recoveryStart = recoveryStart ?? sample.sourceTimestamp
        if sample.sourceTimestamp - (recoveryStart ?? sample.sourceTimestamp) >= configuration.recoveryDuration {
            transition(.usable, at: sample.sourceTimestamp, reason: "Valid stream recovery completed")
        }
        previousSourceTime = sample.sourceTimestamp
        previousReceiptTime = sample.receiptUptime
    }

    mutating func disconnect(at sourceTimestamp: Double) {
        breakStream(.disconnected, at: sourceTimestamp, reason: "Stream disconnected")
    }

    mutating func reset() {
        state = .warmingUp; epoch = 0; transitions = []
        previousSourceTime = nil; previousReceiptTime = nil; recoveryStart = nil
    }

    private mutating func breakStream(_ newState: SignalQualityState, at time: Double, reason: String) {
        epoch += 1; recoveryStart = nil; transition(newState, at: time, reason: reason)
    }

    private mutating func transition(_ newState: SignalQualityState, at time: Double, reason: String) {
        guard state != newState else { return }
        state = newState
        transitions.append(QualityTransition(sourceTimestamp: time, state: newState, reason: reason))
    }
}

import Foundation
@testable import LiftPod

final class MockMotionProvider: MotionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MotionProviderEvent>.Continuation?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var activeStreamCount = 0

    var authorizationState: MotionPermissionState = .authorized
    var isMotionAvailable = true
    var connectionUpdatesActive = false
    var motionUpdatesActive = false

    func makeEventStream() -> AsyncStream<MotionProviderEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock {
                self.continuation = continuation
                self.activeStreamCount += 1
            }
        }
    }

    func start() {
        lock.withLock {
            guard !motionUpdatesActive else { return }
            startCallCount += 1
            connectionUpdatesActive = true
            motionUpdatesActive = true
        }
    }

    func stop() {
        lock.withLock {
            guard motionUpdatesActive || connectionUpdatesActive else { return }
            stopCallCount += 1
            connectionUpdatesActive = false
            motionUpdatesActive = false
        }
    }

    func emit(_ event: MotionProviderEvent) {
        lock.withLock { continuation }?.yield(event)
    }
}
actor MockRecorder: MotionRecording {
    var shouldFailStart = false
    var shouldFailAppend = false
    var shouldFailStop = false
    private(set) var samples: [RawMotionSample] = []
    private(set) var active = false
    let completedURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("complete.csv")

    func configure(failStart: Bool = false, failAppend: Bool = false, failStop: Bool = false) {
        shouldFailStart = failStart
        shouldFailAppend = failAppend
        shouldFailStop = failStop
    }

    func start() throws {
        if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
        guard !active else { return }
        active = true
        samples = []
    }

    func append(_ sample: RawMotionSample) throws -> Int {
        if shouldFailAppend { throw CocoaError(.fileWriteUnknown) }
        guard active else { throw CSVRecorderError.notRecording }
        samples.append(sample)
        return samples.count
    }

    func stop() throws -> CompletedRecording? {
        guard active else { return nil }
        active = false
        if shouldFailStop { throw CocoaError(.fileWriteUnknown) }
        return CompletedRecording(url: completedURL, sampleCount: samples.count)
    }
}

func makeSample(index: UInt64 = 1, receiptUptime: Double = 10) -> RawMotionSample {
    RawMotionSample(
        index: index,
        sourceTimestamp: 1.2345678901234567,
        receiptUptime: receiptUptime,
        sensorLocation: .leftHeadphone,
        userAccelerationX: 0.1,
        userAccelerationY: -0.2,
        userAccelerationZ: 0.3,
        gravityX: 0.01,
        gravityY: 0.02,
        gravityZ: 0.99,
        rotationRateX: -1.1,
        rotationRateY: 2.2,
        rotationRateZ: -3.3,
        quaternionW: 0.9,
        quaternionX: 0.1,
        quaternionY: 0.2,
        quaternionZ: 0.3,
        roll: 0.4,
        pitch: -0.5,
        yaw: 0.6
    )
}

func syntheticSample(
    index: UInt64,
    timestamp: Double,
    gravity: (Double, Double, Double) = (0, 0, -1),
    userAcceleration: (Double, Double, Double) = (0, 0, 0),
    rotationRate: (Double, Double, Double) = (0, 0, 0),
    sensorLocation: HeadphoneSensorLocation = .leftHeadphone
) -> RawMotionSample {
    RawMotionSample(
        index: index,
        sourceTimestamp: timestamp,
        receiptUptime: timestamp + 100,
        sensorLocation: sensorLocation,
        userAccelerationX: userAcceleration.0,
        userAccelerationY: userAcceleration.1,
        userAccelerationZ: userAcceleration.2,
        gravityX: gravity.0,
        gravityY: gravity.1,
        gravityZ: gravity.2,
        rotationRateX: rotationRate.0,
        rotationRateY: rotationRate.1,
        rotationRateZ: rotationRate.2,
        quaternionW: 1,
        quaternionX: 0,
        quaternionY: 0,
        quaternionZ: 0,
        roll: 0,
        pitch: 0,
        yaw: 0
    )
}

func makeStationarySamples(
    count: Int = 61,
    interval: Double = 0.05,
    userAcceleration: (Double, Double, Double) = (0, 0, 0),
    rotationRate: (Double, Double, Double) = (0, 0, 0)
) -> [RawMotionSample] {
    (0..<count).map { offset in
        syntheticSample(
            index: UInt64(offset + 1),
            timestamp: Double(offset) * interval,
            userAcceleration: userAcceleration,
            rotationRate: rotationRate
        )
    }
}

func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

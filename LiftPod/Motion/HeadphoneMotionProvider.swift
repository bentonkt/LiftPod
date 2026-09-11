@preconcurrency import CoreMotion
import Foundation

/// Core Motion's Objective-C manager is not Sendable. This narrow wrapper is
/// safe because mutable callback state is protected by a lock and Core Motion
/// serializes motion callbacks on the dedicated operation queue below.
final class HeadphoneMotionProvider: NSObject, MotionProviding, @unchecked Sendable {
    struct CallbackIndexer {
        private(set) var value: UInt64 = 0

        mutating func reset() {
            value = 0
        }

        mutating func next() -> UInt64 {
            value += 1
            return value
        }
    }

    private struct State {
        var monitoring = false
        var callbackIndexer = CallbackIndexer()
        var continuation: AsyncStream<MotionProviderEvent>.Continuation?
        var streamID: UUID?
    }

    private let manager: CMHeadphoneMotionManager
    private let callbackQueue: OperationQueue
    private let lock = NSLock()
    private var state = State()

    override init() {
        manager = CMHeadphoneMotionManager()
        callbackQueue = OperationQueue()
        super.init()
        callbackQueue.name = "app.liftpod.rawmotion.motion-callbacks"
        callbackQueue.maxConcurrentOperationCount = 1
        callbackQueue.qualityOfService = .userInitiated
        manager.delegate = self
    }

    var authorizationState: MotionPermissionState {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }

    var isMotionAvailable: Bool { manager.isDeviceMotionAvailable }
    var connectionUpdatesActive: Bool { manager.isConnectionStatusActive }
    var motionUpdatesActive: Bool { manager.isDeviceMotionActive }

    func makeEventStream() -> AsyncStream<MotionProviderEvent> {
        let streamID = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            lock.withLock {
                state.continuation?.finish()
                state.continuation = continuation
                state.streamID = streamID
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: streamID)
            }
        }
    }

    func start() {
        let shouldStart = lock.withLock {
            guard !state.monitoring else { return false }
            state.monitoring = true
            state.callbackIndexer.reset()
            return true
        }
        guard shouldStart else { return }

        manager.startConnectionStatusUpdates()
        startMotionUpdatesIfNeeded()
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard state.monitoring else { return false }
            state.monitoring = false
            return true
        }
        guard shouldStop else { return }
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
    }

    private func receive(motion: CMDeviceMotion?, error: Error?) {
        if let error {
            emitFatalEvent(.failure(error.localizedDescription))
            return
        }
        guard let motion else { return }

        let payload: (UInt64, AsyncStream<MotionProviderEvent>.Continuation?)? = lock.withLock {
            guard state.monitoring else { return nil }
            return (state.callbackIndexer.next(), state.continuation)
        }
        guard let (index, continuation) = payload else { return }
        let sample = RawMotionSample(
            deviceMotion: motion,
            index: index,
            receiptUptime: ProcessInfo.processInfo.systemUptime
        )
        continuation?.yield(.sample(sample))
    }

    private func startMotionUpdatesIfNeeded() {
        let isMonitoring = lock.withLock { state.monitoring }
        guard isMonitoring, manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: callbackQueue) { [weak self] motion, error in
            self?.receive(motion: motion, error: error)
        }
    }

    private func emitFatalEvent(_ event: MotionProviderEvent) {
        lock.withLock { state.continuation }?.yield(event)
    }

    private func removeContinuation(id: UUID) {
        lock.withLock {
            guard state.streamID == id else { return }
            state.continuation = nil
            state.streamID = nil
        }
    }
}

extension HeadphoneMotionProvider: CMHeadphoneMotionManagerDelegate {
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        startMotionUpdatesIfNeeded()
        lock.withLock { state.continuation }?.yield(.connected)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        emitFatalEvent(.disconnected)
    }
}

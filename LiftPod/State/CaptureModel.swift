import Combine
import Foundation

@MainActor
protocol WorkoutMotionConsumer: AnyObject {
    func ingest(_ sample: RawMotionSample) async
    func motionUnavailable() async
}

@MainActor
final class CaptureModel: ObservableObject {
    weak var workoutConsumer: (any WorkoutMotionConsumer)?
    @Published private(set) var authorizationState: MotionPermissionState
    @Published private(set) var motionAvailable: Bool
    @Published private(set) var connectionUpdatesActive = false
    @Published private(set) var motionUpdatesActive = false
    @Published private(set) var connectionState: HeadphoneConnectionState = .unknown
    @Published private(set) var monitoringActive = false
    @Published private(set) var recordingActive = false
    @Published private(set) var callbackCount: UInt64 = 0
    @Published private(set) var recordedSampleCount = 0
    @Published private(set) var latestSample: RawMotionSample?
    @Published private(set) var latestError: String?
    @Published private(set) var completedCSVURL: URL?

    private let provider: any MotionProviding
    private let recorder: any MotionRecording
    private var eventTask: Task<Void, Never>?

    init(
        provider: any MotionProviding = HeadphoneMotionProvider(),
        recorder: any MotionRecording = CSVRecorder()
    ) {
        self.provider = provider
        self.recorder = recorder
        authorizationState = provider.authorizationState
        motionAvailable = provider.isMotionAvailable
    }

    func startMotion() {
        guard !monitoringActive else { return }
        latestError = nil
        latestSample = nil
        callbackCount = 0
        recordedSampleCount = 0
        authorizationState = provider.authorizationState
        motionAvailable = provider.isMotionAvailable
        connectionState = .waiting

        let stream = provider.makeEventStream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handle(event)
            }
        }
        provider.start()
        monitoringActive = true
        refreshProviderState()
    }

    func stopMotion(reason: String? = nil) async {
        guard monitoringActive || recordingActive || eventTask != nil else { return }
        await workoutConsumer?.motionUnavailable()
        await stopRecording()
        provider.stop()
        eventTask?.cancel()
        eventTask = nil
        monitoringActive = false
        connectionUpdatesActive = false
        motionUpdatesActive = false
        if let reason { latestError = reason }
    }

    func startRecording() async {
        guard monitoringActive, motionUpdatesActive, !recordingActive else { return }
        do {
            try await recorder.start()
            recordingActive = true
            recordedSampleCount = 0
            completedCSVURL = nil
        } catch {
            latestError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard recordingActive else { return }
        recordingActive = false
        do {
            if let completed = try await recorder.stop() {
                recordedSampleCount = completed.sampleCount
                completedCSVURL = completed.url
            }
        } catch {
            completedCSVURL = nil
            latestError = "Could not finalize recording: \(error.localizedDescription)"
        }
    }

    func applicationDidBecomeInactive() async {
        await stopMotion(reason: "Capture stopped because the application became inactive.")
    }

    private func handle(_ event: MotionProviderEvent) async {
        switch event {
        case .connected:
            connectionState = .connected
            refreshProviderState()
        case .disconnected:
            connectionState = .disconnected
            await stopMotion(reason: "AirPods disconnected. Press Start Motion to begin again.")
        case let .failure(message):
            refreshProviderState()
            await stopMotion(reason: "Motion capture failed: \(message). Press Start Motion to try again.")
        case let .sample(sample):
            callbackCount += 1
            if recordingActive {
                do {
                    recordedSampleCount = try await recorder.append(sample)
                } catch {
                    recordingActive = false
                    completedCSVURL = nil
                    latestError = "Recording failed: \(error.localizedDescription)"
                    _ = try? await recorder.stop()
                }
            }
            latestSample = sample
            refreshProviderState()
            await workoutConsumer?.ingest(sample)
        }
    }

    private func refreshProviderState() {
        authorizationState = provider.authorizationState
        motionAvailable = provider.isMotionAvailable
        connectionUpdatesActive = provider.connectionUpdatesActive
        motionUpdatesActive = provider.motionUpdatesActive
    }
}

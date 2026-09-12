import Combine
import Foundation

@MainActor
protocol WorkoutMotionConsumer: AnyObject {
    var ownsMotionCapture: Bool { get }
    func ingest(_ sample: RawMotionSample) async
    func motionUnavailable() async
}

@MainActor
extension WorkoutMotionConsumer {
    var ownsMotionCapture: Bool { false }
}

@MainActor
final class CaptureModel: ObservableObject {
    weak var workoutConsumer: (any WorkoutMotionConsumer)?
    var workoutRecordingActive: Bool { workoutConsumer?.ownsMotionCapture == true }
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
    // The ordered capture consumer forwards every event; UI publication is not a sensor transport.
    var analysisEventConsumer: (@MainActor (MotionProviderEvent) async -> Void)?

    let autoWorkout = AutoWorkoutModel()
    @Published var automaticMode = false
    @Published var manualAnalysisActive = false
    @Published private(set) var automaticTrackingActive = false
    @Published private(set) var autoRecoveryAvailable = false
    private let autoSession = AutoWorkoutSession()
    private let autoRecordingRoot: URL?
    private var recoveryFolder: URL?
    private var systemSuspendedAuto = false
    private var lastAutoReceipt: Double?
    private var lastAutoSource: Double?
    private var lastAutoPresentation = -Double.infinity
    private var autoWatchdog: Task<Void, Never>?

    private let provider: any MotionProviding
    private let recorder: any MotionRecording
    private var eventTask: Task<Void, Never>?

    init(
        provider: any MotionProviding = HeadphoneMotionProvider(),
        recorder: any MotionRecording = CSVRecorder(),
        autoRecordingRoot: URL? = nil
    ) {
        self.provider = provider
        self.recorder = recorder
        self.autoRecordingRoot = autoRecordingRoot
        authorizationState = provider.authorizationState
        motionAvailable = provider.isMotionAvailable
        recoveryFolder = AutoWorkoutSession.recoverableDirectory()
        autoRecoveryAvailable = recoveryFolder != nil
    }

    /// Connection and source side are separate: iOS can stream the left AirPod
    /// even when both earbuds are paired. Expire a stopped stream explicitly.
    func liveSensor(now: Double = ProcessInfo.processInfo.systemUptime) -> HeadphoneSensorLocation? {
        guard monitoringActive, motionUpdatesActive, let sample = latestSample else { return nil }
        let age = now - sample.receiptUptime
        guard age >= 0, age < 0.5 else { return nil }
        return sample.sensorLocation
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
        if automaticTrackingActive, [.connecting,.running].contains(autoWorkout.snapshot.state) {
            await sendAuto(.init(kind: reason == nil ? .pause : .suspend, reason: reason))
        }
        guard monitoringActive || recordingActive || eventTask != nil else { return }
        if !automaticTrackingActive { await workoutConsumer?.motionUnavailable() }
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
        guard monitoringActive, motionUpdatesActive, !recordingActive, !automaticTrackingActive, !manualAnalysisActive, !workoutRecordingActive else { return }
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
        systemSuspendedAuto = systemSuspendedAuto || (automaticTrackingActive && [.connecting,.running].contains(autoWorkout.snapshot.state))
        await stopMotion(reason: "Capture stopped because the application became inactive.")
    }

    private func handle(_ event: MotionProviderEvent) async {
        if automaticTrackingActive {
            switch event {
            case .sample(let sample):
                if [.connecting,.running].contains(autoWorkout.snapshot.state) {
                    lastAutoReceipt = sample.receiptUptime
                    await sendAuto(.init(kind:.sample,raw:RawMotionEvent(sample)),forcePresentation:false)
                    lastAutoSource = await autoSession.snapshot.timestamp
                }
            case .disconnected:
                await sendAuto(.init(kind:.suspend,reason:"Headphones disconnected. Resume after reconnecting."))
            case .failure(let message):
                await sendAuto(.init(kind:.suspend,reason:message))
            case .connected: break
            }
        } else { await analysisEventConsumer?(event) }
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
            if !automaticTrackingActive { await workoutConsumer?.ingest(sample) }
        }
    }


    func applicationDidBecomeActive() async {
        if systemSuspendedAuto && automaticTrackingActive {
            systemSuspendedAuto = false
            await resumeAutoWorkout()
        }
    }

    func startAutoWorkout(side: ExperimentalSensorSide) async {
        guard !automaticTrackingActive, !manualAnalysisActive, !recordingActive, !workoutRecordingActive else {
            autoWorkout.report(error:"Finish the other recording before starting Auto."); return
        }
        automaticTrackingActive = true
        autoWorkout.apply(snapshot:.init(state:.connecting,status:"Connecting"))
        do {
            var config=AutoWorkoutConfiguration();config.side=side
            try await autoSession.start(configuration:config,root:autoRecordingRoot)
            lastAutoReceipt=nil;lastAutoSource=nil;lastAutoPresentation = -Double.infinity
            autoWorkout.setExports(await autoSession.exportURLs)
            autoWorkout.apply(snapshot:await autoSession.snapshot)
            startMotion(); startAutoWatchdog()
        } catch {
            automaticTrackingActive=false;autoWorkout.apply(snapshot:.init());autoWorkout.report(error:error.localizedDescription)
        }
    }

    func pauseAutoWorkout() async {
        systemSuspendedAuto=false
        await sendAuto(.init(kind:.pause))
        await stopMotion()
    }

    func resumeAutoWorkout() async {
        guard automaticTrackingActive else { return }
        await sendAuto(.init(kind:.resume))
        if [.connecting,.running].contains(autoWorkout.snapshot.state) {
            lastAutoReceipt=nil;startMotion();startAutoWatchdog()
        }
    }

    func finishAutoWorkout() async {
        guard automaticTrackingActive else { return }
        await sendAuto(.init(kind:.finish))
        if autoWorkout.snapshot.state == .finished {
            automaticTrackingActive=false;systemSuspendedAuto=false
            autoWatchdog?.cancel();autoWatchdog=nil
            await stopMotion()
        }
    }

    func endAutoSet() async { await sendAuto(.init(kind:.endSet)) }
    func correctAutoWorkout(_ correction: AutoWorkoutCorrection) async {
        await sendAuto(.init(kind:.correction,correction:correction))
    }

    func recoverAutoWorkout() async {
        guard !automaticTrackingActive,!manualAnalysisActive,!recordingActive,!workoutRecordingActive,let recoveryFolder else { return }
        do {
            try await autoSession.recover(from:recoveryFolder,root:autoRecordingRoot)
            automaticTrackingActive = await autoSession.snapshot.state != .finished
            autoWorkout.apply(snapshot:await autoSession.snapshot)
            autoWorkout.setExports(await autoSession.exportURLs)
            autoRecoveryAvailable=false
        } catch { autoWorkout.report(error:error.localizedDescription) }
    }

    private func sendAuto(_ input: AutoWorkoutInput, forcePresentation: Bool = true) async {
        do {
            try await autoSession.apply(input)
            let next=await autoSession.snapshot
            let time=next.timestamp ?? 0
            if forcePresentation || next.state != autoWorkout.snapshot.state ||
                next.cycles.count != autoWorkout.snapshot.cycles.count || time-lastAutoPresentation >= 0.1 {
                autoWorkout.apply(snapshot:next);lastAutoPresentation=time
            }
            if input.kind != .sample { autoWorkout.setExports(await autoSession.exportURLs) }
        } catch {
            autoWorkout.apply(snapshot:await autoSession.snapshot)
            autoWorkout.report(error:error.localizedDescription)
        }
    }

    private func startAutoWatchdog() {
        autoWatchdog?.cancel()
        autoWatchdog=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(0.5))
                guard !Task.isCancelled,let self else { return }
                guard self.automaticTrackingActive,
                    [.connecting,.running].contains(self.autoWorkout.snapshot.state),
                    let receipt=self.lastAutoReceipt,let source=self.lastAutoSource else { continue }
                let age=ProcessInfo.processInfo.systemUptime-receipt
                if age >= 1 {
                    await self.sendAuto(.init(kind:.clock,timestamp:source+age,reason:"Motion callbacks stopped"))
                    await self.stopMotion(reason:"Motion callbacks stopped")
                }
            }
        }
    }

    private func refreshProviderState() {
        authorizationState = provider.authorizationState
        motionAvailable = provider.isMotionAvailable
        connectionUpdatesActive = provider.connectionUpdatesActive
        motionUpdatesActive = provider.motionUpdatesActive
    }
}

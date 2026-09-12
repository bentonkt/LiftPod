import XCTest
@testable import LiftPod

@MainActor
final class CaptureModelTests: XCTestCase {
    func testSandboxWorkoutOwnershipBlocksOtherRecordersAndAutoRoutesExclusively() async {
        let root = autoScratch("sandbox-routing")
        defer { try? FileManager.default.removeItem(at:root) }
        let provider = MockMotionProvider()
        let model = CaptureModel(provider:provider,recorder:MockRecorder(),autoRecordingRoot:root)
        let consumer = SandboxCaptureConsumer()
        model.workoutConsumer = consumer
        model.startMotion()
        await model.startAutoWorkout(side:.right)
        await model.startRecording()
        XCTAssertFalse(model.automaticTrackingActive)
        XCTAssertFalse(model.recordingActive)
        consumer.ownsMotionCapture = false
        var diagnosticSamples = 0
        model.analysisEventConsumer = { event in
            if case .sample = event { diagnosticSamples += 1 }
        }
        await model.startAutoWorkout(side:.right)
        provider.emit(.sample(autoSample(0)))
        let received = await eventually { model.autoWorkout.snapshot.state == .running }
        XCTAssertTrue(received)
        XCTAssertEqual(consumer.samples,0)
        XCTAssertEqual(diagnosticSamples,0)
        await model.finishAutoWorkout()
    }

    func testAutoManualAndRawRecordingOwnershipIsExclusive() async {
        let root = autoScratch("ownership")
        defer { try? FileManager.default.removeItem(at: root) }

        let manualProvider = MockMotionProvider()
        let manualRecorder = MockRecorder()
        let manual = CaptureModel(provider: manualProvider, recorder: manualRecorder, autoRecordingRoot: root)
        manual.manualAnalysisActive = true
        await manual.startAutoWorkout(side: .right)
        XCTAssertFalse(manual.automaticTrackingActive)
        XCTAssertEqual(manualProvider.startCallCount, 0)
        manual.startMotion()
        await manual.startRecording()
        XCTAssertFalse(manual.recordingActive)
        await manual.stopMotion()

        let rawProvider = MockMotionProvider()
        let raw = CaptureModel(provider: rawProvider, recorder: MockRecorder(), autoRecordingRoot: root)
        raw.startMotion()
        await raw.startRecording()
        XCTAssertTrue(raw.recordingActive)
        await raw.startAutoWorkout(side: .right)
        XCTAssertFalse(raw.automaticTrackingActive)
        await raw.stopMotion()

        let autoProvider = MockMotionProvider()
        let automatic = CaptureModel(provider: autoProvider, recorder: MockRecorder(), autoRecordingRoot: root)
        await automatic.startAutoWorkout(side: .right)
        XCTAssertTrue(automatic.automaticTrackingActive)
        await automatic.startRecording()
        XCTAssertFalse(automatic.recordingActive)
        await automatic.finishAutoWorkout()
    }

    func testUserPauseStaysPausedAcrossInactiveAndActiveTransitions() async {
        let root = autoScratch("user-pause")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockMotionProvider()
        let model = CaptureModel(provider: provider, recorder: MockRecorder(), autoRecordingRoot: root)
        await model.startAutoWorkout(side: .right)
        provider.emit(.sample(autoSample(0)))
        let started = await eventually { model.autoWorkout.snapshot.state == .running }
        XCTAssertTrue(started)

        await model.pauseAutoWorkout()
        XCTAssertEqual(model.autoWorkout.snapshot.state, .paused)
        XCTAssertFalse(model.monitoringActive)
        await model.applicationDidBecomeInactive()
        await model.applicationDidBecomeActive()

        XCTAssertEqual(model.autoWorkout.snapshot.state, .paused)
        XCTAssertFalse(model.monitoringActive)
        XCTAssertEqual(provider.startCallCount, 1)
        await model.finishAutoWorkout()
    }

    func testRepeatedSystemInactiveThenActiveResumesRunningAutoWorkoutOnce() async {
        let root = autoScratch("system-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockMotionProvider()
        let model = CaptureModel(provider: provider, recorder: MockRecorder(), autoRecordingRoot: root)
        await model.startAutoWorkout(side: .right)
        provider.emit(.sample(autoSample(0)))
        let started = await eventually { model.autoWorkout.snapshot.state == .running }
        XCTAssertTrue(started)

        await model.applicationDidBecomeInactive()
        await model.applicationDidBecomeInactive()
        XCTAssertEqual(model.autoWorkout.snapshot.state, .suspended)
        XCTAssertFalse(model.monitoringActive)
        await model.applicationDidBecomeActive()

        XCTAssertEqual(model.autoWorkout.snapshot.state, .running)
        XCTAssertTrue(model.monitoringActive)
        XCTAssertEqual(provider.startCallCount, 2)
        await model.applicationDidBecomeActive()
        XCTAssertEqual(provider.startCallCount, 2)
        await model.finishAutoWorkout()
    }

    func testFinishingAutoWorkoutStopsMotionStream() async {
        let root = autoScratch("finish")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockMotionProvider()
        let model = CaptureModel(provider: provider, recorder: MockRecorder(), autoRecordingRoot: root)
        await model.startAutoWorkout(side: .right)
        XCTAssertTrue(model.monitoringActive)

        await model.finishAutoWorkout()

        XCTAssertEqual(model.autoWorkout.snapshot.state, .finished)
        XCTAssertFalse(model.automaticTrackingActive)
        XCTAssertFalse(model.monitoringActive)
        XCTAssertFalse(model.motionUpdatesActive)
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    func testResumeAfterMissingCallbackClockUsesCurrentWorkoutTime() async {
        let root = autoScratch("clock-resume")
        defer { try? FileManager.default.removeItem(at:root) }
        let provider = MockMotionProvider()
        let model = CaptureModel(provider:provider,recorder:MockRecorder(),autoRecordingRoot:root)
        await model.startAutoWorkout(side:.right)
        provider.emit(.sample(experimentalRawSample(index:0,time:0,side:.rightHeadphone,
            receiptTime:ProcessInfo.processInfo.systemUptime - 2)))
        let suspended = await eventually(timeout:.seconds(2)) {
            model.autoWorkout.snapshot.state == .suspended && !model.monitoringActive
        }
        XCTAssertTrue(suspended)
        let interruptionTime = model.autoWorkout.snapshot.timestamp ?? 0
        XCTAssertGreaterThan(interruptionTime,1)
        await model.resumeAutoWorkout()
        XCTAssertEqual(model.autoWorkout.snapshot.state,.running)
        XCTAssertGreaterThanOrEqual(model.autoWorkout.snapshot.timestamp ?? 0,interruptionTime)
        XCTAssertTrue(model.monitoringActive)
        await model.finishAutoWorkout()
        XCTAssertEqual(model.autoWorkout.snapshot.state,.finished)
    }

    func testRepeatedModelStartAndStopDoNotDuplicateMonitoring() async {
        let provider = MockMotionProvider()
        let model = CaptureModel(provider: provider, recorder: MockRecorder())

        model.startMotion()
        model.startMotion()
        XCTAssertEqual(provider.startCallCount, 1)
        XCTAssertEqual(provider.activeStreamCount, 1)

        await model.stopMotion()
        await model.stopMotion()
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    func testFirstSampleUpdatesApplicationState() async {
        let provider = MockMotionProvider()
        let model = CaptureModel(provider: provider, recorder: MockRecorder())
        model.startMotion()
        provider.emit(.sample(makeSample(index: 1)))

        let receivedFirstSample = await eventually { model.callbackCount == 1 }
        XCTAssertTrue(receivedFirstSample)
        XCTAssertEqual(model.latestSample?.index, 1)
        XCTAssertTrue(model.monitoringActive)
    }

    func testDisconnectionStopsRecordingAndMonitoring() async {
        let provider = MockMotionProvider()
        let recorder = MockRecorder()
        let model = CaptureModel(provider: provider, recorder: recorder)
        model.startMotion()
        await model.startRecording()
        provider.emit(.disconnected)

        let stopped = await eventually { !model.monitoringActive }
        XCTAssertTrue(stopped)
        XCTAssertFalse(model.recordingActive)
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertNotNil(model.completedCSVURL)
        XCTAssertTrue(model.latestError?.contains("disconnected") == true)
    }

    func testHandlerErrorRequiresRestart() async {
        let provider = MockMotionProvider()
        let model = CaptureModel(provider: provider, recorder: MockRecorder())
        model.startMotion()
        provider.emit(.failure("synthetic failure"))

        let stopped = await eventually { !model.monitoringActive }
        XCTAssertTrue(stopped)
        XCTAssertTrue(model.latestError?.contains("synthetic failure") == true)
        XCTAssertEqual(provider.stopCallCount, 1)
    }

    func testApplicationDeactivationSafelyStopsEverything() async {
        let provider = MockMotionProvider()
        let model = CaptureModel(provider: provider, recorder: MockRecorder())
        model.startMotion()
        await model.startRecording()
        await model.applicationDidBecomeInactive()

        XCTAssertFalse(model.monitoringActive)
        XCTAssertFalse(model.recordingActive)
        XCTAssertFalse(model.motionUpdatesActive)
        XCTAssertTrue(model.latestError?.contains("inactive") == true)
    }

    func testRecordingFailureIsSurfacedAndNotExportable() async {
        let provider = MockMotionProvider()
        let recorder = MockRecorder()
        await recorder.configure(failAppend: true)
        let model = CaptureModel(provider: provider, recorder: recorder)
        model.startMotion()
        await model.startRecording()
        XCTAssertNil(model.completedCSVURL)
        provider.emit(.sample(makeSample()))

        let stopped = await eventually { !model.recordingActive }
        XCTAssertTrue(stopped)
        XCTAssertNil(model.completedCSVURL)
        XCTAssertTrue(model.latestError?.contains("Recording failed") == true)
    }

    func testSuccessfullyClosedRecordingIsExportable() async {
        let provider = MockMotionProvider()
        let model = CaptureModel(provider: provider, recorder: MockRecorder())
        model.startMotion()
        await model.startRecording()
        provider.emit(.sample(makeSample()))
        let wroteSample = await eventually { model.recordedSampleCount == 1 }
        XCTAssertTrue(wroteSample)
        await model.stopRecording()

        XCTAssertNotNil(model.completedCSVURL)
        XCTAssertFalse(model.recordingActive)
    }

    private func autoSample(_ index: Int) -> RawMotionSample {
        experimentalRawSample(index: UInt64(index), time: Double(index) / 50,
                              side: .rightHeadphone, gravity: .init(x: 0, y: 0, z: -1))
    }

    private func autoScratch(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("capture-auto-\(label)-\(UUID().uuidString)")
    }
}

@MainActor
private final class SandboxCaptureConsumer: WorkoutMotionConsumer {
    var ownsMotionCapture = true
    var samples = 0
    func ingest(_ sample: RawMotionSample) async { samples += 1 }
    func motionUnavailable() async {}
}

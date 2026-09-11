import XCTest
@testable import LiftPod

@MainActor
final class CaptureModelTests: XCTestCase {
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
}

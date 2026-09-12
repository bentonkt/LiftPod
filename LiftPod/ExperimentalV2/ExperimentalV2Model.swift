import Combine
import Foundation

@MainActor
final class ExperimentalV2Model: ObservableObject {
    @Published var selectedExercise: V2Exercise = .bicepsCurl { didSet { refreshProfile() } }
    @Published var selectedSide: ExperimentalSensorSide = .right { didSet { refreshProfile() } }
    @Published var setupConfirmed = false
    @Published var airPodsModelLabel = ""
    @Published var observedCount = ""
    @Published var notes = ""
    @Published private(set) var profile: V2DSPProfile? = .bundledCurl
    @Published private(set) var snapshot = V2ProcessorSnapshot(
        ingestSequence: -1, setState: .idle, quality: .warmingUp, detectorPhase: .waitingForBottom,
        committedCount: 0, reference: nil, filteredSignal: nil, landmarks: .init(), recentEvents: []
    )
    @Published private(set) var recordingStatus = "Idle"
    @Published private(set) var replayStatus = "Not run"
    @Published private(set) var latestError: String?
    @Published private(set) var exportURLs: V2SessionBundleURLs?
    @Published private(set) var reviewStatus: String?

    private let engine = V2SetEngine()
    private var recorder: V2SessionRecorder?
    private var latestSourceTimestamp = 0.0
    private var latestReceiptUptime = 0.0
    private var lastPresentationSourceTimestamp = -Double.infinity

    var unavailableMessage: String? {
        selectedExercise == .bicepsCurl && selectedSide == .right ? nil :
            "This exercise and setup require calibration or an imported eligible Experimental V2 profile."
    }

    func canStart(motionActive: Bool, sideVerified: Bool, otherRecordingActive: Bool) -> Bool {
        motionActive && sideVerified && !otherRecordingActive && setupConfirmed && profile != nil &&
            (snapshot.setState == .idle || snapshot.setState == .complete || snapshot.setState == .interrupted)
    }

    func startSet(motionActive: Bool, sideVerified: Bool, otherRecordingActive: Bool) async {
        guard let profile else { latestError = unavailableMessage; return }
        let recorder = V2SessionRecorder()
        do {
            try await engine.start(profile: profile, recorder: recorder, motionActive: motionActive,
                                   sideVerified: sideVerified, noOtherRecording: !otherRecordingActive,
                                   setupConfirmed: setupConfirmed)
            self.recorder = recorder; latestError = nil; exportURLs = nil; reviewStatus = nil
            recordingStatus = "Recording"; await refresh(force: true)
        } catch { latestError = error.localizedDescription }
    }

    func ingest(_ sample: RawMotionSample) async {
        latestSourceTimestamp = sample.sourceTimestamp; latestReceiptUptime = sample.receiptUptime
        await engine.ingest(sample)
        let next = await engine.snapshot
        if next.setState != snapshot.setState || sample.sourceTimestamp - lastPresentationSourceTimestamp >= 0.09 {
            await apply(next)
            lastPresentationSourceTimestamp = sample.sourceTimestamp
        }
    }

    func endSet() async {
        do { try await engine.requestEnd(at: latestSourceTimestamp); await refresh(force: true) }
        catch { latestError = error.localizedDescription }
    }

    func sync() async {
        do {
            try await engine.addSyncMarker(name: "SYNC", sourceTimestamp: latestSourceTimestamp,
                                           receiptUptime: latestReceiptUptime)
        } catch { latestError = error.localizedDescription }
    }

    func motionUnavailable() async {
        await engine.motionDisconnected(); await refresh(force: true)
    }

    func applicationBackgrounded() async {
        await engine.applicationBackgrounded(); await refresh(force: true)
    }

    func saveReview() {
        guard let directory = exportURLs?.directory else {
            latestError = "Complete a set before saving an Experimental V2 review."; return
        }
        do {
            let count = observedCount.isEmpty ? nil : Int(observedCount)
            _ = try V2HumanReviewWriter().save(.init(observedCount: count,
                                                     committedCount: snapshot.committedCount,
                                                     notes: notes, createdUTC: Date()), in: directory)
            reviewStatus = "Review saved as a separate sidecar."
        } catch { latestError = error.localizedDescription }
    }

    private func refresh(force: Bool) async {
        let next = await engine.snapshot
        if force { await apply(next) }
    }

    private func apply(_ next: V2ProcessorSnapshot) async {
        snapshot = next
        exportURLs = await engine.completedBundle
        if snapshot.setState == .complete {
            recordingStatus = "Complete"
            if let directory = exportURLs?.directory {
                do {
                    let result = V2ReplayVerifier().verify(try V2ReplayArchive.load(from: directory))
                    replayStatus = result.passed ? "Passed" : "Failed at \(result.field ?? "unknown field")"
                } catch { replayStatus = "Failed: \(error.localizedDescription)" }
            }
        }
        if snapshot.setState == .interrupted { recordingStatus = "Interrupted" }
    }

    private func refreshProfile() {
        profile = selectedExercise == .bicepsCurl && selectedSide == .right ? .bundledCurl : nil
        snapshot = .init(ingestSequence: -1, setState: .idle, quality: .warmingUp,
                         detectorPhase: .waitingForBottom, committedCount: 0, reference: nil,
                         filteredSignal: nil, landmarks: .init(), recentEvents: [])
    }
}

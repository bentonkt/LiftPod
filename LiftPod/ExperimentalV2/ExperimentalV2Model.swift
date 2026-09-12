import Combine
import Foundation

@MainActor
final class ExperimentalV2Model: ObservableObject {
    @Published var countingMode: RepCountingMode = .generic { didSet { refreshProfile() } }
    @Published var selectedExercise: V2Exercise = .bicepsCurl { didSet { refreshProfile() } }
    @Published var selectedSide: ExperimentalSensorSide = .right { didSet { refreshProfile() } }
    @Published var selectedAlgorithm: V6Algorithm = .adaptiveAxis {
        didSet { preferences.set(selectedAlgorithm.rawValue, forKey: Self.algorithmKey); refreshProfile() }
    }
    /// Experimental app default; developers may select V1 for comparison and legacy replay.
    @Published var continuousMetricsEnabled = true {
        didSet { preferences.set(continuousMetricsEnabled, forKey: Self.metricsKey) }
    }
    @Published var devicePathMetricsEnabled = true {
        didSet { preferences.set(devicePathMetricsEnabled, forKey: Self.devicePathKey) }
    }
    @Published var setupConfirmed = false
    @Published var airPodsModelLabel = ""
    @Published var observedCount = ""
    @Published var notes = ""
    @Published private(set) var profile: V2DSPProfile? = .adaptiveCurlV6
    @Published private(set) var snapshot = V2ProcessorSnapshot(
        ingestSequence: -1, setState: .idle, quality: .warmingUp, detectorPhase: .waitingForBottom,
        committedCount: 0, reference: nil, filteredSignal: nil, landmarks: .init(), recentEvents: []
    )
    @Published private(set) var recordingStatus = "Idle"
    @Published private(set) var replayStatus = "Not run"
    @Published private(set) var latestError: String?
    @Published private(set) var exportURLs: V2SessionBundleURLs?
    @Published private(set) var reviewStatus: String?

    private static let algorithmKey = "repLab.detectorAlgorithm"
    private static let metricsKey = "repLab.continuousMetricsEnabled"
    // A distinct release preference prevents V1's opt-in default from silently
    // disabling the new default. Subsequent explicit choices remain persistent.
    private static let devicePathKey = "repLab.cyclicDevicePathMetricsEnabled"
    private let preferences: UserDefaults
    private let engine = V2SetEngine()
    private let genericSession = GenericRepSession()
    private var runningGeneric = false
    private var recorder: V2SessionRecorder?
    private var latestSourceTimestamp = 0.0
    private var latestReceiptUptime = 0.0
    private var lastPresentationSourceTimestamp = -Double.infinity
    private var verifyingDirectory: URL?
    private var replayTask: Task<Void, Never>?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        selectedAlgorithm = preferences.string(forKey: Self.algorithmKey)
            .flatMap(V6Algorithm.init(rawValue:)) ?? .adaptiveAxis
        continuousMetricsEnabled = preferences.object(forKey: Self.metricsKey) as? Bool ?? true
        devicePathMetricsEnabled = preferences.object(forKey: Self.devicePathKey) as? Bool ?? true
        refreshProfile()
    }

    var unavailableMessage: String? {
        if countingMode == .generic { return nil }
        return profile != nil ? nil :
            "This exercise and setup require calibration or an imported eligible Experimental V6 profile."
    }

    func canStart(motionActive: Bool, sideVerified: Bool, otherRecordingActive: Bool) -> Bool {
        motionActive && sideVerified && !otherRecordingActive && setupConfirmed && (countingMode == .generic || profile != nil) &&
            (snapshot.setState == .idle || snapshot.setState == .complete || snapshot.setState == .interrupted)
    }

    func startSet(motionActive: Bool, sideVerified: Bool, otherRecordingActive: Bool) async {
        if countingMode == .generic {
            guard canStart(motionActive: motionActive, sideVerified: sideVerified, otherRecordingActive: otherRecordingActive) else { return }
            do {
                try await genericSession.start(side: selectedSide, metricsEnabled: devicePathMetricsEnabled)
                runningGeneric = true
                latestError = nil; exportURLs = nil; reviewStatus = nil
                replayTask?.cancel(); replayTask = nil; verifyingDirectory = nil; replayStatus = "Not run"
                recordingStatus = "Recording"; await refresh(force: true)
            } catch { latestError = error.localizedDescription }
            return
        }
        guard let profile else { latestError = unavailableMessage; return }
        let recorder = V2SessionRecorder()
        do {
            try await engine.start(profile: profile, recorder: recorder, motionActive: motionActive,
                                   sideVerified: sideVerified, noOtherRecording: !otherRecordingActive,
                                   setupConfirmed: setupConfirmed,
                                   metricsConfiguration: devicePathMetricsEnabled ? .cyclicDevicePath3D :
                                    (continuousMetricsEnabled ? .continuousV2 : .init()))
            runningGeneric = false
            self.recorder = recorder; latestError = nil; exportURLs = nil; reviewStatus = nil
            replayTask?.cancel(); replayTask = nil; verifyingDirectory = nil; replayStatus = "Not run"
            recordingStatus = "Recording"; await refresh(force: true)
        } catch { latestError = error.localizedDescription }
    }

    func ingest(_ sample: RawMotionSample) async {
        latestSourceTimestamp = sample.sourceTimestamp; latestReceiptUptime = sample.receiptUptime
        if runningGeneric {
            guard [.active,.finalizing].contains(snapshot.setState) else { return }
            do { try await genericSession.apply(.init(kind: .sample, raw: RawMotionEvent(sample))) }
            catch { latestError = error.localizedDescription }
            if let next = await genericSession.snapshot,
               next.setState != snapshot.setState || next.committedCount != snapshot.committedCount ||
                sample.sourceTimestamp-lastPresentationSourceTimestamp >= 0.09 {
                await apply(next); lastPresentationSourceTimestamp = sample.sourceTimestamp
            }
            return
        }
        await engine.ingest(sample)
        let next = await engine.snapshot
        let finalizedCount = next.metrics?.reps.filter { $0.status != .pending }.count ?? 0
        let presentedFinalizedCount = snapshot.metrics?.reps.filter { $0.status != .pending }.count ?? 0
        if next.setState != snapshot.setState || finalizedCount != presentedFinalizedCount ||
            sample.sourceTimestamp - lastPresentationSourceTimestamp >= 0.09 {
            await apply(next)
            lastPresentationSourceTimestamp = sample.sourceTimestamp
        }
    }

    func endSet() async {
        if runningGeneric {
            do { try await genericSession.apply(.init(kind: .end, timestamp: latestSourceTimestamp)); await refresh(force: true) }
            catch { latestError = error.localizedDescription }
            return
        }
        do { try await engine.requestEnd(at: latestSourceTimestamp); await refresh(force: true) }
        catch { latestError = error.localizedDescription }
    }

    func sync() async {
        if runningGeneric {
            do { try await genericSession.apply(.init(kind: .marker, marker: .init(name: "SYNC",
                estimatedSessionSourceTime: latestSourceTimestamp, receiptUptime: latestReceiptUptime,
                ingestSequence: snapshot.ingestSequence))) }
            catch { latestError = error.localizedDescription }
            return
        }
        do {
            try await engine.addSyncMarker(name: "SYNC", sourceTimestamp: latestSourceTimestamp,
                                           receiptUptime: latestReceiptUptime)
        } catch { latestError = error.localizedDescription }
    }

    func motionUnavailable() async {
        if runningGeneric {
            try? await genericSession.apply(.init(kind: .interrupt, interruption: .disconnect)); await refresh(force: true); return
        }
        await engine.motionDisconnected(); await refresh(force: true)
    }

    func applicationBackgrounded() async {
        if runningGeneric {
            try? await genericSession.apply(.init(kind: .interrupt, interruption: .appBackgrounding)); await refresh(force: true); return
        }
        await engine.applicationBackgrounded(); await refresh(force: true)
    }

    func saveReview() {
        guard let directory = exportURLs?.directory else {
            latestError = "Complete a set before saving an Experimental V6 review."; return
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
        if runningGeneric {
            if force, let next = await genericSession.snapshot { await apply(next) }
            return
        }
        let next = await engine.snapshot
        if force { await apply(next) }
    }

    private func apply(_ next: V2ProcessorSnapshot) async {
        snapshot = next
        if runningGeneric { exportURLs = await genericSession.completedBundle }
        else { exportURLs = await engine.completedBundle }
        if snapshot.setState == .complete {
            recordingStatus = "Complete"
            if let directory = exportURLs?.directory, verifyingDirectory != directory {
                verifyingDirectory = directory
                replayStatus = "Verifying…"
                let isGeneric = runningGeneric
                replayTask = Task { [weak self] in
                    let status = await Task.detached(priority: .utility) {
                        do {
                            let result = try isGeneric ? GenericReplayVerifier().verify(directory: directory) :
                                V2ReplayVerifier().verify(V2ReplayArchive.load(from: directory))
                            return result.passed ? "Passed" : "Failed at \(result.field ?? "unknown field")"
                        } catch { return "Failed: \(error.localizedDescription)" }
                    }.value
                    guard !Task.isCancelled, self?.exportURLs?.directory == directory else { return }
                    self?.replayStatus = status
                }
            }
        }
        if snapshot.setState == .interrupted { recordingStatus = "Interrupted" }
    }

    private func refreshProfile() {
        guard ![.preparing, .active, .finalizing].contains(snapshot.setState) else { return }
        guard selectedSide == .right else { profile = nil; return }
        if selectedExercise == .lateralRaise {
            profile = .lateralRaiseV6
        } else if selectedExercise == .bicepsCurl {
            switch selectedAlgorithm {
            case .qualifiedLocalCycle: profile = .bundledCurl
            case .fixedAxisAngular: profile = .fixedAxisAngularCurl
            case .adaptiveAxis: profile = .adaptiveCurlV6
            case .adaptiveAxisV7: profile = .adaptiveCurlV7
            case .gravityTilt: profile = .adaptiveCurlV6
            }
        } else { profile = nil; return }
        snapshot = .init(ingestSequence: -1, setState: .idle, quality: .warmingUp,
                         detectorPhase: .waitingForBottom, committedCount: 0, reference: nil,
                         filteredSignal: nil, landmarks: .init(), recentEvents: [])
    }
}

typealias ExperimentalV6Model = ExperimentalV2Model

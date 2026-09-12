import Foundation

struct V2ProcessorSnapshot: Codable, Sendable, Equatable {
    let ingestSequence: Int
    let setState: V2SetState
    let quality: SignalQualityState
    let detectorPhase: V2DetectorPhase
    let committedCount: Int
    let reference: V2ReferenceMeasurements?
    let filteredSignal: Double?
    let landmarks: V2CycleLandmarks
    let recentEvents: [V2CycleEvidence]
    var v6Diagnostics: V6Diagnostics? = nil
    var metrics: RepMetricsSnapshot? = nil
    var streamVersion: String? = nil
    var qualityDetail: String? = nil
    var isRecovering: Bool? = nil
}

protocol V2RecordingSink: Sendable {
    func start(descriptor: V2SetDescriptor, profile: V2DSPProfile) async throws
    func appendRaw(_ sample: RawMotionSample) async throws
    func appendTransaction(_ transaction: V2ProcessorTransaction) async throws
    func addMarker(_ marker: V2SyncMarker) async throws
    func finalize(state: V2SetState, failure: V2SetInterruption?, snapshot: V2ProcessorSnapshot,
                  reference: V2ReferenceMeasurements?) async throws -> V2SessionBundleURLs?
}

actor V2SetEngine {
    private(set) var state: V2SetState = .idle
    private(set) var snapshot = V2ProcessorSnapshot(ingestSequence: -1, setState: .idle, quality: .warmingUp,
                                                    detectorPhase: .waitingForBottom, committedCount: 0,
                                                    reference: nil, filteredSignal: nil, landmarks: .init(), recentEvents: [])
    private(set) var descriptor: V2SetDescriptor?
    private(set) var interruption: V2SetInterruption?
    private(set) var completedBundle: V2SessionBundleURLs?

    private var profile: V2DSPProfile?
    private var recorder: (any V2RecordingSink)?
    private var lastRawSample: RawMotionSample?
    private var resampler = V2StreamingResampler()
    private var recoveryStartedAt: Double?
    private var recoveryNeedsAnchor = false
    private var qualityDetail: String?
    private var referenceAcquirer = V2ReferenceAcquirer()
    private var v6ReferenceAcquirer = V6ReferenceAcquirer()
    private var filter = ScalarBiquadFilter()
    private var segmenter: V2LocalCycleSegmenter?
    private var templateSegmenter: V2TemplateCycleSegmenter?
    private var v6Detector: V6CurlDetector?
    private var preparationStart: Double?
    private var activationTimestamp: Double?
    private var endRequestTimestamp: Double?
    private var ingestSequence = 0
    private var quality: SignalQualityState = .warmingUp
    private var metrics: PassiveRepMetrics?
    private var metricsFrames: [V2MetricsFrameInput] = []
    private var recordedCommittedIDs: Set<String> = []
    private var countingDrainComplete = false

    func start(profile: V2DSPProfile, recorder: any V2RecordingSink,
               motionActive: Bool, sideVerified: Bool, noOtherRecording: Bool,
               setupConfirmed: Bool, metricsConfiguration: RepMetricsConfiguration? = .init()) async throws {
        guard state == .idle || state == .complete || state == .interrupted else {
            throw V2Error.invalidLifecycle("another set is already running")
        }
        let frozen = try profile.validated()
        let metricsConfiguration = try metricsConfiguration?.validated()
        guard motionActive, sideVerified, noOtherRecording, setupConfirmed else {
            throw V2Error.invalidLifecycle("motion, sensor side, recording, and setup requirements must be satisfied")
        }
        let descriptor = V2SetDescriptor(setID: UUID(), exercise: frozen.identity.exercise,
                                         profileID: frozen.profileID, dspContentHash: frozen.contentHash,
                                         authorizationSource: .manual,
                                         hardwareSetupIdentifier: frozen.identity.setupIdentifier)
        try await recorder.start(descriptor: descriptor, profile: frozen)
        self.profile = frozen; self.descriptor = descriptor; self.recorder = recorder
        metrics = metricsConfiguration.map { PassiveRepMetrics(configuration: $0) }
        metricsFrames = []; recordedCommittedIDs = []
        countingDrainComplete = false
        lastRawSample = nil; resampler = .init(); recoveryStartedAt = nil; recoveryNeedsAnchor = false; qualityDetail = nil
        referenceAcquirer.reset(); v6ReferenceAcquirer.reset()
        filter = ScalarBiquadFilter(coefficients: frozen.identity.filter)
        let usesV6 = frozen.identity.profileVersion == "experimental-v6"
        segmenter = !usesV6 && frozen.identity.kind == .localCycle
            ? V2LocalCycleSegmenter(profile: frozen, setDescriptor: descriptor) : nil
        templateSegmenter = !usesV6 && frozen.identity.kind == .fullCycleTemplate
            ? V2TemplateCycleSegmenter(profile: frozen, setDescriptor: descriptor) : nil
        v6Detector = usesV6 ? V6CurlDetector(profile: frozen, descriptor: descriptor) : nil
        preparationStart = nil; activationTimestamp = nil; endRequestTimestamp = nil
        ingestSequence = 0; quality = .warmingUp; interruption = nil; completedBundle = nil
        state = .preparing
        updateSnapshot(filtered: nil)
    }

    func ingest(_ sample: RawMotionSample) async {
        guard state == .preparing || state == .active || state == .finalizing,
              let profile, let recorder else { return }
        do { try await recorder.appendRaw(sample) }
        catch { await interrupt(.recordingFailure); return }

        guard profile.identity.expectedSensorSide.matches(sample.sensorLocation) else {
            await interrupt(.wrongSensorSide); return
        }
        let result: V2StreamStep
        do { result = try resampler.append(sample) }
        catch V2StreamFailure.backwardClock { await interrupt(.backwardSourceClock); return }
        catch { await interrupt(.invalidInput); return }
        lastRawSample = sample
        if let discontinuity = result.discontinuity {
            recoveryStartedAt = sample.sourceTimestamp
            recoveryNeedsAnchor = result.samples.isEmpty
            quality = discontinuity.state; qualityDetail = discontinuity.reason
            filter.reset()
            segmenter?.reset(discontinuity: true)
            templateSegmenter?.reset(discontinuity: true)
            v6Detector?.reset(discontinuity: true)
            metrics?.sourceDiscontinuity(at: sample.sourceTimestamp)
            if state == .preparing { referenceAcquirer.reset(); v6ReferenceAcquirer.reset() }
        }
        let newSamples = result.samples
        metricsFrames.removeAll(keepingCapacity: true)
        for uniform in newSamples { process(uniform, profile: profile) }
        updateSnapshot(filtered: snapshot.filteredSignal)
        let schema = V2RecordingFormat.schema(profile: profile, metrics: metrics?.configuration)
        let transaction = V2ProcessorTransaction(
            schemaVersion: schema, processorVersion: V2RecordingFormat.processor(schema), ingestSequence: ingestSequence,
            boundary: ingestSequence == 0 ? .start : nil, input: RawMotionEvent(sample), output: snapshot,
            uniformSamples: Array(newSamples), profileID: profile.profileID, profileHash: profile.contentHash,
            metricsFrames: schema == 7 ? metricsFrames : nil
        )
        do { try await recorder.appendTransaction(transaction) }
        catch { await interrupt(error is V2RecordingQueueError ? .processingQueueOverflow : .recordingFailure); return }
        ingestSequence += 1

        if state == .finalizing, let endRequestTimestamp,
           sample.sourceTimestamp - endRequestTimestamp >= profile.identity.timing.finalizationDrainDuration {
            countingDrainComplete = true
            let pendingDeadline = metrics?.pendingDeadline ?? endRequestTimestamp
            let metricsDrainEnd = min(endRequestTimestamp + 0.60, pendingDeadline)
            if sample.sourceTimestamp + 1e-9 >= metricsDrainEnd { await finishComplete() }
        }
    }

    func requestEnd(at sourceTimestamp: Double) async throws {
        guard state == .active else { throw V2Error.invalidLifecycle("end is accepted only while active") }
        guard sourceTimestamp.isFinite else { throw V2Error.invalidLifecycle("end requires a finite source timestamp") }
        state = .finalizing; endRequestTimestamp = sourceTimestamp
        updateSnapshot(filtered: snapshot.filteredSignal)
    }

    func addSyncMarker(name: String, sourceTimestamp: Double, receiptUptime: Double) async throws {
        guard let recorder else { throw V2Error.invalidLifecycle("no active recording") }
        try await recorder.addMarker(.init(name: name, estimatedSessionSourceTime: sourceTimestamp,
                                          receiptUptime: receiptUptime, ingestSequence: ingestSequence))
    }

    func cancel() async { await interrupt(.explicitCancellation) }
    func motionDisconnected() async { await interrupt(.disconnect) }
    func applicationBackgrounded() async { await interrupt(.appBackgrounding) }

    private func process(_ sample: ResampledMotionSample, profile: V2DSPProfile) {
        var boundaryEvidence: [V2BoundaryEvidence] = []
        metrics?.observe(sample)
        defer {
            let events = v6Detector?.events ?? segmenter?.events ?? templateSegmenter?.events ?? []
            metrics?.observeBoundaryEvidence(boundaryEvidence, at: sample.sourceTimestamp)
            metrics?.observeCommitted(events, at: sample.sourceTimestamp)
            if V2RecordingFormat.schema(profile: profile, metrics: metrics?.configuration) == 7 {
                let newlyCommitted = events.filter { $0.committed && !recordedCommittedIDs.contains($0.id) }
                recordedCommittedIDs.formUnion(newlyCommitted.map(\.id))
                metricsFrames.append(.init(sourceTimestamp: sample.sourceTimestamp,
                                            boundaryEvidence: boundaryEvidence, committedEvents: newlyCommitted))
            }
            updateSnapshot(filtered: snapshot.filteredSignal)
        }
        preparationStart = preparationStart ?? sample.sourceTimestamp
        if recoveryNeedsAnchor { recoveryStartedAt = sample.sourceTimestamp; recoveryNeedsAnchor = false }
        if let recoveryStartedAt {
            guard sample.sourceTimestamp - recoveryStartedAt + 1e-9 >= V2StreamingResampler.recoveryDuration else { return }
            self.recoveryStartedAt = nil
            quality = state == .preparing ? .warmingUp : .usable
            qualityDetail = "Stream recovered; committed count retained"
        }
        if state == .preparing {
            let reference = profile.identity.profileVersion == "experimental-v6"
                ? v6ReferenceAcquirer.observe(sample, profile: profile)
                : referenceAcquirer.observe(sample, profile: profile)
            if let reference {
                filter.reset()
                segmenter?.reset()
                templateSegmenter?.reset()
                v6Detector?.reset()
                if sample.sourceTimestamp - (preparationStart ?? sample.sourceTimestamp) >=
                    profile.identity.timing.minimumPreparationDuration {
                    state = .active; activationTimestamp = sample.sourceTimestamp; quality = .usable
                }
                updateSnapshot(filtered: nil, reference: reference)
            }
            return
        }
        guard let reference = activeReference else { return }
        // Only passive metrics may consume the extra drain; counting ends at the original boundary.
        if state == .finalizing && countingDrainComplete { return }
        if var v6Detector {
            let update = v6Detector.observe(sample, reference: reference, departureAllowed: state == .active)
            boundaryEvidence = update.boundaryEvidence
            for event in v6Detector.events where !event.committed && event.rejectionReason == nil {
                let withinSet = event.startTimestamp >= (activationTimestamp ?? .infinity) &&
                    (state != .finalizing || event.completionTimestamp <= (endRequestTimestamp ?? -.infinity))
                v6Detector.setCommitted(withinSet, forCandidateID: event.id)
            }
            self.v6Detector = v6Detector
            updateSnapshot(filtered: update.filteredSignal, v6Diagnostics: update.diagnostics)
            return
        }
        let source = profile.identity.signalSource == .gravity ? sample.gravity : sample.userAcceleration
        let normalized = profile.identity.polarity * source.value(on: profile.identity.projectionAxis) - reference.neutralSignal
        let filtered = filter.process(normalized)
        if profile.identity.kind == .localCycle, var segmenter {
            let emitted = segmenter.observe(signal: filtered, gyroscopeMagnitude: sample.rotationRate.magnitude,
                                             timestamp: sample.sourceTimestamp, departureAllowed: state == .active)
            for event in emitted {
                let withinSet = event.startTimestamp >= (activationTimestamp ?? .infinity) &&
                    (state != .finalizing || event.completionTimestamp <= (endRequestTimestamp ?? -.infinity))
                segmenter.setCommitted(event.rejectionReason == nil && withinSet, forCandidateID: event.id)
            }
            self.segmenter = segmenter
        } else if profile.identity.kind == .fullCycleTemplate, var templateSegmenter {
            let emitted = templateSegmenter.observe(sample, departureAllowed: state == .active)
            for event in emitted {
                let withinSet = event.startTimestamp >= (activationTimestamp ?? .infinity) &&
                    (state != .finalizing || event.completionTimestamp <= (endRequestTimestamp ?? -.infinity))
                templateSegmenter.setCommitted(event.rejectionReason == nil && withinSet, forCandidateID: event.id)
            }
            self.templateSegmenter = templateSegmenter
        }
        updateSnapshot(filtered: filtered)
    }

    private var activeReference: V2ReferenceMeasurements? {
        profile?.identity.profileVersion == "experimental-v6" ? v6ReferenceAcquirer.measurements : referenceAcquirer.measurements
    }

    private func updateSnapshot(filtered: Double?, reference: V2ReferenceMeasurements? = nil,
                                v6Diagnostics: V6Diagnostics? = nil) {
        let events = v6Detector?.events ?? segmenter?.events ?? templateSegmenter?.events ?? []
        snapshot = .init(ingestSequence: ingestSequence, setState: state, quality: quality,
                         detectorPhase: recoveryStartedAt != nil ? .recovering : (v6Detector?.phase ?? segmenter?.phase ?? .waitingForBottom),
                         committedCount: events.filter(\.committed).count,
                         reference: reference ?? activeReference, filteredSignal: filtered,
                         landmarks: v6Detector?.landmarks ?? segmenter?.landmarks ?? .init(),
                         recentEvents: Array(events.suffix(12)), v6Diagnostics: v6Diagnostics ?? snapshot.v6Diagnostics,
                         metrics: metrics?.snapshot, streamVersion: V2StreamingResampler.version,
                         qualityDetail: qualityDetail, isRecovering: recoveryStartedAt != nil)
    }

    private func finishComplete() async {
        guard state == .finalizing else { return }
        metrics?.finish(at: lastRawSample?.sourceTimestamp ?? 0, interrupted: false)
        state = .complete; updateSnapshot(filtered: snapshot.filteredSignal)
        do {
            guard let bundle = try await recorder?.finalize(state: .complete, failure: nil,
                                                             snapshot: snapshot,
                                                             reference: activeReference) else {
                throw V2Error.recordingFailure("finalization produced no session bundle")
            }
            completedBundle = bundle
        } catch {
            state = .interrupted
            interruption = .recordingFailure
            quality = .invalidInput
            qualityDetail = "Recording could not be finalized: \(error.localizedDescription)"
            completedBundle = nil
            updateSnapshot(filtered: snapshot.filteredSignal)
        }
    }

    private func interrupt(_ reason: V2SetInterruption) async {
        guard state != .complete, state != .interrupted else { return }
        state = .interrupted; interruption = reason; quality = qualityFor(reason)
        switch reason {
        case .invalidInput: qualityDetail = "Set stopped: a sensor frame contains non-finite values (invalidInput)"
        case .backwardSourceClock: qualityDetail = "Set stopped: source clock moved backward; start a new capture (backwardSourceClock)"
        case .recordingFailure: qualityDetail = "Set stopped: recording failed (recordingFailure)"
        default: qualityDetail = "Set stopped: \(reason.rawValue)"
        }
        recoveryStartedAt = nil
        metrics?.finish(at: lastRawSample?.sourceTimestamp ?? 0, interrupted: true)
        templateSegmenter?.reset(discontinuity: true)
        segmenter?.reset(discontinuity: true)
        v6Detector?.reset(discontinuity: true)
        updateSnapshot(filtered: snapshot.filteredSignal)
        completedBundle = try? await recorder?.finalize(state: .interrupted, failure: reason,
                                                        snapshot: snapshot, reference: activeReference)
    }

    private func qualityFor(_ reason: V2SetInterruption) -> SignalQualityState {
        switch reason {
        case .disconnect: .disconnected
        case .staleDelivery: .stale
        case .wrongSensorSide: .wrongSensorSide
        default: .invalidInput
        }
    }

}

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
    private var rawSamples: [RawMotionSample] = []
    private var processedUniformCount = 0
    private var referenceAcquirer = V2ReferenceAcquirer()
    private var filter = ScalarBiquadFilter()
    private var segmenter: V2LocalCycleSegmenter?
    private var templateSegmenter: V2TemplateCycleSegmenter?
    private var preparationStart: Double?
    private var activationTimestamp: Double?
    private var endRequestTimestamp: Double?
    private var previousReceipt: Double?
    private var ingestSequence = 0
    private var quality: SignalQualityState = .warmingUp

    func start(profile: V2DSPProfile, recorder: any V2RecordingSink,
               motionActive: Bool, sideVerified: Bool, noOtherRecording: Bool,
               setupConfirmed: Bool) async throws {
        guard state == .idle || state == .complete || state == .interrupted else {
            throw V2Error.invalidLifecycle("another set is already running")
        }
        let frozen = try profile.validated()
        guard motionActive, sideVerified, noOtherRecording, setupConfirmed else {
            throw V2Error.invalidLifecycle("motion, sensor side, recording, and setup requirements must be satisfied")
        }
        let descriptor = V2SetDescriptor(setID: UUID(), exercise: frozen.identity.exercise,
                                         profileID: frozen.profileID, dspContentHash: frozen.contentHash,
                                         authorizationSource: .manual,
                                         hardwareSetupIdentifier: frozen.identity.setupIdentifier)
        try await recorder.start(descriptor: descriptor, profile: frozen)
        self.profile = frozen; self.descriptor = descriptor; self.recorder = recorder
        rawSamples = []; processedUniformCount = 0; referenceAcquirer.reset()
        filter = ScalarBiquadFilter(coefficients: frozen.identity.filter)
        segmenter = frozen.identity.kind == .localCycle
            ? V2LocalCycleSegmenter(profile: frozen, setDescriptor: descriptor) : nil
        templateSegmenter = frozen.identity.kind == .fullCycleTemplate
            ? V2TemplateCycleSegmenter(profile: frozen, setDescriptor: descriptor) : nil
        preparationStart = nil; activationTimestamp = nil; endRequestTimestamp = nil
        previousReceipt = nil; ingestSequence = 0; quality = .warmingUp; interruption = nil; completedBundle = nil
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
        guard allFinite(sample) else { await interrupt(.invalidInput); return }
        if let previous = rawSamples.last?.sourceTimestamp, sample.sourceTimestamp < previous {
            await interrupt(.backwardSourceClock); return
        }
        if let previousReceipt, sample.receiptUptime - previousReceipt > 0.250 {
            await interrupt(.staleDelivery); return
        }
        previousReceipt = sample.receiptUptime
        rawSamples.append(sample)
        let result: MotionResamplingResult
        do { result = try V2UniformSourceResampler().resample(rawSamples, profile: profile) }
        catch { await interrupt(.invalidInput); return }
        if result.discontinuityEpochs.contains(where: { $0 > 0 }) {
            await interrupt(.invalidInput); return
        }
        let newSamples = result.samples.dropFirst(processedUniformCount)
        processedUniformCount = result.samples.count
        for uniform in newSamples { process(uniform, profile: profile) }
        updateSnapshot(filtered: snapshot.filteredSignal)
        let transaction = V2ProcessorTransaction(
            schemaVersion: 2, processorVersion: "rep-analysis-v2", ingestSequence: ingestSequence,
            boundary: ingestSequence == 0 ? .start : nil, input: RawMotionEvent(sample), output: snapshot,
            uniformSamples: Array(newSamples), profileID: profile.profileID, profileHash: profile.contentHash
        )
        do { try await recorder.appendTransaction(transaction) }
        catch { await interrupt(error is V2RecordingQueueError ? .processingQueueOverflow : .recordingFailure); return }
        ingestSequence += 1

        if state == .finalizing, let endRequestTimestamp,
           sample.sourceTimestamp - endRequestTimestamp >= profile.identity.timing.finalizationDrainDuration {
            await finishComplete()
        }
    }

    func requestEnd(at sourceTimestamp: Double) async throws {
        guard state == .active else { throw V2Error.invalidLifecycle("end is accepted only while active") }
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
        preparationStart = preparationStart ?? sample.sourceTimestamp
        if state == .preparing {
            if let reference = referenceAcquirer.observe(sample, profile: profile) {
                filter.reset()
                segmenter?.reset()
                templateSegmenter?.reset()
                if sample.sourceTimestamp - (preparationStart ?? sample.sourceTimestamp) >=
                    profile.identity.timing.minimumPreparationDuration {
                    state = .active; activationTimestamp = sample.sourceTimestamp; quality = .usable
                }
                updateSnapshot(filtered: nil, reference: reference)
            }
            return
        }
        guard let reference = referenceAcquirer.measurements else { return }
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

    private func updateSnapshot(filtered: Double?, reference: V2ReferenceMeasurements? = nil) {
        let events = segmenter?.events ?? templateSegmenter?.events ?? []
        snapshot = .init(ingestSequence: ingestSequence, setState: state, quality: quality,
                         detectorPhase: segmenter?.phase ?? .waitingForBottom,
                         committedCount: events.filter(\.committed).count,
                         reference: reference ?? referenceAcquirer.measurements, filteredSignal: filtered,
                         landmarks: segmenter?.landmarks ?? .init(), recentEvents: Array(events.suffix(12)))
    }

    private func finishComplete() async {
        guard state == .finalizing else { return }
        state = .complete; updateSnapshot(filtered: snapshot.filteredSignal)
        do {
            guard let bundle = try await recorder?.finalize(state: .complete, failure: nil,
                                                             snapshot: snapshot,
                                                             reference: referenceAcquirer.measurements) else {
                throw V2Error.recordingFailure("finalization produced no session bundle")
            }
            completedBundle = bundle
        } catch {
            state = .interrupted
            interruption = .recordingFailure
            quality = .invalidInput
            completedBundle = nil
            updateSnapshot(filtered: snapshot.filteredSignal)
        }
    }

    private func interrupt(_ reason: V2SetInterruption) async {
        guard state != .complete, state != .interrupted else { return }
        state = .interrupted; interruption = reason; quality = qualityFor(reason)
        templateSegmenter?.reset(discontinuity: true)
        segmenter?.reset(discontinuity: true)
        updateSnapshot(filtered: snapshot.filteredSignal)
        completedBundle = try? await recorder?.finalize(state: .interrupted, failure: reason,
                                                        snapshot: snapshot, reference: referenceAcquirer.measurements)
    }

    private func qualityFor(_ reason: V2SetInterruption) -> SignalQualityState {
        switch reason {
        case .disconnect: .disconnected
        case .staleDelivery: .stale
        case .wrongSensorSide: .wrongSensorSide
        default: .invalidInput
        }
    }

    private func allFinite(_ sample: RawMotionSample) -> Bool {
        [sample.sourceTimestamp, sample.receiptUptime,
         sample.userAccelerationX, sample.userAccelerationY, sample.userAccelerationZ,
         sample.rotationRateX, sample.rotationRateY, sample.rotationRateZ,
         sample.gravityX, sample.gravityY, sample.gravityZ,
         sample.quaternionW, sample.quaternionX, sample.quaternionY, sample.quaternionZ,
         sample.roll, sample.pitch, sample.yaw].allSatisfy(\.isFinite)
    }
}

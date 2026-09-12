import SwiftUI

struct ExperimentalV2SignalLabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var capture: CaptureModel
    @StateObject private var model = ExperimentalV6Model()
    @State private var developerControlsExpanded = false

    var body: some View {
        List {
            setupSection
                .disabled([.preparing, .active, .finalizing].contains(model.snapshot.setState))
            lifecycleSection
            diagnosticsSection
            metricsSection
            eventsSection
            reviewSection
            developerSection
        }
        .navigationTitle("Experimental Rep Lab")
        .onAppear {
            capture.analysisEventConsumer = { [weak model] event in
                switch event {
                case .sample(let sample): await model?.ingest(sample)
                case .disconnected, .failure: await model?.motionUnavailable()
                case .connected: break
                }
            }
        }
        .onDisappear {
            capture.analysisEventConsumer = nil
            if [.preparing, .active, .finalizing].contains(model.snapshot.setState) {
                Task { await model.applicationBackgrounded() }
            }
        }
        .onChange(of: capture.monitoringActive) { _, active in
            guard !active, [.preparing, .active, .finalizing].contains(model.snapshot.setState) else { return }
            Task { await model.motionUnavailable() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active,
                  [.preparing, .active, .finalizing].contains(model.snapshot.setState) else { return }
            Task { await model.applicationBackgrounded() }
        }
    }

    private var setupSection: some View {
        Section("Setup") {
            Picker("Exercise", selection: $model.selectedExercise) {
                ForEach(V2Exercise.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Expected AirPod", selection: $model.selectedSide) {
                ForEach(ExperimentalSensorSide.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            TextField("Optional AirPods model label", text: $model.airPodsModelLabel)
            Toggle("Sensor side and mounting confirmed", isOn: $model.setupConfirmed)
            row("Profile", model.profile?.profileID ?? "Unavailable")
            row("Speed mode", model.devicePathMetricsEnabled ? "3D rep motion · experimental" :
                (model.continuousMetricsEnabled ? "V2 · continuous · experimental" : "V1 · quiet endpoints"))
            row("Validation", model.profile?.validationStatus.rawValue ?? "Calibration required")
            row("DSP hash", model.profile.map { String($0.contentHash.prefix(16)) } ?? "—")
            if let message = model.unavailableMessage { Text(message).foregroundStyle(.orange) }
        }
    }

    private var lifecycleSection: some View {
        Section("Set Lifecycle") {
            Button("Start Set") {
                Task { await model.startSet(motionActive: capture.motionUpdatesActive,
                                            sideVerified: capture.latestSample.map(sideMatches) ?? false,
                                            otherRecordingActive: capture.recordingActive) }
            }
            .disabled(!model.canStart(motionActive: capture.motionUpdatesActive,
                                      sideVerified: capture.latestSample.map(sideMatches) ?? false,
                                      otherRecordingActive: capture.recordingActive))
            Button("End Set") { Task { await model.endSet() } }.disabled(model.snapshot.setState != .active)
            Button("SYNC") { Task { await model.sync() } }
                .disabled(![.preparing, .active, .finalizing].contains(model.snapshot.setState))
            Text("SYNC estimates source time for external-video alignment. Presentation and transport delay remain; verify alignment independently.")
                .font(.caption).foregroundStyle(.secondary)
            row("State", model.snapshot.setState.rawValue.capitalized)
            row("Preparation", model.snapshot.setState == .preparing ? "Hold the weight still for at least 3 seconds" : "—")
            row("Reference", model.snapshot.reference == nil ? "Not ready" : "Ready")
            row("Recording", model.recordingStatus)
            if let error = model.latestError { Text(error).foregroundStyle(.red) }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Text(String(model.snapshot.committedCount)).font(.system(size: 56, weight: .bold, design: .rounded))
                .accessibilityLabel("Committed reps")
            row("Detector phase", model.snapshot.detectorPhase.rawValue)
            row("Signal quality", model.snapshot.quality.rawValue)
            if let detail = model.snapshot.qualityDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if model.snapshot.isRecovering == true {
                Text("Recovering—keep the AirPod connected and return to the starting position. Count retained.")
                    .foregroundStyle(.orange)
            }
            row("Filtered signal", number(model.snapshot.filteredSignal))
            row("Local bottom", number(model.snapshot.landmarks.bottom))
            row("Local top", number(model.snapshot.landmarks.top))
            row("Local return", number(model.snapshot.landmarks.returned))
            if let diagnostics = model.snapshot.v6Diagnostics {
                row("Bottom qualified", diagnostics.bottomQualified ? "Yes" : "No")
                row("Candidate", diagnostics.candidateID ?? "—")
                row("Axis energy", number(diagnostics.axisEnergyFraction))
                row("Unwrapped angle", number(diagnostics.unwrappedAngle))
                row("Signed rotation", number(diagnostics.signedRotationRate))
                row("Last rejection", diagnostics.rejectionReason?.rawValue ?? "—")
            }
            row("Replay", model.replayStatus)
            if let urls = model.exportURLs {
                ShareLink(items: [urls.rawCSV, urls.transactions, urls.metadata, urls.summary, urls.manifest, urls.profile]) {
                    Label("Export Session", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var eventsSection: some View {
        Section("Recent Events") {
            if model.snapshot.recentEvents.isEmpty { Text("No accepted or rejected events.").foregroundStyle(.secondary) }
            ForEach(model.snapshot.recentEvents) { event in
                VStack(alignment: .leading) {
                    Text(event.committed ? "Committed" : "Rejected")
                    Text("start \(number(event.startTimestamp)) · completion \(number(event.completionTimestamp)) · detection \(number(event.detectionTimestamp))" +
                         (event.rejectionReason.map { " · \($0.rawValue)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if let metrics = model.snapshot.metrics?.reps.first(where: { $0.id == event.id && $0.setID == event.setID }) {
                        Text("\(metrics.measurementKind?.hasSuffix("device-path-3d") == true ? "3D path" : "Vertical") lift mean \(metricNumber(metrics.meanLiftingSpeed)) · peak \(metricNumber(metrics.peakLiftingSpeed)) m/s · \(metrics.status.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var metricsSection: some View {
        Section(model.snapshot.metrics?.configuration.devicePath != nil ? "Estimated 3D rep-motion speed · Experimental" : "Estimated vertical speed · Experimental") {
            Text(model.snapshot.metrics?.configuration.devicePath?.cyclic != nil ?
                 "3D motion along the AirPod's rep path. Assumes you stay roughly in place and return to the starting region; steady body translation is not measured. No holds needed. Counting is independent." : model.snapshot.metrics?.configuration.devicePath != nil ?
                 "Speed along the AirPod's path, not exact dumbbell-center speed. Vertical speed comes from the same velocity vector. Counting is independent." :
                 "Speed of the mounted sensor along gravity, not full-path speed or a form score. Counting is independent of speed availability.")
                .font(.caption).foregroundStyle(.secondary)
            if let metrics = model.snapshot.metrics, let rep = metrics.reps.last {
                row("Speed status", rep.status == .pending ? "Estimating speed…" : rep.status.rawValue.capitalized)
                if let reason = rep.reason { Text(metricsExplanation(reason)).font(.caption).foregroundStyle(.secondary) }
                row("Lift mean / peak", "\(metricNumber(rep.meanLiftingSpeed)) / \(metricNumber(rep.peakLiftingSpeed)) m/s")
                row("Lower mean / peak", "\(metricNumber(rep.meanLoweringSpeed)) / \(metricNumber(rep.peakLoweringSpeed)) m/s")
                if rep.measurementKind?.hasSuffix("device-path-3d") == true {
                    row("Vertical lift mean / peak", "\(metricNumber(rep.meanVerticalLiftingSpeed)) / \(metricNumber(rep.peakVerticalLiftingSpeed)) m/s")
                    row("Vertical lower mean / peak", "\(metricNumber(rep.meanVerticalLoweringSpeed)) / \(metricNumber(rep.peakVerticalLoweringSpeed)) m/s")
                }
                row("Lifting / lowering", "\(metricNumber(rep.liftingDuration)) / \(metricNumber(rep.loweringDuration)) s")
                if rep.timingSource == .detectorLandmarks {
                    Text("Timing uses approximate detector boundaries; pauses may be included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                row("Top / preceding bottom pause", "\(metricNumber(rep.topPauseDuration)) / \(metricNumber(rep.bottomPauseDuration)) s")
                row("Tempo: lift–top–lower–bottom", "\(metricNumber(rep.liftingDuration))–\(metricNumber(rep.topPauseDuration))–\(metricNumber(rep.loweringDuration))–\(metricNumber(rep.bottomPauseDuration))")
                row("Slowdown vs first 3", metrics.slowdownPercent(for: rep).map { String(format: "%+.0f%%", $0) } ??
                    (metrics.baselineMeanLiftingSpeed == nil ? "Need 3 eligible reps" : "Speed unavailable"))
                Text("Positive slowdown means slower; negative means faster. Estimates may finalize after the rep count changes.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Bottom pause is the supported pause before this rep; unknown pauses are not estimated from timestamp gaps.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Metrics appear after a committed rep.").foregroundStyle(.secondary) }
        }
    }

    private func metricNumber(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }
    private func metricsExplanation(_ reason: RepMetricsReason) -> String {
        switch reason {
        case .waitingForEndpoint: "Estimating speed from the return boundary. Keep moving naturally."
        case .missingStartHold: "Speed unavailable: no quiet start anchor before this rep."
        case .missingEndHold: "Speed unavailable: no quiet return anchor. The rep still counts."
        case .excessiveEndpointCorrection: "Speed unavailable: acceleration drift needs too much correction."
        case .excessiveVerticalClosure: "Speed unavailable: reconstructed vertical motion did not return consistently."
        case .ambiguousDirection: "Speed unavailable: lifting and lowering could not be separated reliably."
        case .invalidInterval: "Speed unavailable: invalid or interrupted sensor interval."
        case .invalidOrientation: "Speed unavailable: attitude and gravity do not define a consistent world frame. The rep still counts."
        case .invalidLandmarks: "Speed unavailable: unsupported movement boundaries."
        case .interrupted: "Speed unavailable: set interrupted before confirmation."
        case .ambiguousBoundary: "Speed unavailable: the return boundary was ambiguous. The rep still counts."
        case .missingInitialAnchor: "Speed unavailable: no supported initial velocity reference. The rep still counts."
        case .excessiveUncertainty: "Speed unavailable: the motion estimate is too uncertain. The rep still counts."
        case .staleAnchor: "Speed unavailable: the last supported velocity reference is too old. The rep still counts."
        case .unsupportedExercise: "Continuous speed boundaries are currently supported for curls only."
        }
    }

    private var reviewSection: some View {
        Section("Human Review") {
            TextField("Independently observed count (optional)", text: $model.observedCount).keyboardType(.numberPad)
            TextField("Notes", text: $model.notes, axis: .vertical)
            Button("Save Review") { model.saveReview() }.disabled(model.exportURLs == nil)
            if let status = model.reviewStatus { Text(status).foregroundStyle(.secondary) }
            Text("Observed counts and SYNC taps are review aids, not precise ground truth.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var developerSection: some View {
        Section {
            DisclosureGroup("Developer Controls", isExpanded: $developerControlsExpanded) {
                Picker("Detector", selection: $model.selectedAlgorithm) {
                    ForEach(V6Algorithm.allCases, id: \.self) { Text(algorithmName($0)).tag($0) }
                }
                .disabled([.preparing, .active, .finalizing].contains(model.snapshot.setState))
                Toggle("Continuous speed V2 (experimental)", isOn: $model.continuousMetricsEnabled)
                    .disabled(model.devicePathMetricsEnabled || [.preparing, .active, .finalizing].contains(model.snapshot.setState))
                Toggle("3D rep-motion speed (experimental default)", isOn: $model.devicePathMetricsEnabled)
                    .disabled([.preparing, .active, .finalizing].contains(model.snapshot.setState))
                Text("3D mode fits each out-and-back rep locally without endpoint holds. It assumes approximate path return, not zero 3D velocity at every reversal. Stay roughly in place. Mode choices are remembered.")
                    .font(.caption).foregroundStyle(.secondary)
                if let rep = model.snapshot.metrics?.reps.last, let version = rep.estimatorVersion {
                    row("Estimator", version)
                    row("Endpoint evidence", rep.boundaryKind?.rawValue ?? "Unresolved")
                    row("Maximum velocity uncertainty", "\(metricNumber(rep.maximumVelocityStandardDeviation)) m/s")
                    row("Endpoint velocity", "\(metricNumber(rep.boundaryVelocity)) m/s")
                    row("Finalized at source time", number(rep.finalizedAt))
                }
                if let decision = model.snapshot.metrics?.boundaryDecisions?.last {
                    row("Last boundary decision", decision.accepted ? "Accepted" : decision.reason.rawValue)
                    row("Boundary ID", decision.boundaryID)
                }
                Button("Guided Calibration") { }.disabled(true)
                Button("Import V6 Profile") { }.disabled(true)
                Button("Offline Profile Evaluation") { }.disabled(true)
                Text("Calibration records exactly three uninterrupted demonstrations. Profile import and offline evaluation require versioned V6 data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sideMatches(_ sample: RawMotionSample) -> Bool { model.selectedSide.matches(sample.sensorLocation) }
    private func row(_ name: String, _ value: String) -> some View { LabeledContent(name, value: value) }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "—" }
    private func algorithmName(_ value: V6Algorithm) -> String {
        switch value {
        case .qualifiedLocalCycle: "Qualified local cycle (V4)"
        case .fixedAxisAngular: "Fixed-axis angular (V5)"
        case .adaptiveAxis: "Adaptive-axis (V6)"
        case .adaptiveAxisV7: "Adaptive-axis continuous (V7)"
        }
    }
}

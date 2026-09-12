import SwiftUI

struct ExperimentalV2SignalLabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var capture: CaptureModel
    @StateObject private var model = ExperimentalV6Model()
    @State private var developerControlsExpanded = false

    var body: some View {
        List {
            setupSection
            lifecycleSection
            diagnosticsSection
            eventsSection
            reviewSection
            developerSection
        }
        .navigationTitle("Experimental V6 Signal Lab")
        .onChange(of: capture.latestSample?.index) { _, _ in
            guard let sample = capture.latestSample else { return }
            Task { await model.ingest(sample) }
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
            Picker("Detector", selection: $model.selectedAlgorithm) {
                ForEach(V6Algorithm.allCases, id: \.self) { Text(algorithmName($0)).tag($0) }
            }
            TextField("Optional AirPods model label", text: $model.airPodsModelLabel)
            Toggle("Sensor side and mounting confirmed", isOn: $model.setupConfirmed)
            row("Profile", model.profile?.profileID ?? "Unavailable")
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
                    Label("Export V6 Session", systemImage: "square.and.arrow.up")
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
                }
            }
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
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: CaptureModel
    @StateObject private var offlineModel = OfflinePreprocessingModel()
    @StateObject private var experimentalModel = ExperimentalV1Model()
    @State private var showingRawCSVImporter = false
    @State private var showingExperimentalCSVImporter = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                controlsSection
                sampleSection
                offlinePreprocessingSection
                experimentalV1Section
                guidanceSection
            }
            .fileImporter(
                isPresented: $showingExperimentalCSVImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) { selection in
                switch selection {
                case let .success(url): experimentalModel.importRawCSV(url)
                case let .failure(error): experimentalModel.handleImportFailure(error)
                }
            }
            .navigationTitle("AirPods Motion")
            .fileImporter(
                isPresented: $showingRawCSVImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) { selection in
                switch selection {
                case let .success(url):
                    Task { await offlineModel.processImportedFile(url) }
                case let .failure(error):
                    offlineModel.handleImportFailure(error)
                }
            }
        }
    }

    private var experimentalV1Section: some View {
        Section("Experimental V1 Rep Detection") {
            Button("Select V1 Raw CSV") { showingExperimentalCSVImporter = true }
            statusRow("Recording", experimentalModel.sourceFilename ?? "None", id: "v1-source-file")
            Picker("Exercise", selection: $experimentalModel.selectedExercise) {
                ForEach(ExperimentalExercise.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Expected AirPod", selection: $experimentalModel.expectedSensorSide) {
                ForEach(ExperimentalSensorSide.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Button("Run V1 Detection") { Task { await experimentalModel.run() } }
                .disabled(experimentalModel.sourceFilename == nil || experimentalModel.state == .running)
            statusRow("State", experimentalModel.state.rawValue, id: "v1-state")
            if let result = experimentalModel.result {
                statusRow("Committed reps", String(result.committedCount), id: "v1-count")
                statusRow("Final quality", result.finalQuality.rawValue, id: "v1-quality")
                statusRow("Candidates", String(result.provisionalCount + result.committedCount), id: "v1-candidates")
                statusRow("Rejections", String(result.rejectedCount), id: "v1-rejections")
                ForEach(result.candidates) { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(candidate.exercise.rawValue): \(candidate.disposition.rawValue)")
                        Text("\(number(candidate.completionTimestamp)) s · \(number(candidate.duration)) s" +
                             (candidate.rejectionReason.map { " · \($0.rawValue)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = experimentalModel.latestError {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("v1-error")
            }
            if let urls = experimentalModel.exportURLs {
                ShareLink(items: [urls.summary, urls.replayTrace]) {
                    Label("Export V1 Results", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            statusRow("Motion permission", model.authorizationState.rawValue, id: "permission-status")
            statusRow("Headphone motion", model.motionAvailable ? "Available" : "Unavailable", id: "availability-status")
            statusRow("Connection", model.connectionState.rawValue, id: "connection-status")
            statusRow("Connection updates", model.connectionUpdatesActive ? "Active" : "Stopped", id: "connection-updates-status")
            statusRow("Motion stream", model.motionUpdatesActive ? "Active" : "Stopped", id: "motion-stream-status")
            statusRow("Received callbacks", String(model.callbackCount), id: "callback-count")
            statusRow("Recorded samples", String(model.recordedSampleCount), id: "recorded-count")
            if let error = model.latestError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("latest-error")
            }
        }
    }

    private var offlinePreprocessingSection: some View {
        Section("Offline Preprocessing") {
            Button("Import Raw CSV") {
                showingRawCSVImporter = true
            }
            .disabled(offlineModel.state == .importing || offlineModel.state == .processing)
            .accessibilityIdentifier("import-raw-csv")

            statusRow("Processing state", offlineModel.state.rawValue, id: "preprocessing-state")
            statusRow("Imported samples", String(offlineModel.importedSampleCount), id: "preprocessing-sample-count")

            if let result = offlineModel.result {
                valueRow("Source duration (s)", number(result.totalSourceDuration), id: "preprocessing-source-duration")
                valueRow("Effective sample rate (Hz)", number(result.effectiveSampleRate), id: "preprocessing-sample-rate")
                valueRow("Calibration duration (s)", number(result.calibration.duration), id: "preprocessing-calibration-duration")
                statusRow("Calibration samples", String(result.calibration.sampleCount), id: "preprocessing-calibration-count")
                valueRow("Vertical bias (m/s²)", number(result.calibration.verticalBias), id: "preprocessing-vertical-bias")
                valueRow("Calibration acceleration SD (m/s²)", number(result.calibration.verticalAccelerationStandardDeviation), id: "preprocessing-acceleration-deviation")
                valueRow("Calibration gyroscope RMS (rad/s)", number(result.calibration.gyroscopeRMSMagnitude), id: "preprocessing-gyroscope-rms")
                valueRow("Maximum timestamp gap (s)", number(result.maximumSourceTimeGap), id: "preprocessing-maximum-gap")
            }

            if let error = offlineModel.latestError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("preprocessing-error")
            }

            if let url = offlineModel.processedCSVURL {
                ShareLink(item: url) {
                    Label("Export Processed CSV", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("export-processed-csv")
            } else {
                Button {} label: {
                    Label("Export Processed CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(true)
                .accessibilityIdentifier("export-processed-csv-disabled")
            }
        }
    }

    private var controlsSection: some View {
        Section("Controls") {
            Button(model.monitoringActive ? "Stop Motion" : "Start Motion") {
                if model.monitoringActive {
                    Task { await model.stopMotion() }
                } else {
                    model.startMotion()
                }
            }
            .accessibilityIdentifier("motion-toggle")

            Button(model.recordingActive ? "Stop Recording" : "Start Recording") {
                Task {
                    if model.recordingActive {
                        await model.stopRecording()
                    } else {
                        await model.startRecording()
                    }
                }
            }
            .disabled(!model.monitoringActive || !model.motionUpdatesActive)
            .accessibilityIdentifier("recording-toggle")

            if let url = model.completedCSVURL {
                ShareLink(item: url) {
                    Label("Export Last Recording", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("export-recording")
            } else {
                Button {} label: {
                    Label("Export Last Recording", systemImage: "square.and.arrow.up")
                }
                    .disabled(true)
                    .accessibilityIdentifier("export-recording-disabled")
            }
        }
    }

    @ViewBuilder
    private var sampleSection: some View {
        Section("Latest Raw Sample") {
            if let sample = model.latestSample {
                valueRow("Sensor location", sample.sensorLocation.description, id: "sample-sensor-location")
                valueRow("Source timestamp (s)", number(sample.sourceTimestamp), id: "sample-source-timestamp")
                valueRow("Receipt uptime (s)", number(sample.receiptUptime), id: "sample-receipt-uptime")
                vectorRow("User acceleration (g)", sample.userAccelerationX, sample.userAccelerationY, sample.userAccelerationZ, id: "sample-user-acceleration")
                vectorRow("Gravity (g)", sample.gravityX, sample.gravityY, sample.gravityZ, id: "sample-gravity")
                vectorRow("Rotation rate (rad/s)", sample.rotationRateX, sample.rotationRateY, sample.rotationRateZ, id: "sample-rotation-rate")
                valueRow("Quaternion (w, x, y, z)", [sample.quaternionW, sample.quaternionX, sample.quaternionY, sample.quaternionZ].map(number).joined(separator: ", "), id: "sample-quaternion")
                valueRow("Roll / pitch / yaw (rad)", [sample.roll, sample.pitch, sample.yaw].map(number).joined(separator: ", "), id: "sample-attitude-angles")
            } else if model.monitoringActive {
                Text("Waiting for samples…")
                    .accessibilityIdentifier("waiting-for-samples")
            } else {
                Text("Start motion monitoring to receive samples.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var guidanceSection: some View {
        Section("Device Requirement") {
            Text("Real AirPods motion data requires a physical iPhone and compatible AirPods.")
            if model.authorizationState == .denied || model.authorizationState == .restricted {
                Text("Motion access is unavailable. Review Motion & Fitness access in iOS Settings.")
                    .foregroundStyle(.orange)
            } else if !model.motionAvailable {
                Text("Connect compatible AirPods. If monitoring is stopped, connect them and press Start Motion again.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func statusRow(_ label: String, _ value: String, id: String) -> some View {
        LabeledContent {
            Text(value).font(.system(.body, design: .monospaced))
        } label: {
            Text(label)
        }
            .accessibilityIdentifier(id)
    }

    private func valueRow(_ label: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
        .accessibilityIdentifier(id)
    }

    private func vectorRow(_ label: String, _ x: Double, _ y: Double, _ z: Double, id: String) -> some View {
        valueRow(label, "x \(number(x))  y \(number(y))  z \(number(z))", id: id)
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(8)))
    }
}

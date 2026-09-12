import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: CaptureModel
    var workoutRecordingDirectory: URL? = nil
    var toggleInterface: (() -> Void)? = nil
    @StateObject private var offlineModel = OfflinePreprocessingModel()
    @State private var showingRawCSVImporter = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                controlsSection
                sampleSection
                offlinePreprocessingSection
                experimentalV2Section
                guidanceSection
            }
            .navigationTitle("AirPods Motion")
            .toolbar {
                if let toggleInterface {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("liftpod", action: toggleInterface)
                            .font(.system(size: 15, weight: .semibold))
                            .accessibilityLabel("Switch to workout interface")
                            .accessibilityIdentifier("interface-toggle")
                    }
                }
            }
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

    private var experimentalV2Section: some View {
        Section("Experimental Signal Analysis") {
            NavigationLink("Experimental V6 Signal Lab") {
                ExperimentalV2SignalLabView(capture: model)
            }
            Text("Live set lifecycle, local-cycle diagnostics, recording, replay, and calibration tools.")
                .font(.caption).foregroundStyle(.secondary)
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

            if let directory = workoutRecordingDirectory {
                RecordingExportButton(url: directory, title: "Export Recorded Workout Set")
                    .accessibilityIdentifier("export-workout-set")
            } else {
                Button {} label: {
                    Label("Export Recorded Workout Set", systemImage: "square.and.arrow.up")
                }
                .disabled(true)
                .accessibilityIdentifier("export-workout-set-disabled")
            }
            if let url = model.completedCSVURL {
                RecordingExportButton(url: url, title: "Export Last Raw Recording")
                .accessibilityIdentifier("export-recording")
            } else {
                Button {} label: {
                    Label("Export Last Raw Recording", systemImage: "square.and.arrow.up")
                }
                    .disabled(true)
                    .accessibilityIdentifier("export-recording-disabled")
                Text("Complete a set in the workout interface to export its full recording. Raw CSV export becomes available after Stop Recording.")
                    .font(.caption).foregroundStyle(.secondary)
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

/// Exports a complete set as a ZIP, or a raw recording as CSV, through Files.
struct RecordingExportButton: View {
    let url: URL
    let title: String
    @State private var document: RecordingExportDocument?
    @State private var exporting = false
    @State private var exportError: String?
    @State private var filename = "recording"
    @State private var contentType: UTType = .data

    var body: some View {
        Button {
            do {
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                contentType = isDirectory ? .zip : .commaSeparatedText
                filename = isDirectory ? "LiftPod-set-\(url.lastPathComponent).zip" : url.lastPathComponent
                if isDirectory {
                    var coordinatorError: NSError?
                    var readResult: Result<Data, Error>?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading,
                                                   error: &coordinatorError) { archive in
                        readResult = Result { try Data(contentsOf: archive) }
                    }
                    if let coordinatorError { throw coordinatorError }
                    guard let readResult else { throw CocoaError(.fileReadUnknown) }
                    document = RecordingExportDocument(data: try readResult.get())
                } else {
                    document = RecordingExportDocument(data: try Data(contentsOf: url))
                }
                exporting = true
            } catch { exportError = error.localizedDescription }
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }
        .fileExporter(isPresented: $exporting, document: document,
                      contentType: contentType, defaultFilename: filename) { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("Could not export recording", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}

struct RecordingExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

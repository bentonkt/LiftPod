import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        NavigationStack {
            List {
                statusSection
                controlsSection
                sampleSection
                guidanceSection
            }
            .navigationTitle("AirPods Motion")
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

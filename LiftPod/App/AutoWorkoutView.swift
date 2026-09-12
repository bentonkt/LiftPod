import SwiftUI

enum AutoWorkoutPresentation {
    static func status(_ snapshot: AutoWorkoutSnapshot) -> String {
        switch snapshot.state {
        case .connecting: return "Connecting"
        case .paused: return "Paused"
        case .suspended: return "Tracking unavailable"
        default: return snapshot.status
        }
    }

    static func intervalName(_ kind: AutoIntervalKind) -> String {
        switch kind {
        case .preparation: "Preparation"
        case .recovery: "Recovery · estimated"
        case .unclassified: "Movement unclear"
        case .unavailable: "Tracking unavailable"
        case .intraSetPause: "Pause within set"
        }
    }

    static func trackingControlTitle(_ state: AutoWorkoutState) -> String {
        state == .paused || state == .suspended ? "Resume Tracking" : "Pause Tracking"
    }

    static func canControlTracking(_ state: AutoWorkoutState) -> Bool {
        [.running, .paused, .suspended].contains(state)
    }
}

struct AutoWorkoutView: View {
    @ObservedObject var capture: CaptureModel
    @ObservedObject var model: AutoWorkoutModel
    @State private var mountingConfirmed = false
    @State private var side: ExperimentalSensorSide = .right

    private var active: Bool {
        [.connecting, .running, .paused, .suspended].contains(model.snapshot.state)
    }
    private var otherOwner: Bool { capture.manualAnalysisActive || (capture.recordingActive && !active) }

    var body: some View {
        List {
            Section("Auto Workout · Experimental") {
                Text("Automatically groups repeating movement into sets while the app stays open. Counts remain editable.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Expected AirPod", selection: $side) {
                    ForEach(ExperimentalSensorSide.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .disabled(active)
                Toggle("Sensor side and mounting confirmed", isOn: $mountingConfirmed)
                    .disabled(active)
                Button("Start Workout") { Task { await capture.startAutoWorkout(side: side) } }
                    .disabled(active || !mountingConfirmed || otherOwner)
                if capture.autoRecoveryAvailable {
                    Button("Recover Workout") { Task { await capture.recoverAutoWorkout() } }
                        .disabled(active || otherOwner)
                }
                if otherOwner {
                    Text("Another recording or analysis session owns motion capture.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Workout") {
                Text(AutoWorkoutPresentation.status(model.snapshot))
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("auto-workout-status")
                if let elapsed = model.snapshot.elapsedRest {
                    LabeledContent("Recovery · estimated", value: duration(elapsed))
                }
                if let reason = model.snapshot.availabilityReason {
                    Text(reason).foregroundStyle(.orange)
                }
                HStack {
                    Button(AutoWorkoutPresentation.trackingControlTitle(model.snapshot.state)) {
                        Task {
                            if [.paused, .suspended].contains(model.snapshot.state) { await capture.resumeAutoWorkout() }
                            else { await capture.pauseAutoWorkout() }
                        }
                    }
                    .disabled(!AutoWorkoutPresentation.canControlTracking(model.snapshot.state))
                    Spacer()
                    Button("Finish Workout", role: .destructive) { Task { await capture.finishAutoWorkout() } }
                        .disabled(!active)
                }
                Button("End Set Now") { Task { await capture.endAutoSet() } }
                    .disabled(model.snapshot.state != .running || !model.snapshot.sets.contains { $0.status == .open || $0.status == .provisional })
            }

            Section("Sets") {
                if model.snapshot.sets.isEmpty { Text("No qualified sets yet.").foregroundStyle(.secondary) }
                ForEach(Array(model.snapshot.sets.enumerated()), id: \.element.id) { index, set in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Set \(index + 1) · \(set.count) reps").font(.headline)
                            Spacer()
                            Text(set.status.rawValue.capitalized).foregroundStyle(.secondary)
                        }
                        if let metric = model.snapshot.metrics.last(where: { set.cycleIDs.contains($0.id) }),
                           let speed = metric.meanSpeed {
                            LabeledContent("Latest cycle speed", value: String(format:"%.2f m/s",speed))
                        }
                        if let baseline = set.baselineMeanSpeed {
                            LabeledContent("Set speed baseline", value:String(format:"%.2f m/s",baseline))
                        }
                        HStack {
                            Button("−") { correct(.init(kind: .count, setID: set.id, count: max(0, set.count - 1))) }
                                .accessibilityLabel("Decrease Set \(index + 1) count")
                            Text("Correct count")
                            Button("+") { correct(.init(kind: .count, setID: set.id, count: set.count + 1)) }
                                .accessibilityLabel("Increase Set \(index + 1) count")
                            Spacer()
                            Button("Discard", role: .destructive) { correct(.init(kind: .discard, setID: set.id)) }
                        }
                        if set.cycleIDs.count > 1 {
                            Menu("Split between reps") {
                                ForEach(Array(set.cycleIDs.dropLast().enumerated()), id: \.element) { boundary, cycleID in
                                    Button("After rep \(boundary + 1)") {
                                        correct(.init(kind: .split, setID: set.id, afterCycleID: cycleID))
                                    }
                                }
                            }
                        }
                        if index + 1 < model.snapshot.sets.count {
                            Button("Merge with next set") {
                                correct(.init(kind: .merge, setID: set.id,
                                              otherSetID: model.snapshot.sets[index + 1].id))
                            }
                        }
                    }
                }
            }

            Section("Timeline") {
                if model.snapshot.intervals.isEmpty { Text("Timeline appears as evidence resolves.").foregroundStyle(.secondary) }
                ForEach(model.snapshot.intervals) { interval in
                    LabeledContent(AutoWorkoutPresentation.intervalName(interval.kind)) {
                        Text(duration(max(0, interval.end - interval.start)) + (interval.provisional ? " · provisional" : ""))
                    }
                }
            }

            if !model.exportURLs.isEmpty {
                Section("Export") {
                    ShareLink(items: model.exportURLs) {
                        Label("Export Workout", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .buttonStyle(.borderless)
        .navigationTitle("Auto Workout")
    }

    private func correct(_ correction: AutoWorkoutCorrection) {
        Task { await capture.correctAutoWorkout(correction) }
    }

    private func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

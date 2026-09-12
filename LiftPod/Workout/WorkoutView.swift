import SwiftUI

struct WorkoutView: View {
    @ObservedObject var capture: CaptureModel
    @StateObject private var workout = WorkoutModel()
    @State private var showingDiagnostics = false
    @State private var now = ProcessInfo.processInfo.systemUptime

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let result = workout.result {
                        summary(result)
                    } else if workout.isRunning {
                        live
                    } else {
                        ready
                    }
                    if let error = workout.error ?? capture.latestError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("LiftPod")
            .toolbar {
                if !workout.isRunning {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Diagnostics", systemImage: "waveform.path.ecg") { showingDiagnostics = true }
                    }
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                ContentView(model: capture)
                    .safeAreaInset(edge: .bottom) {
                        Button("Done") { showingDiagnostics = false }.buttonStyle(.borderedProminent).padding()
                    }
            }
            .task {
                while !Task.isCancelled {
                    now = ProcessInfo.processInfo.systemUptime
                    await workout.checkStaleness(now: now)
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                }
            }
        }
        .tint(.indigo)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Make every set count.").font(.largeTitle.bold())
            Text("Attach your right AirPod to the dumbbell in the tested curl orientation.")
                .foregroundStyle(.secondary)
            card {
                signalStatus
                if !capture.monitoringActive {
                    Button("Connect motion") { capture.startMotion() }.buttonStyle(.bordered)
                }
                Toggle("Mount and right AirPod confirmed", isOn: $workout.mountConfirmed)
            }
            card {
                Picker("Exercise", selection: $workout.prescription.exercise) {
                    ForEach(V2Exercise.allCases) { Text($0.rawValue).tag($0) }
                }
                if !workout.supportedExercise {
                    Text("This exercise will be available when its profile is integrated.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Goal", selection: $workout.prescription.goal) {
                    ForEach(TrainingGoal.allCases) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    Text("Dumbbell load (lb)")
                    Spacer()
                    TextField("Load", value: $workout.prescription.loadLB, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                        .accessibilityIdentifier("workout-load")
                }
                Stepper("Minimum reps: \(workout.prescription.minimumReps)",
                        value: $workout.prescription.minimumReps, in: 1...workout.prescription.maximumReps)
                Stepper("Maximum reps: \(workout.prescription.maximumReps)",
                        value: $workout.prescription.maximumReps, in: workout.prescription.minimumReps...100)
            }
            Text("Select your exercise manually. Sets start and finish automatically.")
                .font(.footnote).foregroundStyle(.secondary)
            if capture.recordingActive {
                Text("Stop the raw recording in Diagnostics before starting a workout.").foregroundStyle(.orange)
            }
            if !workout.prescription.isValid {
                Text("Enter a load between 0 and 1,000 lb and a valid rep range.").foregroundStyle(.orange)
            }
            Button("Start Workout") { Task { await workout.start(capture) } }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!workout.canStart(capture))
                .accessibilityIdentifier("start-workout")
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(workout.activePrescription.exercise.rawValue).font(.largeTitle.bold())
            Text(prescriptionText(workout.activePrescription)).foregroundStyle(.secondary)
            card {
                Text(workout.state == .preparing ? "GET READY" : (workout.session?.current == nil ? "READY FOR NEXT SET" : "SET \(workout.completedSets.count + 1)"))
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Text("\(workout.reps)").font(.system(size: 96, weight: .bold, design: .rounded))
                    .contentTransition(.numericText()).accessibilityIdentifier("workout-reps")
                Text(liveMessage).font(.title3.weight(.medium))
                if let restStart = workout.restStart {
                    LabeledContent("Rest", value: "\(Int(max(0, workout.sourceTime - restStart))) s")
                }
                signalStatus
            }
            if workout.state == .preparing {
                Button("Cancel set") { Task { await workout.cancelPreparation() } }
                    .buttonStyle(.bordered).disabled(workout.busy)
            } else {
                Button(workout.state == .finalizing ? "Finishing workout…" : "End Workout") {
                    Task { await workout.end() }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(workout.state != .active || workout.busy)
            }
            if workout.state == .active, workout.session?.current != nil {
                Button("End this set now") { workout.endSet() }.buttonStyle(.bordered)
            }
            if workout.state == .active, workout.session?.current == nil {
                nextSetControls
            }
            if let last = workout.completedSets.last {
                card {
                    Text("Last set · \(last.reps.count) reps").font(.headline)
                    Text("Set complete").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nextSetControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Next-set setup").font(.headline)
            HStack {
                Text("Load (lb)")
                TextField("Load", value: $workout.prescription.loadLB, format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Stepper("Minimum reps: \(workout.prescription.minimumReps)", value: $workout.prescription.minimumReps,
                    in: 1...workout.prescription.maximumReps)
            Stepper("Maximum reps: \(workout.prescription.maximumReps)", value: $workout.prescription.maximumReps,
                    in: workout.prescription.minimumReps...100)
            Button("Apply to next set") { workout.updateNextSet() }.disabled(!workout.prescription.isValid)
            Text("Start moving when ready. The next complete rep opens a new set automatically.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var liveMessage: String {
        switch workout.state {
        case .preparing: "Hold the weight still at the starting position for at least 3 seconds."
        case .finalizing: "Hold still while the set finishes recording."
        default: workout.session?.current == nil ? "Ready when you are. Your first complete rep starts the set." : "The set closes after 12 seconds without a complete rep."
        }
    }

    private func summary(_ result: WorkoutSetResult) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(result.interrupted ? "Workout interrupted" : "Workout complete").font(.largeTitle.bold())
            Text(result.prescription.exercise.rawValue).font(.title2)
            card {
                Text("\(result.reps)").font(.system(size: 72, weight: .bold, design: .rounded))
                Text("completed reps").foregroundStyle(.secondary)
                Text("\(workout.completedSets.count) recorded sets").font(.headline)
                Divider()
                LabeledContent("Goal", value: result.prescription.goal.rawValue)
                LabeledContent("Load", value: "\(result.prescription.loadLB.formatted()) lb")
                LabeledContent("Rep target", value: "\(result.prescription.minimumReps)–\(result.prescription.maximumReps)")
                if let duration = result.averageRepDuration {
                    LabeledContent("Average rep time", value: "\(duration.formatted(.number.precision(.fractionLength(1)))) s")
                }
                if let duration = result.movementDuration {
                    LabeledContent("First to last rep", value: "\(duration.formatted(.number.precision(.fractionLength(1)))) s")
                }
            }
            ForEach(Array(workout.completedSets.enumerated()), id: \.element.id) { index, set in
                card {
                    Text("Set \(index + 1) · \(set.prescription.exercise.rawValue)").font(.headline)
                    Text("\(set.reps.count) reps · \(set.prescription.loadLB.formatted()) lb")
                    Text(set.interrupted ? "Interrupted" : "Complete").foregroundStyle(.secondary)
                }
            }
            if let url = workout.sessionURL { ShareLink("Share workout and replay data", item: url) }
            Button("New workout") { workout.reset() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var signalStatus: some View {
        let ready = workout.signalReady(capture, now: now)
        return Label(ready ? "Right AirPod · motion live" : "Waiting for live right-AirPod motion",
                     systemImage: ready ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
            .font(.callout).foregroundStyle(ready ? Color.green : Color.secondary)
    }

    private func prescriptionText(_ value: WorkoutPrescription) -> String {
        "\(value.loadLB.formatted()) lb · \(value.minimumReps)–\(value.maximumReps) reps · \(value.goal.rawValue)"
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 24))
    }
}

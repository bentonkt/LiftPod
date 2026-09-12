import SwiftUI

private enum LiftStyle {
    static let blue = Color(red: 49 / 255, green: 91 / 255, blue: 1)
    static let secondary = Color.secondary
}

struct WorkoutView: View {
    @ObservedObject var capture: CaptureModel
    @StateObject private var workout = WorkoutModel()
    @State private var developerMode = false
    @State private var showingDiagnostics = false
    @State private var showingSetup = false
    @State private var showingSupport = false
    @State private var showingNotebook = false
    @State private var reviewingSet: SetReviewDraft?
    @State private var diagnosticsPending = false
    @State private var now = ProcessInfo.processInfo.systemUptime

    var body: some View {
        Group {
            if developerMode {
                ContentView(model: capture, toggleInterface: { developerMode = false })
            } else {
                workoutInterface
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

    private var workoutInterface: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if let result = workout.result {
                        summary(result)
                    } else if workout.isRunning {
                        live
                    } else {
                        ready
                    }
                    if let error = workout.error ?? capture.latestError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 24)
                .frame(minHeight: max(0, geometry.size.height - 110), alignment: .top)
            }
            .background {
                Color(.systemBackground).ignoresSafeArea()
                    .overlay {
                        RadialGradient(colors: [LiftStyle.blue.opacity(0.09), .clear],
                                       center: .init(x: 0.5, y: 0.38), startRadius: 30, endRadius: 360)
                            .ignoresSafeArea()
                    }
            }
            .safeAreaInset(edge: .bottom) { bottomControls.padding(.horizontal, 26).padding(.bottom, 12) }
        }
        .foregroundStyle(.primary).tint(LiftStyle.blue)
        .sheet(isPresented: $showingSetup, onDismiss: openPendingDiagnostics) { setupSheet }
        .sheet(isPresented: $showingSupport, onDismiss: openPendingDiagnostics) {
            LiftSupportView(status: statusText) { diagnosticsPending = true; showingSupport = false }
        }
        .sheet(isPresented: $showingDiagnostics) {
            ContentView(model: capture).safeAreaInset(edge: .bottom) {
                Button("Done") { showingDiagnostics = false }.buttonStyle(.borderedProminent).padding()
            }
        }
        .sheet(isPresented: $showingNotebook) { WorkoutNotebookView(store: workout.history) }
        .sheet(item: $reviewingSet) { draft in
            SetReviewView(draft: draft) { load, reps, rir in
                let saved = workout.confirmSet(draft, loadLB: load, reps: reps, repsInReserve: rir)
                if saved {
                    reviewingSet = nil
                    DispatchQueue.main.async { reviewingSet = workout.pendingSetReviews.first }
                }
                return saved
            }
        }
        .onChange(of: workout.pendingSetReviews) { _, reviews in
            if reviewingSet == nil { reviewingSet = reviews.first }
        }

    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Button { developerMode = true } label: {
                    Text("liftpod").font(.system(size: 15, weight: .semibold))
                        .frame(minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel("Switch to developer interface")
                    .accessibilityIdentifier("interface-toggle")
                if workout.isRunning {
                    Text("Set \(workout.completedSets.count + 1)").font(.caption)
                }
                if workout.isRunning { statusPill }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if workout.isRunning {
                    Text(clock(workout.elapsedTime)).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7).glass(radius: 14)
                        .accessibilityLabel("Workout elapsed time \(clock(workout.elapsedTime))")
                } else {
                    statusPill
                }
                Button { showingNotebook = true } label: {
                    Image(systemName: workout.pendingSetReviews.isEmpty ? "book.closed" : "book.closed.fill")
                        .font(.title3).frame(minWidth: 32, minHeight: 32)
                }.accessibilityLabel("Workout notebook")
                    .accessibilityIdentifier("workout-notebook")
            }
            if !workout.isRunning {
                Button { showingSupport = true } label: {
                    Image(systemName: "questionmark.circle").font(.title3).frame(minWidth: 32, minHeight: 32)
                }.accessibilityLabel("Support")
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 28)
            LiftHalo(reps: nil, connected: signalLive)
                .frame(maxWidth: 290).padding(.horizontal, 16)
            Text(readyInstruction).font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
            Button { showingSetup = true } label: {
                VStack(spacing: 6) {
                    Text(workout.prescription.exercise.rawValue).font(.subheadline.weight(.semibold))
                    Text("\(workout.prescription.loadLB.formatted()) lb · \(workout.prescription.minimumReps)–\(workout.prescription.maximumReps) reps")
                        .font(.footnote).foregroundStyle(.secondary)
                    Label("Workout setup", systemImage: "slider.horizontal.3").font(.footnote)
                }.frame(maxWidth: .infinity).padding(18).glass(radius: 22)
            }.buttonStyle(.plain).accessibilityIdentifier("workout-setup")
            Spacer(minLength: 12)
        }
    }

    private var live: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 20)
            Text(workout.activePrescription.exercise.rawValue.uppercased())
                .font(.system(size: 18, weight: .semibold)).tracking(2.2).multilineTextAlignment(.center)
            LiftHalo(reps: workout.reps, connected: signalLive).frame(maxWidth: 310).padding(.horizontal, 8)
            VStack(spacing: 8) {
                if workout.state == .preparing {
                    Text("Hold still at the starting position.")
                    Text("Preparing the sensor · at least 3 seconds").font(.footnote)
                } else if workout.state == .finalizing {
                    Text("Finishing your recording…")
                } else if let remaining = workout.timeoutRemaining {
                    if let pace = workout.currentPace {
                        Text("Average pace: \(pace.formatted(.number.precision(.fractionLength(1)))) seconds")
                    }
                    Text("Set ends in \(Int(ceil(remaining)))s without another rep").font(.footnote)
                } else {
                    Text(workout.completedSets.isEmpty ? "Your first complete rep starts the set." : "Set complete. Ready for your next set.")
                    if let rest = workout.restStart {
                        HStack(spacing: 8) {
                            Text("Rest · \(clock(workout.sourceTime - rest))")
                            if let recommendation = workout.restRecommendation {
                                Text("Suggested \(clock(Double(recommendation.seconds)))")
                                    .fontWeight(.semibold).foregroundStyle(LiftStyle.blue)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(LiftStyle.blue.opacity(0.11), in: Capsule())
                            } else if !workout.pendingSetReviews.isEmpty {
                                Text("Confirm RIR for rest target").font(.footnote)
                            }
                        }.monospacedDigit()
                    }
                }
            }.font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if workout.session?.current == nil && workout.state == .active {
                Button("Adjust next set") { showingSetup = true }.font(.subheadline)
            }
            if let pending = workout.pendingSetReviews.first {
                Button("Review completed set") { reviewingSet = pending }
                    .font(.subheadline.weight(.semibold))
            }
            if let last = workout.completedSets.last {
                Text("Last set · \(last.reps.count) reps · \(last.prescription.loadLB.formatted()) lb")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
    }

    private func summary(_ result: WorkoutSetResult) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 9) {
                Text(result.interrupted ? "Workout interrupted" : "Workout complete")
                    .font(.system(size: 32, weight: .semibold)).tracking(-1)
                Text("\(result.reps) reps · \(workout.completedSets.count) sets · \(clock(workout.elapsedTime))")
                    .font(.system(size: 17)).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.top, 20)
            VStack(alignment: .leading, spacing: 0) {
                if workout.completedSets.isEmpty { Text("No complete reps recorded.").foregroundStyle(.secondary) }
                ForEach(Array(workout.completedSets.enumerated()), id: \.element.id) { index, set in
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 0) {
                            Circle().fill(LiftStyle.blue).frame(width: 10, height: 10).padding(.top, 6)
                            Rectangle().fill(LiftStyle.blue.opacity(0.25)).frame(width: 1.5)
                                .opacity(index == workout.completedSets.count - 1 ? 0 : 1)
                        }.frame(width: 11)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(index + 1). \(set.prescription.exercise.rawValue)")
                                .font(.system(size: 19, weight: .medium))
                            Text("\(set.reps.count) reps · \(set.averageDuration.formatted(.number.precision(.fractionLength(1)))) sec average")
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                            Text("\(set.prescription.loadLB.formatted()) lb · target \(set.prescription.minimumReps)–\(set.prescription.maximumReps)\(set.interrupted ? " · interrupted" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.bottom, index == workout.completedSets.count - 1 ? 0 : 24)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 26)
            VStack(spacing: 14) {
                metric("Active rep time", clock(workout.activeTime))
                Divider()
                metric("Average pace", result.averageRepDuration.map { "\($0.formatted(.number.precision(.fractionLength(1)))) sec per rep" } ?? "—")
            }.padding(22).glass(radius: 24)
            if let url = workout.sessionURL {
                ShareLink(item: url) { Label("Share workout", systemImage: "square.and.arrow.up") }.font(.subheadline)
            }
            if let pending = workout.pendingSetReviews.first {
                Button("Review \(workout.pendingSetReviews.count) unconfirmed set\(workout.pendingSetReviews.count == 1 ? "" : "s")") {
                    reviewingSet = pending
                }.buttonStyle(LiftPrimaryStyle())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var bottomControls: some View {
        if workout.result != nil {
            Button("Done") { workout.reset() }.buttonStyle(LiftPrimaryStyle())
        } else if workout.isRunning {
            HStack(spacing: 10) {
                Button(workout.state == .preparing ? "Cancel" : "End set") {
                    if workout.state == .preparing { Task { await workout.cancelPreparation() } }
                    else { workout.endSet() }
                }.buttonStyle(LiftPrimaryStyle(secondary: true))
                    .disabled(workout.busy || workout.state == .finalizing || (workout.state == .active && workout.session?.current == nil))
                Button(workout.state == .finalizing ? "Finishing…" : "Finish") { Task { await workout.end() } }
                    .buttonStyle(LiftPrimaryStyle()).disabled(workout.state != .active || workout.busy)
            }.padding(8).glass(radius: 26)
        } else {
            Button(primaryLabel) {
                if !capture.monitoringActive { capture.startMotion() }
                else if !workout.mountConfirmed || !workout.prescription.isValid || !workout.supportedExercise { showingSetup = true }
                else { Task { await workout.start(capture) } }
            }.buttonStyle(LiftPrimaryStyle())
                .disabled(capture.monitoringActive && !needsSetup && (!signalLive || capture.recordingActive))
                .accessibilityIdentifier("start-workout")
        }
    }

    private var setupSheet: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    Picker("Exercise", selection: $workout.prescription.exercise) {
                        ForEach(V2Exercise.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(workout.isRunning)
                    if !workout.supportedExercise { Text("This exercise profile is not available yet.").foregroundStyle(.secondary) }
                    Picker("Goal", selection: $workout.prescription.goal) {
                        ForEach(TrainingGoal.allCases) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text("Load (lb)")
                        TextField("Load", value: $workout.prescription.loadLB, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityIdentifier("workout-load")
                    }
                    Stepper("Minimum reps: \(workout.prescription.minimumReps)", value: $workout.prescription.minimumReps, in: 1...workout.prescription.maximumReps)
                    Stepper("Maximum reps: \(workout.prescription.maximumReps)", value: $workout.prescription.maximumReps, in: workout.prescription.minimumReps...100)
                }
                if !workout.isRunning {
                    Section("Mount") {
                        Toggle("Right AirPod and mount confirmed", isOn: $workout.mountConfirmed)
                        Text("Use the tested curl mounting orientation. Exercise selection is manual.").font(.footnote)
                    }
                    Section { Button("Open diagnostics") { diagnosticsPending = true; showingSetup = false } }
                }
                Section {
                    Text("Sets end after 12 seconds without a completed rep. Goals and targets are recorded only.")
                    if !workout.prescription.isValid { Text("Enter a load from 0 to 1,000 lb and a valid rep range.").foregroundStyle(.orange) }
                }.font(.footnote)
                if let prediction = workout.loadPrediction() {
                    Section("Load estimate") {
                        Text("\(prediction.source.loadLB.formatted()) lb × \(prediction.source.reps)" +
                             (prediction.source.repsInReserve.map { " @ \($0) RIR" } ?? ""))
                        Button("Use estimated \(prediction.loadLB.formatted()) lb") {
                            workout.prescription.loadLB = prediction.loadLB
                        }
                        Text("\(prediction.confidence.rawValue) from \(prediction.sourceCount) confirmed " +
                             (prediction.sourceCount == 1 ? "set" : "sets") +
                             ". Uses a public-data load curve with reps + RIR. Always verify the load.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Workout setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if workout.isRunning { workout.updateNextSet() }
                    showingSetup = false
                }.disabled(!workout.prescription.isValid || !workout.supportedExercise)
            } }
        }.tint(LiftStyle.blue)
    }

    private func openPendingDiagnostics() {
        if diagnosticsPending { diagnosticsPending = false; showingDiagnostics = true }
    }

    private var needsSetup: Bool {
        !workout.mountConfirmed || !workout.prescription.isValid || !workout.supportedExercise
    }
    // The redraw timer can precede the newest sample. Read uptime at evaluation,
    // rather than comparing a fresh callback against the previous timer tick.
    private var liveSensor: HeadphoneSensorLocation? {
        capture.liveSensor(now: max(now, ProcessInfo.processInfo.systemUptime))
    }
    private var signalLive: Bool { liveSensor == .rightHeadphone }
    private var statusText: String {
        if let sensor = liveSensor {
            switch sensor {
            case .rightHeadphone: return "Right AirPod live"
            case .leftHeadphone: return "Left AirPod live"
            default: return "Motion live · side unknown"
            }
        }
        if capture.connectionState == .disconnected { return "AirPod disconnected" }
        return capture.monitoringActive ? "Waiting for motion…" : "AirPod not connected"
    }
    private var readyInstruction: String {
        if capture.recordingActive { return "Stop raw recording in diagnostics to begin." }
        if !capture.monitoringActive { return "Connect your AirPod to begin." }
        if liveSensor == .leftHeadphone {
            return "Motion is coming from the left AirPod. This curl profile needs the right AirPod. Put the left AirPod in its case, then reconnect motion."
        }
        if let sensor = liveSensor, sensor != .rightHeadphone {
            return "Motion is arriving, but iOS has not identified the AirPod side. Reconnect the right AirPod."
        }
        if !signalLive { return "Waiting for AirPods motion. Bluetooth audio connection alone does not confirm a live motion stream." }
        return workout.mountConfirmed ? "Secure the AirPod in the mount." : "Confirm your mount in workout setup."
    }
    private var primaryLabel: String {
        !capture.monitoringActive ? "Connect AirPod" : (needsSetup ? "Review setup" : "Start workout")
    }
    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle().fill(liveSensor != nil ? LiftStyle.blue : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 10).padding(.vertical, 7).glass(radius: 14)
    }
    private func metric(_ name: String, _ value: String) -> some View {
        HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium).monospacedDigit() }.font(.system(size: 15))
    }
    private func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct SetReviewView: View {
    let draft: SetReviewDraft
    let confirm: (Double, Int, Int?) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var loadLB: Double
    @State private var reps: Int
    @State private var repsInReserve: Int?

    init(draft: SetReviewDraft, confirm: @escaping (Double, Int, Int?) -> Bool) {
        self.draft = draft
        self.confirm = confirm
        _loadLB = State(initialValue: draft.loadLB)
        _reps = State(initialValue: draft.detectedReps)
        _repsInReserve = State(initialValue: nil)
    }

    private var valid: Bool {
        loadLB.isFinite && (0...1000).contains(loadLB) && (1...100).contains(reps)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Exercise", value: draft.exercise.rawValue)
                    LabeledContent("Detected reps", value: "\(draft.detectedReps)")
                    if let duration = draft.averageRepDuration {
                        LabeledContent("Average rep", value: "\(duration.formatted(.number.precision(.fractionLength(1)))) sec")
                    }
                } header: { Text("Detected set") }
                Section("Confirm or edit") {
                    HStack {
                        Text("Weight (lb)")
                        TextField("Weight", value: $loadLB, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Stepper("Reps: \(reps)", value: $reps, in: 1...100)
                    Picker("Reps in reserve", selection: $repsInReserve) {
                        Text("Not entered").tag(Int?.none)
                        ForEach(0...10, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    Text("RIR means how many more good reps you believe you could have completed. It improves future load and suggested-rest estimates.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Confirm set") {
                        if confirm(loadLB, reps, repsInReserve) { dismiss() }
                    }.disabled(!valid)
                        .accessibilityIdentifier("confirm-workout-set")
                }
            }
            .navigationTitle("Review set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }.tint(LiftStyle.blue)
    }
}

private struct WorkoutNotebookView: View {
    @ObservedObject var store: WorkoutHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.days.isEmpty {
                    ContentUnavailableView("No confirmed workouts", systemImage: "book.closed",
                                           description: Text("Confirmed sets will appear here by day."))
                } else {
                    List {
                        ForEach(store.days) { day in
                            Section {
                                ForEach(day.sets) { set in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(set.exercise.rawValue).font(.headline)
                                            Spacer()
                                            Text(set.performedAt, format: .dateTime.hour().minute())
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text("\(set.loadLB.formatted()) lb × \(set.reps) reps" +
                                             (set.repsInReserve.map { " · \($0) RIR" } ?? ""))
                                            .font(.subheadline)
                                        if let duration = set.averageRepDuration {
                                            Text("\(duration.formatted(.number.precision(.fractionLength(1)))) sec average rep")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(.vertical, 5)
                                }
                            } header: {
                                HStack {
                                    Text(day.date.formatted(date: .abbreviated, time: .omitted))
                                    Spacer()
                                    Text("\(day.sets.count) sets · \(day.totalVolumeLB.formatted()) lb")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Workout notebook")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(LiftStyle.blue)
    }
}

private struct LiftHalo: View {
    let reps: Int?
    let connected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                .shadow(color: LiftStyle.blue.opacity(0.07), radius: 28, y: 18)
            Circle().stroke(LiftStyle.blue.opacity(connected ? 0.12 : 0.04), lineWidth: 1).padding(15)
            Circle().fill(LiftStyle.blue.opacity(connected ? 0.035 : 0.01)).padding(42)
            Circle().stroke(connected ? LiftStyle.blue.opacity(0.45) : Color.secondary.opacity(0.18), lineWidth: 1.5)
                .padding(28).scaleEffect(pulse ? 1.055 : 1)
            if let reps {
                VStack(spacing: 2) {
                    Text("\(reps)").font(.system(size: 112, weight: .medium, design: .default)).tracking(-5)
                        .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1).contentTransition(.numericText())
                    Text("REPS").font(.system(size: 12, weight: .semibold)).tracking(2.3).foregroundStyle(.secondary)
                }.padding(45).accessibilityElement(children: .ignore).accessibilityLabel("\(reps) completed reps")
                    .accessibilityIdentifier("workout-reps")
            } else {
                VStack(spacing: 14) {
                    Circle().stroke(LiftStyle.blue.opacity(0.6), lineWidth: 1.5).frame(width: 14, height: 14)
                    Image(systemName: "dumbbell.fill").font(.system(size: 66, weight: .regular))
                }.offset(y: -10).accessibilityHidden(true)
            }
        }.aspectRatio(1, contentMode: .fit)
        .task(id: reps) {
            guard !reduceMotion, let reps, reps > 0 else { return }
            withAnimation(.easeOut(duration: 0.2)) { pulse = true }
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeOut(duration: 0.4)) { pulse = false }
        }
    }
}

private struct LiftPrimaryStyle: ButtonStyle {
    var secondary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity).frame(minHeight: 56)
            .foregroundStyle(enabled ? (secondary ? Color.primary : .white) : Color.secondary)
            .background(enabled ? (secondary ? Color(.secondarySystemBackground).opacity(0.8) : LiftStyle.blue.opacity(configuration.isPressed ? 0.8 : 0.94)) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: enabled && !secondary ? LiftStyle.blue.opacity(0.18) : .clear, radius: 12, y: 6)
    }
}

private extension View {
    func glass(radius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.primary.opacity(0.045), lineWidth: 1))
    }
}

private struct LiftSupportView: View {
    let status: String
    let diagnostics: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let topics: [(String, String, String)] = [
        ("AirPod won’t connect", "airpodspro", "Pair the AirPods with this iPhone, then tap Connect AirPod. LiftPod requires live motion from the right AirPod. Check Motion & Fitness permission in Settings."),
        ("Mount and fit", "dumbbell.fill", "Secure the right AirPod in the tested curl orientation and confirm the mount in Workout setup. For outside-ear testing, disable Automatic Ear Detection in iOS Settings."),
        ("How sets end", "timer", "The first complete rep starts a set. Twelve seconds without another completed rep ends it. The next complete rep starts a new set. End set remains available as a manual control."),
        ("Reps stopped counting", "waveform.path.ecg", "Check the live motion status and mounting orientation. An interrupted workout retains confirmed reps. Finish or return to setup, reconnect, and start a new workout. Diagnostics shows raw motion and the experimental signal lab.")
    ]
    var body: some View {
        NavigationStack {
            List {
                Section { Text("LiftPod · \(status)").foregroundStyle(.secondary) }
                Section("Devices & workouts") {
                    ForEach(topics.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) || $0.2.localizedCaseInsensitiveContains(query) }, id: \.0) { topic in
                        DisclosureGroup {
                            Text(topic.2).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                        } label: {
                            Label(topic.0, systemImage: topic.1).padding(.vertical, 5)
                        }
                    }
                }
                if !query.isEmpty && !topics.contains(where: { $0.0.localizedCaseInsensitiveContains(query) || $0.2.localizedCaseInsensitiveContains(query) }) {
                    Text("No topics match “\(query)”.").foregroundStyle(.secondary)
                }
            }.searchable(text: $query, prompt: "Search topics")
                .navigationTitle("Support")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Still stuck?").font(.subheadline.weight(.semibold))
                        Button("Open diagnostics", action: diagnostics).buttonStyle(LiftPrimaryStyle())
                    }.padding(18).glass(radius: 22).padding(16)
                }
        }.tint(LiftStyle.blue)
    }
}

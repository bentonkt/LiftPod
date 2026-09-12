import SwiftUI
import Charts

private struct RepSpeedChart: View {
    let series: RepSpeedSeries
    var compact = false

    private var comparison: String {
        guard !series.points.isEmpty else { return "Your rep speeds will appear here" }
        guard series.points.last?.speed != nil else { return "Latest rep speed unavailable or pending" }
        guard let change = series.latestSlowdownPercent else { return "Baseline needs three eligible reps in this pattern" }
        let percentage = abs(change).formatted(.number.precision(.fractionLength(0)))
        if abs(change) < 0.5 { return "Latest rep matches baseline" }
        return "Latest rep: \(percentage)% \(change > 0 ? "slower" : "faster") than baseline"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rep speed").font(.headline)
                Text(series.wholeCycle ? "Estimated whole-rep mean · m/s" : "Estimated lifting mean · m/s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            plot
            Text(comparison).font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .accessibilityIdentifier("rep-speed-comparison")
            if !compact, let baseline = series.baseline {
                Text("Dashed line: first 3 eligible reps in this pattern (\(baseline.formatted(.number.precision(.fractionLength(2)))) m/s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !compact {
                Text("Gaps mean speed is unavailable. Changes in pace do not necessarily mean fatigue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 12 : 18).glass(radius: compact ? 18 : 22)
        .accessibilityIdentifier("rep-speed-chart")
    }

    private var xDomain: ClosedRange<Double> { 0.5...max(4.5, Double(series.points.count) + 0.5) }
    private var yDomain: ClosedRange<Double> {
        0.0...max(0.1, (series.points.compactMap(\.speed).max() ?? 0.5) * 1.2)
    }
    private var repTicks: [Int] {
        Array(stride(from: 1, through: max(4, series.points.count), by: max(1, (series.points.count + 5) / 6)))
    }

    private var plot: some View {
        Chart { marks }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: repTicks) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .chartXAxisLabel("Rep number")
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartLegend(.hidden)
            .frame(height: compact ? 92 : 160)
            .accessibilityLabel("Estimated speed by rep. Gaps indicate unavailable measurements.")
    }

    @ChartContentBuilder private var marks: some ChartContent {
        ForEach(series.points) { point in
            if let speed = point.speed {
                LineMark(x: .value("Rep", point.id), y: .value("Speed", speed),
                         series: .value("Continuous segment", point.segment))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LiftStyle.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Rep", point.id), y: .value("Speed", speed))
                    .foregroundStyle(LiftStyle.blue).symbolSize(32)
            }
        }
        if let baseline = series.baseline {
            RuleMark(y: .value("Baseline", baseline))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }
}

private enum LiftStyle {
    static let blue = Color(red: 49 / 255, green: 91 / 255, blue: 1)
    static let ink = Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255)
    static let secondary = Color(red: 107 / 255, green: 110 / 255, blue: 118 / 255)
}

struct WorkoutView: View {
    @ObservedObject var capture: CaptureModel
    @StateObject private var workout = WorkoutModel()
    @State private var developerMode = false
    @State private var showingDiagnostics = false
    @State private var showingSetup = false
    @State private var showingWeight = false
    @State private var showingReps = false
    @State private var showingSupport = false
    @State private var showingNotebook = false
    @State private var reviewingSet: SetReviewDraft?
    @State private var editingLoggedSet: LoggedWorkoutSet?
    @State private var diagnosticsPending = false
    @State private var now = ProcessInfo.processInfo.systemUptime

    var body: some View {
        Group {
            if developerMode {
                ContentView(model: capture, workoutRecordingDirectory: workout.latestRecordingDirectory,
                            toggleInterface: { developerMode = false })
            } else {
                workoutInterface
            }
        }
        .task {
            workout.bindAutoWorkout(capture)
            while !Task.isCancelled {
                now = ProcessInfo.processInfo.systemUptime
                await workout.checkStaleness(now: now)
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
    }

    private var workoutInterface: some View {
        GeometryReader { geometry in
            Group {
                if workout.isRunning {
                    workoutScreenContent
                        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        workoutScreenContent
                            .padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 24)
                            .frame(minHeight: max(0, geometry.size.height - 110), alignment: .top)
                    }
                }
            }
            .background {
                Color.white.ignoresSafeArea()
                    .overlay {
                        RadialGradient(colors: [LiftStyle.blue.opacity(0.028), .clear],
                                       center: .init(x: 0.5, y: 0.38), startRadius: 30, endRadius: 360)
                            .ignoresSafeArea()
                    }
            }
            .safeAreaInset(edge: .bottom) { bottomControls.padding(.horizontal, 26).padding(.bottom, 12) }
        }
        .foregroundStyle(LiftStyle.ink).tint(LiftStyle.blue)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingWeight) {
            NavigationStack {
                WeightEntryView(loadLB: workout.prescription.loadLB) { load in
                    workout.prescription.loadLB = load
                    workout.updateNextSet()
                }
            }
        }
        .sheet(isPresented: $showingReps) {
            NavigationStack {
                Form {
                    Section("Rep target") {
                        Stepper("Minimum reps: \(workout.prescription.minimumReps)", value: $workout.prescription.minimumReps, in: 1...workout.prescription.maximumReps)
                        Stepper("Maximum reps: \(workout.prescription.maximumReps)", value: $workout.prescription.maximumReps, in: workout.prescription.minimumReps...100)
                    }
                }
                .navigationTitle("Next set reps")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingReps = false }
                } }
            }
        }
        .onChange(of: showingReps) { wasShowing, isShowing in
            if wasShowing && !isShowing { workout.updateNextSet() }
        }
        .sheet(isPresented: $showingSetup, onDismiss: openPendingDiagnostics) { setupSheet }
        .sheet(isPresented: $showingSupport, onDismiss: openPendingDiagnostics) {
            LiftSupportView(status: statusText) { diagnosticsPending = true; showingSupport = false }
        }
        .sheet(isPresented: $showingDiagnostics) {
            ContentView(model: capture, workoutRecordingDirectory: workout.latestRecordingDirectory)
                .safeAreaInset(edge: .bottom) {
                Button("Done") { showingDiagnostics = false }.buttonStyle(.borderedProminent).padding()
            }
        }
        .sheet(isPresented: $showingNotebook) { WorkoutNotebookView(store: workout.history) }
        .sheet(item: $editingLoggedSet) { set in
            NavigationStack {
                WeightEntryView(loadLB: set.loadLB) { workout.updateCompletedWeight(set, loadLB: $0) }
            }
        }
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
    }

    private var workoutScreenContent: some View {
        VStack(spacing: workout.isRunning ? 12 : 24) {
            header
            if let result = workout.result {
                summary(result)
            } else if workout.isRunning {
                live
            } else if let setResult = workout.latestSetResult {
                betweenSets(setResult)
            } else {
                ready
            }
            if let error = workout.error ?? capture.latestError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Button { developerMode = true } label: {
                    Text("liftpod").font(.system(size: 15, weight: .semibold))
                        .frame(minHeight: 44)
                }.buttonStyle(.plain)
                    .disabled(workout.automaticWorkoutActive)
                    .accessibilityLabel("Switch to developer interface")
                    .accessibilityIdentifier("interface-toggle")
                if workout.workoutStarted {
                    Text("Set \(workout.completedSetResults.count + (workout.isRunning ? 1 : 0))").font(.caption)
                }
                if workout.workoutStarted { statusPill }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if workout.workoutStarted {
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
            if !workout.workoutStarted {
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
            VStack(spacing: 12) {
                HStack {
                    exerciseMenu
                    Spacer()
                    weightButton
                }
                Text("\(workout.prescription.minimumReps)–\(workout.prescription.maximumReps) reps · \(workout.prescription.targetRIR) RIR")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { showingSetup = true } label: {
                    Label("Workout setup", systemImage: "slider.horizontal.3").font(.footnote)
                }.accessibilityIdentifier("workout-setup")
            }.padding(18).glass(radius: 22)
            Spacer(minLength: 12)
        }
    }

    private var live: some View {
        VStack(spacing: 12) {
            VStack(spacing: 5) {
                Text(workout.activePrescription.exercise.rawValue.uppercased())
                    .font(.system(size: 18, weight: .semibold)).tracking(2.2)
                Text("\(workout.activePrescription.loadLB.map { "\($0.formatted()) lb · " } ?? "")target \(workout.activePrescription.minimumReps)–\(workout.activePrescription.maximumReps)")
                    .font(.footnote).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
            LiftHalo(reps: workout.learningMovement ? nil : workout.reps,
                     connected: signalLive, learning: workout.learningMovement)
                .frame(maxWidth: 180).padding(.horizontal, 8)
            HStack(spacing: 8) {
                liveMetric("SPEED", workout.liveRepSpeedMPS.map {
                    "\($0.formatted(.number.precision(.fractionLength(2)))) m/s"
                } ?? "—")
                liveMetric("DEGRADATION", workout.liveSpeedDegradationPercent.map {
                    "\($0.formatted(.number.precision(.fractionLength(0))))%"
                } ?? "—")
                liveMetric("RIR", workout.liveRIRDescription ?? "—")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("live-set-metrics")
            RepSpeedChart(series: workout.repSpeedSeries, compact: true)
            VStack(spacing: 8) {
                if workout.automaticWorkoutActive {
                    Text(workout.automaticStatus)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("automatic-workout-status")
                    if workout.learningMovement {
                        Text("Keep moving steadily. Your first reps still count.").font(.footnote)
                    }
                } else if workout.state == .preparing {
                    Text("Hold weight still…").font(.headline).foregroundStyle(.primary)
                    Text("Preparing the sensor").font(.footnote)
                } else if workout.state == .finalizing {
                    Text("Finalizing measurements…").font(.headline).foregroundStyle(.primary)
                } else if workout.learningMovement {
                    Text("Complete three steady reps").font(.headline).foregroundStyle(.primary)
                    Text("Your first reps still count.").font(.footnote)
                } else if workout.reps == 0 {
                    Text("Ready — begin lifting").font(.headline).foregroundStyle(.primary)
                } else {
                    Text(workout.coaching.state.title.uppercased())
                        .font(.system(size: 22, weight: .semibold)).tracking(1.2).foregroundStyle(.primary)
                        .accessibilityIdentifier("workout-coaching-state")
                    Text("Target \(workout.activePrescription.minimumReps)–\(workout.activePrescription.maximumReps) reps").font(.subheadline)
                        .accessibilityIdentifier("workout-coaching-reason")
                }
            }.font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func liveMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .glass(radius: 17)
        .accessibilityElement(children: .combine)
    }

    private func betweenSets(_ set: WorkoutSetResult) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 18)
            VStack(alignment: .leading, spacing: 9) {
                Text(set.interrupted ? "SET INTERRUPTED" : "SET \(workout.completedSetResults.count) COMPLETE")
                    .font(.system(size: 14, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                if workout.automaticWorkoutActive {
                    Label(workout.automaticRecoveryProvisional
                          ? "Recovery · estimated · provisional"
                          : "Recovery · estimated", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LiftStyle.blue)
                        .accessibilityIdentifier("automatic-recovery-provisional")
                }
                Text("\(set.reps) reps")
                    .font(.system(size: 38, weight: .semibold)).tracking(-1)
                setSpeedReadout(set, rir: workout.latestSetRIRDescription, showsRIR: true).font(.subheadline)
                Text(set.targetDescription).font(.subheadline).foregroundStyle(.secondary)
            }.accessibilityIdentifier("set-result")
            if let logged = workout.latestLoggedSet {
                completedSetEditButton(
                    detail: logged.loadLB.map { "Recorded weight: \($0.formatted()) lb" } ?? "Recorded weight: Not entered"
                ) {
                    editingLoggedSet = logged
                }
            } else if let pending = workout.pendingSetReviews.last {
                completedSetEditButton(detail: "Confirm weight, reps, and RIR") { reviewingSet = pending }
            }
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("REST").font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Text(clock(max(0, now - (workout.restStart ?? now))))
                        .font(.system(size: 28, weight: .medium)).monospacedDigit()
                }
                Spacer()
                if let recommendation = workout.restRecommendation ?? RestRecommendation(
                    reps: set.reps, repsInReserve: nil, velocityLossPercent: set.slowdownPercent
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("Recommended rest").font(.caption).foregroundStyle(.secondary)
                        Text(clock(Double(recommendation.seconds)))
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(LiftStyle.blue)
                    }.accessibilityIdentifier("recommended-rest")
                }
            }.padding(18).glass(radius: 22)
            nextSetCard
            if workout.automaticWorkoutActive {
                Text(workout.automaticStatus)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("automatic-workout-status")
            }
            Spacer(minLength: 12)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setSpeedReadout(_ set: WorkoutSetResult, rir: String? = nil,
                                 showsRIR: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent("Average speed", value: set.averageSpeedMPS.map {
                "\($0.formatted(.number.precision(.fractionLength(2)))) m/s"
            } ?? "Not measured")
            LabeledContent("Peak speed", value: set.peakSpeedMPS.map {
                "\($0.formatted(.number.precision(.fractionLength(2)))) m/s"
            } ?? "Not measured")
            LabeledContent("Speed degradation", value: set.slowdownPercent.map {
                "\($0.formatted(.number.precision(.fractionLength(0))))%"
            } ?? "Not measured")
            if showsRIR {
                LabeledContent("RIR", value: rir ?? "Not measured")
            }
        }.monospacedDigit().foregroundStyle(.secondary)
            .accessibilityIdentifier("set-speed-metrics")
    }

    private func summary(_ result: WorkoutSetResult) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 9) {
                Text(result.interrupted ? "Workout interrupted" : "Workout complete")
                    .font(.system(size: 32, weight: .semibold)).tracking(-1)
                Text("\(result.reps) reps · \(workout.completedSetResults.count) sets · \(clock(workout.elapsedTime))")
                    .font(.system(size: 17)).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.top, 20)
            VStack(alignment: .leading, spacing: 0) {
                if workout.completedSetResults.isEmpty { Text("No complete reps recorded.").foregroundStyle(.secondary) }
                ForEach(Array(workout.completedSetResults.enumerated()), id: \.element.id) { index, set in
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 0) {
                            Circle().fill(LiftStyle.blue).frame(width: 10, height: 10).padding(.top, 6)
                            Rectangle().fill(LiftStyle.blue.opacity(0.25)).frame(width: 1.5)
                                .opacity(index == workout.completedSetResults.count - 1 ? 0 : 1)
                        }.frame(width: 11)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(index + 1). \(set.prescription.exercise.rawValue)")
                                .font(.system(size: 19, weight: .medium))
                            Text("\(set.reps) reps · " + (set.prescription.loadLB.map { "\($0.formatted()) lb" } ?? "Weight not entered"))
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                            setSpeedReadout(set).font(.caption)
                            if let plan = set.nextSetPlan {
                                Text(plan.title).font(.caption.weight(.semibold)).foregroundStyle(LiftStyle.blue)
                            }
                        }.padding(.bottom, index == workout.completedSetResults.count - 1 ? 0 : 24)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 26)
            VStack(spacing: 14) {
                metric("Active rep time", clock(workout.activeTime))
                Divider()
                metric("Average pace", result.averageRepDuration.map { "\($0.formatted(.number.precision(.fractionLength(1)))) sec per rep" } ?? "—")
            }.padding(22).glass(radius: 24)
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
        } else if workout.automaticWorkoutActive {
            automaticBottomControls
        } else if workout.isRunning {
            if workout.state == .preparing {
                Button("Cancel") { Task { await workout.cancelPreparation() } }
                    .buttonStyle(LiftPrimaryStyle(secondary: true)).disabled(workout.busy)
            } else if workout.state == .finalizing {
                Button("Finalizing…") { }.buttonStyle(LiftPrimaryStyle()).disabled(true)
            } else {
                Button("End Set") { Task { await workout.endSet() } }
                    .buttonStyle(LiftPrimaryStyle()).disabled(workout.busy)
                    .accessibilityIdentifier("end-set")
            }
        } else if workout.latestSetResult != nil {
            VStack(spacing: 10) {
                if workout.state != .interrupted {
                    Button("Start Next Set") { Task { await workout.startSet(capture) } }
                        .buttonStyle(LiftPrimaryStyle()).accessibilityIdentifier("start-next-set")
                        .disabled(!signalLive || capture.recordingActive)
                }
                HStack(spacing: 10) {
                    if workout.state != .interrupted {
                        Button("Adjust Next Set") { showingSetup = true }
                            .buttonStyle(LiftPrimaryStyle(secondary: true))
                    }
                    Button("Finish Workout") { workout.finishWorkout() }
                        .buttonStyle(LiftPrimaryStyle(secondary: true))
                        .accessibilityIdentifier("finish-workout")
                }
            }
        } else {
            Button(primaryLabel) {
                if workout.automaticSets {
                    if needsSetup { showingSetup = true }
                    else { Task { await workout.startAutomaticWorkout(capture) } }
                } else if !capture.monitoringActive {
                    capture.startMotion()
                } else if needsSetup {
                    showingSetup = true
                } else {
                    Task { await workout.startSet(capture) }
                }
            }.buttonStyle(LiftPrimaryStyle())
                .disabled(primaryDisabled)
                .accessibilityIdentifier("start-set")
        }
    }

    private var automaticBottomControls: some View {
        VStack(spacing: 10) {
            if workout.isRunning {
                Button("End Set Now") { Task { await capture.endAutoSet() } }
                    .buttonStyle(LiftPrimaryStyle())
                    .disabled(workout.automaticState != .running || workout.reps == 0)
                    .accessibilityIdentifier("end-set")
            } else {
                Text(workout.automaticStatus)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("automatic-workout-status")
            }
            HStack(spacing: 10) {
                Button(automaticTrackingControlTitle) {
                    Task {
                        if [.paused, .suspended].contains(workout.automaticState) {
                            await workout.resumeAutomaticTracking()
                        } else {
                            await workout.pauseAutomaticTracking()
                        }
                    }
                }
                .buttonStyle(LiftPrimaryStyle(secondary: true))
                .disabled(![.running, .paused, .suspended].contains(workout.automaticState))
                .accessibilityIdentifier("automatic-tracking-toggle")
                Button("Finish Workout") { Task { await workout.finishAutomaticWorkout() } }
                    .buttonStyle(LiftPrimaryStyle(secondary: true))
                    .accessibilityIdentifier("finish-workout")
            }
        }
    }

    private var weightButton: some View {
        Button { showingWeight = true } label: {
            HStack(spacing: 7) {
                Image(systemName: workout.prescription.loadLB == nil ? "plus.circle.fill" : "dumbbell.fill")
                Text(workout.prescription.loadLB.map { "Weight: \($0.formatted()) lb" } ?? "Add weight")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .opacity(0.75)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(workout.prescription.loadLB == nil ? .white : LiftStyle.blue)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(
                workout.prescription.loadLB == nil ? LiftStyle.blue : LiftStyle.blue.opacity(0.08),
                in: Capsule()
            )
            .overlay(Capsule().stroke(LiftStyle.blue.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workout.prescription.loadLB.map {
            "Change weight, currently \($0.formatted()) pounds"
        } ?? "Add weight")
        .accessibilityHint("Opens weight entry")
        .accessibilityIdentifier("workout-load")
    }

    private var exerciseMenu: some View {
        Menu {
            ForEach(V2Exercise.allCases) { exercise in
                Button {
                    workout.prescription.exercise = exercise
                    workout.updateNextSet()
                } label: {
                    if exercise == workout.prescription.exercise {
                        Label(exercise.rawValue, systemImage: "checkmark")
                    } else {
                        Text(exercise.rawValue)
                    }
                }
            }
            Divider()
            Button { } label: {
                Label("Auto-detect workout — Coming soon", systemImage: "sparkles")
            }
            .disabled(true)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "figure.strengthtraining.traditional")
                Text(workout.prescription.exercise.rawValue)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LiftStyle.blue)
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background(LiftStyle.blue.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(LiftStyle.blue.opacity(0.3), lineWidth: 1))
        }
        .accessibilityLabel("Exercise, \(workout.prescription.exercise.rawValue)")
        .accessibilityHint("Opens exercise selection")
        .accessibilityIdentifier("exercise-selector")
    }

    private func completedSetEditButton(detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit completed set")
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(LiftStyle.blue)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(LiftStyle.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(LiftStyle.blue.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens completed set details")
        .accessibilityIdentifier("edit-completed-set")
    }

    private var setupSheet: some View {
        NavigationStack {
            Form {
                Section("Set control") {
                    Picker("Set control", selection: $workout.automaticSets) {
                        Text("Automatic").tag(true)
                        Text("Manual").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(workout.workoutStarted || workout.automaticWorkoutActive)
                    Text(workout.automaticSets
                         ? "LiftPod detects supported sets and recovery while the app stays open. You can still end a set or finish the workout at any time."
                         : "Start and end each set explicitly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Workout") {
                    Picker("Exercise", selection: $workout.prescription.exercise) {
                        ForEach(V2Exercise.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(workout.isRunning)
                    NavigationLink {
                        WeightEntryView(loadLB: workout.prescription.loadLB) { load in
                            workout.prescription.loadLB = load
                            workout.updateNextSet()
                        }
                    } label: {
                        LabeledContent("Weight", value: workout.prescription.loadLB.map { "\($0.formatted()) lb" } ?? "Add")
                    }
                }
                Section("Planning") {
                    Picker("Goal", selection: $workout.prescription.goal) {
                        ForEach(TrainingGoal.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: workout.prescription.goal) { _, _ in
                        workout.applyGoalDefaults()
                    }
                    Stepper("Minimum reps: \(workout.prescription.minimumReps)", value: $workout.prescription.minimumReps, in: 1...workout.prescription.maximumReps)
                    Stepper("Maximum reps: \(workout.prescription.maximumReps)", value: $workout.prescription.maximumReps, in: workout.prescription.minimumReps...100)
                    Stepper("Target RIR: \(workout.prescription.targetRIR)", value: $workout.prescription.targetRIR, in: 0...4)
                    Picker("Weight increment", selection: $workout.prescription.equipmentIncrementLB) {
                        Text("2.5 lb").tag(2.5)
                        Text("5 lb").tag(5.0)
                        Text("10 lb").tag(10.0)
                    }
                }
                if workout.session == nil {
                    Section("Mount") {
                        Text("Use a secure, consistent mounting orientation. LiftPod learns the repeated movement within each set.")
                            .font(.footnote)
                    }
                    Section {
                        Button("Open diagnostics") { diagnosticsPending = true; showingSetup = false }
                            .disabled(workout.automaticWorkoutActive)
                    }
                }
                Section {
                    Text(workout.automaticSets
                         ? "Set boundaries and recovery are estimated. RIR and available weight increments guide the next set."
                         : "Start and end each set explicitly. RIR and available weight increments guide the next set.")
                    if !workout.prescription.isValid { Text("Enter a valid rep range and, optionally, a weight from 0 to 1,000 lb.").foregroundStyle(.orange) }
                }.font(.footnote)
            }
            .navigationTitle("Workout setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if workout.session != nil { workout.updateNextSet() }
                    showingSetup = false
                }.disabled(!workout.prescription.isValid || !workout.supportedExercise)
            } }
        }.tint(LiftStyle.blue)
    }

    private func openPendingDiagnostics() {
        if diagnosticsPending { diagnosticsPending = false; showingDiagnostics = true }
    }

    private var needsSetup: Bool {
        !workout.prescription.isValid || !workout.supportedExercise
    }
    // The redraw timer can precede the newest sample. Read uptime at evaluation,
    // rather than comparing a fresh callback against the previous timer tick.
    private var liveSensor: HeadphoneSensorLocation? {
        capture.liveSensor(now: max(now, ProcessInfo.processInfo.systemUptime))
    }
    private var signalLive: Bool { liveSensor == .rightHeadphone }
    private var statusText: String {
        if workout.automaticWorkoutActive { return workout.automaticStatus }
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
        if workout.automaticWorkoutActive { return workout.automaticStatus }
        if workout.automaticSets {
            if capture.recordingActive || capture.manualAnalysisActive {
                return "Finish the other recording or analysis session before starting Auto."
            }
            return "Secure the right AirPod in the mount. LiftPod will detect supported sets and recovery automatically."
        }
        if capture.recordingActive { return "Stop raw recording in diagnostics to begin." }
        if !capture.monitoringActive { return "Connect your AirPod to begin." }
        if liveSensor == .leftHeadphone {
            return "Motion is coming from the left AirPod. Workout counting is using the right AirPod. Put the left AirPod in its case, then reconnect motion."
        }
        if let sensor = liveSensor, sensor != .rightHeadphone {
            return "Motion is arriving, but iOS has not identified the AirPod side. Reconnect the right AirPod."
        }
        if !signalLive { return "Waiting for AirPods motion. Bluetooth audio connection alone does not confirm a live motion stream." }
        return "Secure the AirPod in the mount, then start your set."
    }
    private var primaryLabel: String {
        if workout.automaticSets { return needsSetup ? "Review Setup" : "Start Workout" }
        return !capture.monitoringActive ? "Connect AirPod" : (needsSetup ? "Review setup" : "Start First Set")
    }
    private var primaryDisabled: Bool {
        if workout.automaticSets {
            return !needsSetup && (capture.recordingActive || capture.manualAnalysisActive || capture.automaticTrackingActive)
        }
        return capture.monitoringActive && !needsSetup && (!signalLive || capture.recordingActive)
    }
    private var automaticTrackingControlTitle: String {
        [.paused, .suspended].contains(workout.automaticState) ? "Resume Tracking" : "Pause Tracking"
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
    private func nextSetCaption(_ action: NextSetAction) -> String {
        switch action {
        case .keepLoad: "Keep this weight"
        case .lowerLoad: "Try one step lighter"
        case .considerHeavierLoad: "Try one step heavier"
        case .noRecommendation: "Choose your next set"
        }
    }

    private var nextSetCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NEXT SET")
                .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
            exerciseMenu
            HStack(spacing: 8) {
                Button { showingWeight = true } label: {
                    Label(workout.prescription.loadLB.map { "\($0.formatted()) lb" } ?? "Add weight", systemImage: "pencil")
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Edit upcoming set weight")
                .accessibilityIdentifier("workout-load")
                Text("×").font(.title2).foregroundStyle(.secondary)
                Button { showingReps = true } label: {
                    Label(repTargetLabel, systemImage: "pencil")
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Edit upcoming set reps, \(repTargetLabel)")
                .accessibilityIdentifier("workout-reps")
            }
            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 12))
            .font(.subheadline.weight(.semibold)).monospacedDigit()
            Text("Target RIR: \(workout.prescription.targetRIR)")
                .font(.footnote).foregroundStyle(.secondary)
            if let prediction = workout.loadPrediction(), prediction.loadLB != workout.prescription.loadLB {
                Divider()
                Button {
                    workout.use(prediction)
                } label: {
                    Label("Use suggested weight: \(prediction.loadLB.formatted()) lb", systemImage: "arrow.turn.down.right")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .font(.subheadline.weight(.semibold)).buttonStyle(.bordered)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 22)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("next-set-plan")
    }
    private var repTargetLabel: String {
        let minimum = workout.prescription.minimumReps
        let maximum = workout.prescription.maximumReps
        return minimum == maximum ? "\(minimum) reps" : "\(minimum)–\(maximum) reps"
    }
    private func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct WeightEntryView: View {
    let save: (Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(loadLB: Double?, save: @escaping (Double?) -> Void) {
        self.save = save
        _text = State(initialValue: loadLB.map { $0.formatted(.number.grouping(.never)) } ?? "")
    }

    private var parsed: Double? { try? Double(text, format: .number) }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var valid: Bool { isEmpty || parsed.map { $0.isFinite && (0...1000).contains($0) } == true }

    var body: some View {
        Form {
            Section {
                TextField("Weight (lb)", text: $text)
                    .keyboardType(.decimalPad).focused($focused)
                    .accessibilityIdentifier("weight-entry")
            } footer: {
                Text("Optional. Leave blank to track without weight.")
            }
            if !valid { Text("Enter a weight from 0 to 1,000 lb.").foregroundStyle(.orange) }
            Button("Save weight") { save(isEmpty ? nil : parsed); dismiss() }
                .disabled(!valid).accessibilityIdentifier("save-weight")
            Button("Clear weight") { save(nil); dismiss() }
        }
        .navigationTitle("Weight")
        .onAppear { focused = true }
    }
}

private struct SetReviewView: View {
    let draft: SetReviewDraft
    let confirm: (Double?, Int, Int?) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var loadLB: Double?
    @State private var reps: Int
    @State private var repsInReserve: Int?

    init(draft: SetReviewDraft, confirm: @escaping (Double?, Int, Int?) -> Bool) {
        self.draft = draft
        self.confirm = confirm
        _loadLB = State(initialValue: draft.loadLB)
        _reps = State(initialValue: draft.detectedReps)
        _repsInReserve = State(initialValue: draft.automaticRIR?.repsInReserve)
    }

    private var valid: Bool {
        (loadLB.map { $0.isFinite && (0...1000).contains($0) } ?? true) && (1...100).contains(reps)
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
                    NavigationLink {
                        WeightEntryView(loadLB: loadLB) { loadLB = $0 }
                    } label: {
                        LabeledContent("Weight", value: loadLB.map { "\($0.formatted()) lb" } ?? "Add")
                    }
                    Stepper("Reps: \(reps)", value: $reps, in: 1...100)
                    Picker("Reps in reserve", selection: $repsInReserve) {
                        Text("Not entered").tag(Int?.none)
                        ForEach(0...10, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    if let estimate = draft.automaticRIR, reps == draft.detectedReps {
                        LabeledContent("Automatic RIR",
                            value: estimate.cappedAtFourPlus ? "4+" : "\(estimate.repsInReserve)")
                        LabeledContent("Rep speed loss",
                            value: "\(estimate.velocityLossPercent.formatted(.number.precision(.fractionLength(0))))%")
                        LabeledContent("RIR range", value: estimate.rangeDescription)
                    } else {
                        Text(reps != draft.detectedReps
                            ? "Update RIR after editing reps."
                            : "Enter reps in reserve.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let rest = RestRecommendation(
                           reps: reps, repsInReserve: repsInReserve.map { min(4, $0) },
                           velocityLossPercent: reps == draft.detectedReps
                               ? draft.velocityProfile?.velocityLossPercent : nil
                       ) {
                        LabeledContent("Suggested rest", value: restClock(rest.seconds))
                    }
                    Text("RIR = reps left in reserve.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Confirm set") {
                        if confirm(loadLB, reps, repsInReserve) { dismiss() }
                    }.disabled(!valid)
                        .accessibilityIdentifier("confirm-workout-set")
                }
            }
            .onChange(of: reps) { oldValue, _ in
                if oldValue == draft.detectedReps,
                   let automatic = draft.automaticRIR, repsInReserve == automatic.repsInReserve {
                    repsInReserve = nil
                }
            }
            .navigationTitle("Review set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }.tint(LiftStyle.blue)
    }

    private func restClock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
                                        Text((set.loadLB.map { "\($0.formatted()) lb × " } ?? "Weight not entered · ") + "\(set.reps) reps" +
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
                                    Text("\(day.sets.count) sets" + (day.sets.contains { $0.loadLB == nil }
                                        ? " · Volume incomplete" : " · \(day.totalVolumeLB.formatted()) lb"))
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
    var learning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.42)).overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                .shadow(color: LiftStyle.blue.opacity(0.07), radius: 28, y: 18)
            Circle().stroke(LiftStyle.blue.opacity(connected ? 0.12 : 0.04), lineWidth: 1).padding(15)
            Circle().fill(LiftStyle.blue.opacity(connected ? 0.035 : 0.01)).padding(42)
            Circle().stroke(connected ? LiftStyle.blue.opacity(0.45) : Color.secondary.opacity(0.18), lineWidth: 1.5)
                .padding(28).scaleEffect(pulse ? 1.055 : 1)
            if learning {
                VStack(spacing: 6) {
                    Text("—")
                        .font(.system(size: 86, weight: .medium))
                    Text("Detecting exercise...")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }
                .padding(40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Detecting exercise. Complete three steady reps. Your first reps still count.")
                .accessibilityIdentifier("workout-learning-movement")
            } else if let reps {
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
        background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: radius))
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
        ("How sets work", "timer", "Start each set when the weight is still. LiftPod prepares the sensor, then counts only complete reps. Tap End Set when you finish; your exercise, load, and target carry into the next set."),
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

import SwiftUI

private enum LiftStyle {
    static let blue = Color(red: 1, green: 0.29, blue: 0.14)
    static let ink = Color.primary
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.035, alpha: 1) : UIColor(white: 0.95, alpha: 1) })
    static let panel = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.075, alpha: 1) : .white })
    static let secondary = Color(red: 107 / 255, green: 110 / 255, blue: 118 / 255)
}

struct WorkoutView: View {
    @ObservedObject var capture: CaptureModel
    @StateObject private var workout = WorkoutModel()
    @AppStorage("aiCoachEnabled") private var aiCoachEnabled = false
    @AppStorage("aiCoachModel") private var aiCoachModel = "gpt-4.1"
    @State private var aiCoachAPIKey = (try? AICoachKeyStore.read()) ?? ""
    @State private var aiKeyStatus: String?
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
                ContentView(model: capture, workoutRecordingDirectory: workout.summaryURL?.deletingLastPathComponent(), toggleInterface: { developerMode = false })
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
                VStack(spacing: 20) {
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
                    bottomControls
                    Text(workout.isRunning ? "TAP END SET WHEN FINISHED" : readyInstruction)
                        .font(.system(size: 10, design: .monospaced)).tracking(0.8)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let error = workout.error ?? capture.latestError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
                .frame(minHeight: max(0, geometry.size.height - 110), alignment: .top)
            }
            .background(LiftStyle.background.ignoresSafeArea())
        }
        .foregroundStyle(LiftStyle.ink).tint(LiftStyle.blue)
        .font(.system(.subheadline, design: .monospaced))
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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { developerMode = true } label: {
                Text("LIFTPOD").font(.system(size: 15, weight: .bold, design: .monospaced)).tracking(2)
            }.buttonStyle(.plain).accessibilityLabel("Switch to developer interface")
                .accessibilityIdentifier("interface-toggle")
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(liveSensor != nil ? LiftStyle.blue : Color.secondary).frame(width: 6, height: 6)
                Text(liveSensor == .rightHeadphone ? "POD·R" : liveSensor == .leftHeadphone ? "POD·L" : "OFFLINE")
                    .font(.system(size: 10, design: .monospaced)).tracking(1)
            }.foregroundStyle(.secondary).accessibilityLabel(statusText)
            Button { showingSetup = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 36, height: 44) }
                .accessibilityLabel("Workout setup").accessibilityIdentifier("workout-setup")
            Button { showingNotebook = true } label: {
                Image(systemName: workout.pendingSetReviews.isEmpty ? "book.closed" : "book.closed.fill").frame(width: 36, height: 44)
            }.accessibilityLabel("Workout notebook").accessibilityIdentifier("workout-notebook")
            Button { showingSupport = true } label: { Image(systemName: "questionmark.circle").frame(width: 30, height: 44) }
                .accessibilityLabel("Support")
        }.foregroundStyle(.primary)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            MotionTraceView(samples: capture.traceSamples, streaming: liveSensor != nil)
            repReadout(reps: 0, prescription: workout.prescription, label: "READY · NEXT SET", pace: nil)
            RepTargetBar(reps: 0, target: workout.prescription.maximumReps)
            Divider()
            HStack {
                instrumentLabel("RECENT SETS")
                Spacer()
                instrumentLabel("\(workout.history.sets.count) LOGGED")
            }
            if workout.history.sets.isEmpty {
                Text("Your completed sets will appear here.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            ForEach(Array(workout.history.sets.prefix(4))) { set in
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text(set.performedAt, format: .dateTime.hour().minute()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(set.exercise.rawValue).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(set.loadLB.formatted()) LB · \(set.reps)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 18) {
            MotionTraceView(samples: capture.traceSamples, streaming: liveSensor != nil)
            repReadout(reps: workout.reps, prescription: workout.activePrescription,
                       label: "COUNTING · SET \(workout.completedSetResults.count + 1)", pace: workout.currentPace)
            RepTargetBar(reps: workout.reps, target: workout.activePrescription.maximumReps)
            HStack(spacing: 8) {
                liveMetric("SPEED", workout.liveRepSpeedMPS.map { "\($0.formatted(.number.precision(.fractionLength(2)))) m/s" } ?? "—")
                liveMetric("SPEED LOSS", workout.liveSpeedDegradationPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "—")
                liveMetric("TARGET RIR", "\(workout.activePrescription.targetRIR)")
            }.accessibilityIdentifier("live-set-metrics")
            Divider()
            if workout.reps == 0 {
                Text(workout.state == .preparing ? "Hold weight still…" : "Ready — begin lifting")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            }
            Text(workout.state == .finalizing ? "FINALIZING MEASUREMENTS…" : workout.coaching.state.title.uppercased())
                .font(.system(size: 11, design: .monospaced)).tracking(1).foregroundStyle(LiftStyle.blue)
                .accessibilityIdentifier("workout-coaching-state")
        }
    }

    private func instrumentLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
    }

    private func repReadout(reps: Int, prescription: WorkoutPrescription, label: String, pace: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, design: .monospaced)).tracking(1.4)
                .foregroundStyle(workout.isRunning ? LiftStyle.blue : Color.secondary)
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%02d", reps)).font(.system(size: 94, weight: .bold, design: .monospaced))
                        .tracking(-7).minimumScaleFactor(0.5).lineLimit(1).contentTransition(.numericText())
                    Text("REPS").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.accessibilityElement(children: .ignore).accessibilityLabel("\(reps) completed reps").accessibilityIdentifier("workout-reps")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(prescription.exercise.rawValue.uppercased()).foregroundStyle(.primary)
                    Text("\(prescription.loadLB.formatted()) LB · \(prescription.minimumReps)–\(prescription.maximumReps) REPS")
                    Text(pace.map { "TEMPO \($0.formatted(.number.precision(.fractionLength(2)))) s" } ?? "TARGET \(prescription.targetRIR) RIR")
                    if workout.workoutStarted { Text(clock(workout.elapsedTime)) }
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).padding(.bottom, 12)
            }
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
            VStack(alignment: .leading, spacing: 12) {
                repReadout(reps: set.reps, prescription: set.prescription,
                           label: set.interrupted ? "SET INTERRUPTED" : "SET \(workout.completedSetResults.count) COMPLETE",
                           pace: set.averageRepDuration)
                RepTargetBar(reps: set.reps, target: set.prescription.maximumReps)
                HStack {
                    liveMetric("AI ESTIMATED RIR", set.aiAdvice?.estimatedRIR.map(String.init) ?? "—")
                    liveMetric("CONFIDENCE", set.aiAdvice?.confidence.uppercased() ?? (workout.aiLoading ? "ANALYZING" : "UNAVAILABLE"))
                }
                setSpeedReadout(set, rir: set.aiAdvice?.estimatedRIR.map { "\($0) · AI estimate" } ?? (workout.aiLoading ? "Analyzing…" : "Unavailable"), showsRIR: true).font(.subheadline)
                Text(set.targetDescription).font(.subheadline).foregroundStyle(.secondary)
            }.accessibilityIdentifier("set-result")
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
            aiNotes(set)
            if set.aiAdvice?.nextSet == nil, let prediction = workout.loadPrediction() {
                nextSetCard(prediction)
            } else if set.aiAdvice?.nextSet == nil, let plan = set.nextSetPlan {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEXT SET").font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(.secondary)
                    Text(plan.title).font(.system(size: 24, weight: .semibold))
                    Text(nextSetCaption(plan.action)).font(.subheadline).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 24)
                    .accessibilityIdentifier("next-set-plan")
            }
            Spacer(minLength: 12)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func aiNotes(_ set: WorkoutSetResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI COACH NOTES").font(.caption.weight(.semibold)).tracking(1.4)
            if let advice = set.aiAdvice {
                Text(advice.notes).textSelection(.enabled)
                ForEach(advice.validationWarnings ?? [], id: \.self) { warning in
                    Label(warning, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                }
                Text("\(advice.confidence.capitalized) confidence").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(advice.weakPoints.enumerated()), id: \.offset) { _, point in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rep \(point.rep)")
                            .font(.caption.weight(.semibold))
                        Text(point.observation).font(.subheadline)
                        Text(point.cue).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let next = advice.nextSet {
                    Divider()
                    Text("NEXT SET · AI SUGGESTION").font(.caption.weight(.semibold))
                    Text("\(next.loadLB.formatted()) lb × \(next.reps) · \(next.targetRIR) RIR")
                        .font(.title3.weight(.semibold))
                    Button(workout.isNextSetSelected(loadLB: next.loadLB, reps: next.reps, rir: next.targetRIR) ? "Selected" : "Use next set") {
                        workout.useAIAdvice()
                    }.buttonStyle(.bordered)
                        .disabled(workout.prescription.exercise != set.prescription.exercise || workout.isNextSetSelected(loadLB: next.loadLB, reps: next.reps, rir: next.targetRIR))
                    if workout.prescription.exercise != set.prescription.exercise {
                        Text("This suggestion is for \(set.prescription.exercise.rawValue).").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if workout.aiLoading {
                ProgressView("Analyzing your set…")
            } else if set.interrupted || set.reps == 0 {
                Text("AI analysis unavailable for an interrupted or empty set.").foregroundStyle(.secondary)
            } else if !aiCoachEnabled {
                Text("Enable AI coaching in setup to analyze rep speeds and estimate RIR.").foregroundStyle(.secondary)
            }
            if let error = workout.aiError { Text(error).font(.footnote).foregroundStyle(.secondary) }
            if aiCoachEnabled && !workout.aiLoading && !set.interrupted && set.reps > 0 {
                Button(set.aiAdvice == nil ? "Analyze set" : "Refresh analysis") {
                    Task { await workout.analyzeLatestSet(model: aiCoachModel, apiKey: aiCoachAPIKey) }
                }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(22).glass(radius: 24)
        .accessibilityIdentifier("ai-coach-notes")
        .task(id: "\(set.id)-\(aiCoachEnabled)") {
            if aiCoachEnabled && set.aiAdvice == nil {
                await workout.analyzeLatestSet(model: aiCoachModel, apiKey: aiCoachAPIKey)
            }
        }
    }

    private func setSpeedReadout(_ set: WorkoutSetResult, rir: String? = nil,
                                 showsRIR: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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
                            Text("\(set.reps) reps · \(set.prescription.loadLB.formatted()) lb")
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
                VStack(alignment: .leading, spacing: 6) {
                    instrumentLabel("NEXT SET · SELECTED")
                    Text(workout.prescription.exercise.rawValue)
                    Text("\(workout.prescription.loadLB.formatted()) lb × \(workout.prescription.minimumReps == workout.prescription.maximumReps ? String(workout.prescription.maximumReps) : "\(workout.prescription.minimumReps)–\(workout.prescription.maximumReps)") · \(workout.prescription.targetRIR) RIR")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).glass(radius: 14)
                    .accessibilityIdentifier("selected-next-set")
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
                if !capture.monitoringActive { capture.startMotion() }
                else if !workout.prescription.isValid || !workout.supportedExercise { showingSetup = true }
                else { Task { await workout.startSet(capture) } }
            }.buttonStyle(LiftPrimaryStyle())
                .disabled(capture.monitoringActive && !needsSetup && (!signalLive || capture.recordingActive))
                .accessibilityIdentifier("start-set")
        }
    }

    private var setupSheet: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    Picker("Exercise", selection: $workout.prescription.exercise) {
                        ForEach(V2Exercise.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(workout.isRunning)
                    HStack {
                        Text("Load (lb)")
                        TextField("Load", value: $workout.prescription.loadLB, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityIdentifier("workout-load")
                    }
                }
                Section {
                    Toggle("AI coaching", isOn: $aiCoachEnabled)
                    SecureField("OpenAI API key", text: $aiCoachAPIKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save API key on this iPhone") {
                        do {
                            try AICoachKeyStore.save(aiCoachAPIKey)
                            aiKeyStatus = aiCoachAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Saved key removed." : "API key saved."
                        } catch { aiKeyStatus = error.localizedDescription }
                    }
                    if let aiKeyStatus { Text(aiKeyStatus).font(.footnote).foregroundStyle(.secondary) }
                    TextField("GPT model", text: $aiCoachModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("AI coach") } footer: {
                    Text("When enabled, each completed set sends exercise, weight, targets, rep speeds, durations and speed loss directly to OpenAI. No separate server is needed. RIR is an AI estimate. Clear the key and save to remove it from this iPhone.")
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
                    Section { Button("Open diagnostics") { diagnosticsPending = true; showingSetup = false } }
                }
                Section {
                    Text("Start and end each set explicitly. RIR and available weight increments guide the next set.")
                    if !workout.prescription.isValid { Text("Enter a load from 0 to 1,000 lb and a valid rep range.").foregroundStyle(.orange) }
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
            return "Motion is coming from the left AirPod. Workout counting is using the right AirPod. Put the left AirPod in its case, then reconnect motion."
        }
        if let sensor = liveSensor, sensor != .rightHeadphone {
            return "Motion is arriving, but iOS has not identified the AirPod side. Reconnect the right AirPod."
        }
        if !signalLive { return "Waiting for AirPods motion. Bluetooth audio connection alone does not confirm a live motion stream." }
        return "Secure the AirPod in the mount, then start your set."
    }
    private var primaryLabel: String {
        !capture.monitoringActive ? "Connect AirPod" : (needsSetup ? "Review setup" : "Start First Set")
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

    private func nextSetCard(_ prediction: LoadPrediction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEXT SET")
                .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text("\(prediction.loadLB.formatted()) lb × \(prediction.targetReps)")
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Spacer()
                Text("\(prediction.targetRIR) RIR")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(LiftStyle.blue)
            }
            Text(prediction.action == .increase ? "Try one step heavier" : prediction.action == .decrease ? "Try one step lighter" : "Keep this weight").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(workout.isNextSetSelected(loadLB: prediction.loadLB, reps: prediction.targetReps, rir: prediction.targetRIR) ? "Selected" : "Use next set") {
                    workout.use(prediction)
                }
                .font(.subheadline.weight(.semibold))
                .disabled(workout.isNextSetSelected(loadLB: prediction.loadLB, reps: prediction.targetReps, rir: prediction.targetRIR))
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 22)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("next-set-plan")
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
        _repsInReserve = State(initialValue: draft.automaticRIR?.repsInReserve)
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
                    if let estimate = draft.automaticRIR, reps == draft.detectedReps {
                        LabeledContent("Automatic RIR",
                            value: estimate.cappedAtFourPlus ? "4+" : "\(estimate.repsInReserve)")
                        LabeledContent("Rep speed loss",
                            value: "\(estimate.velocityLossPercent.formatted(.number.precision(.fractionLength(0))))%")
                        LabeledContent("Estimated range", value: estimate.rangeDescription)
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

private struct LiftPrimaryStyle: ButtonStyle {
    var secondary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.textCase(.uppercase)
            .font(.system(size: secondary ? 11 : 16, weight: .bold, design: .monospaced)).tracking(secondary ? 0.6 : 2)
            .frame(maxWidth: .infinity).frame(minHeight: secondary ? 46 : 58)
            .foregroundStyle(secondary ? Color.primary : scheme == .dark ? Color.black : Color.white)
            .background(secondary ? Color.clear : scheme == .dark ? LiftStyle.blue : Color(white: 0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(secondary ? 0.2 : 0), lineWidth: 1))
            .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.7 : 1)
    }
}

private extension View {
    func glass(radius: CGFloat) -> some View {
        background(LiftStyle.panel, in: RoundedRectangle(cornerRadius: min(radius, 14)))
            .overlay(RoundedRectangle(cornerRadius: min(radius, 14)).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// Excess reps overwrite the completed target, starting at the left edge.
struct RepTargetProgress: Equatable {
    let reps: Int
    let target: Int
    var segmentCount: Int { max(1, target) }
    var completed: Int { min(max(0, reps), segmentCount) }
    var overflow: Int { min(max(0, reps - segmentCount), segmentCount) }
}

struct RepTargetBar: View {
    let reps: Int
    let target: Int
    var body: some View {
        let progress = RepTargetProgress(reps: reps, target: target)
        Canvas { context, size in
            let gap = min(3.0, size.width / Double(progress.segmentCount) * 0.2)
            let width = (size.width - gap * Double(progress.segmentCount - 1)) / Double(progress.segmentCount)
            for index in 0..<progress.segmentCount {
                let rect = CGRect(x: Double(index) * (width + gap), y: 0, width: width, height: size.height)
                let color: Color = index < progress.overflow ? .purple : index < progress.completed ? LiftStyle.blue : .primary.opacity(0.15)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }.frame(height: 5).padding(.vertical, 3)
            .accessibilityLabel("\(reps) of \(max(1, target)) target reps, \(max(0, reps - max(1, target))) extra reps")
            .accessibilityIdentifier("rep-target-bar")
    }
}

private struct MotionTraceView: View {
    let samples: [RawMotionSample]
    let streaming: Bool
    private var points: [(Double, Double)] {
        samples.compactMap { sample in
            let x = sample.userAccelerationX + sample.gravityX
            let y = sample.userAccelerationY + sample.gravityY
            let z = sample.userAccelerationZ + sample.gravityZ
            let magnitude = sqrt(x*x + y*y + z*z)
            return magnitude.isFinite ? (sample.sourceTimestamp, magnitude) : nil
        }
    }
    var body: some View {
        let values = points
        let rms = values.isEmpty ? nil : sqrt(values.map { $0.1 * $0.1 }.reduce(0, +) / Double(values.count))
        VStack(spacing: 6) {
            HStack {
                Text("ACCEL MAGNITUDE · IMU")
                Spacer(minLength: 4)
                Text(streaming ? "LIVE" : "IDLE")
            }.font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    for fraction in [0.0, 0.5, 1.0] {
                        var line = Path(); line.move(to: CGPoint(x: 0, y: size.height * fraction)); line.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                        context.stroke(line, with: .color(.primary.opacity(0.09)), lineWidth: 0.5)
                    }
                    guard values.count > 1, let end = values.last?.0 else { return }
                    let low = min(0.8, (values.map(\.1).min() ?? 0.8) - 0.05)
                    let high = max(1.2, (values.map(\.1).max() ?? 1.2) + 0.05)
                    var trace = Path()
                    for (index, point) in values.enumerated() {
                        let position = CGPoint(x: max(0, (point.0 - end + 3) / 3) * size.width, y: size.height * (1 - (point.1 - low) / (high - low)))
                        if index == 0 { trace.move(to: position) } else { trace.addLine(to: position) }
                    }
                    context.stroke(trace, with: .color(LiftStyle.blue.opacity(streaming ? 1 : 0.4)), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(streaming ? rms.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? "—" : "—")
                        .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    Text("g RMS").font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                }.padding(4).background(LiftStyle.panel.opacity(0.9))
                if values.isEmpty {
                    Text("WAITING FOR MOTION").font(.system(size: 10, design: .monospaced)).tracking(1)
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: 110)
            HStack { Text("−3.0s"); Spacer(); Text("−2.0s"); Spacer(); Text("−1.0s"); Spacer(); Text("NOW") }
                .font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(.tertiary)
        }.padding(13).glass(radius: 16)
            .accessibilityElement(children: .ignore).accessibilityLabel(streaming ? "Live acceleration graph, \(rms?.formatted() ?? "unknown") g RMS" : "Motion graph idle")
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

import Foundation

struct CandidateAuthorizer: Sendable {
    private(set) var committedIDs = Set<String>()

    mutating func authorize(
        _ candidates: [RepEvidence],
        decision: StableExerciseSelection,
        retentionDuration: Double
    ) -> [RepEvidence] {
        candidates.map { candidate in
            var candidate = candidate
            guard candidate.disposition == .provisional,
                  candidate.exercise == decision.selectedProfile,
                  candidate.completionTimestamp >= decision.supportStartTimestamp,
                  candidate.completionTimestamp >= decision.effectiveFromTimestamp,
                  decision.decisionTimestamp - candidate.completionTimestamp <= retentionDuration,
                  !committedIDs.contains(candidate.id) else { return candidate }
            candidate.disposition = .committed
            committedIDs.insert(candidate.id)
            if decision.decisionTimestamp > candidate.completionTimestamp {
                candidate.qualityFlags.append(.delayedAuthorization)
            }
            return candidate
        }
    }
}

struct ExperimentalProcessorInput: Sendable {
    let samples: [RawMotionSample]
    let sourceFilename: String
    let selection: StableExerciseSelection
    let expectedSensorSide: ExperimentalSensorSide
    let configuration: ExperimentalV1Configuration
}

struct ExperimentalProcessorOutput: Sendable {
    let summary: ExperimentalAnalysisResult
    let trace: ReplayTrace
}

struct ExperimentalV1Processor: Sendable {
    func process(_ input: ExperimentalProcessorInput) throws -> ExperimentalProcessorOutput {
        let core = try analyze(input)
        var transactions: [ReplayTransaction] = []
        transactions.reserveCapacity(input.samples.count)
        var prefix: [RawMotionSample] = []
        for (index, sample) in input.samples.enumerated() {
            prefix.append(sample)
            let prefixInput = ExperimentalProcessorInput(samples: prefix, sourceFilename: input.sourceFilename,
                                                         selection: input.selection,
                                                         expectedSensorSide: input.expectedSensorSide,
                                                         configuration: input.configuration)
            let partial = try? analyze(prefixInput)
            let snapshot = partial?.snapshot ?? DetectionSnapshot(
                committedCount: 0, provisionalCount: 0, rejectedCount: 0,
                quality: .invalidInput, detectorPhase: .unarmed, candidateIDs: []
            )
            transactions.append(ReplayTransaction(
                ingestSequence: index,
                inputEvent: RawMotionEvent(sample),
                resultingOutput: snapshot,
                qualityState: snapshot.quality,
                detectorPhase: snapshot.detectorPhase,
                provisionalCandidateIDs: partial?.summary.candidates
                    .filter { $0.disposition == .provisional }.map(\.id) ?? [],
                stableExerciseState: input.selection,
                detectorVersion: ExperimentalAnalysisResult.detectorVersion,
                sourceFilename: URL(fileURLWithPath: input.sourceFilename).lastPathComponent,
                expectedSensorSide: input.expectedSensorSide,
                configuration: input.configuration,
                neutralReference: partial?.neutral
            ))
        }
        return ExperimentalProcessorOutput(
            summary: core.summary,
            trace: ReplayTrace(schemaVersion: 1, detectorVersion: ExperimentalAnalysisResult.detectorVersion,
                               sourceFilename: URL(fileURLWithPath: input.sourceFilename).lastPathComponent,
                               expectedSensorSide: input.expectedSensorSide,
                               selection: input.selection, configuration: input.configuration,
                               transactions: transactions)
        )
    }

    func analyze(_ input: ExperimentalProcessorInput) throws -> CoreAnalysis {
        guard !input.samples.isEmpty else { throw ExperimentalV1Error.emptyInput }
        let configuration = try input.configuration.validated()
        let resampling = try MotionResampler(configuration: configuration).resample(input.samples)
        guard !resampling.samples.isEmpty else { throw ExperimentalV1Error.emptyInput }

        var allCandidates: [RepEvidence] = []
        var selectedPhase: DetectorPhase = .unarmed
        var selectedNeutral: NeutralReference?
        for exercise in ExperimentalExercise.allCases {
            let profile = ExperimentalProfile.profile(for: exercise, sensorSide: input.expectedSensorSide)
            let result = profile.detectorKind == .endpointProgress
                ? EndpointProgressDetector(profile: profile, configuration: configuration).run(samples: resampling.samples)
                : BiphasicCycleDetector(profile: profile, configuration: configuration).run(samples: resampling.samples)
            allCandidates.append(contentsOf: result.candidates)
            if exercise == input.selection.selectedProfile {
                selectedPhase = result.finalPhase
                selectedNeutral = result.neutralReference
            }
        }
        allCandidates.sort {
            ($0.completionTimestamp, $0.exercise.rawValue, $0.id) <
                ($1.completionTimestamp, $1.exercise.rawValue, $1.id)
        }
        var authorizer = CandidateAuthorizer()
        let candidates = authorizer.authorize(allCandidates, decision: input.selection,
                                              retentionDuration: configuration.candidateRetentionDuration)
        let committed = candidates.filter { $0.disposition == .committed }.count
        let provisional = candidates.filter { $0.disposition == .provisional }.count
        let rejected = candidates.filter { $0.disposition == .rejected }.count
        let rejectionTotals = Dictionary(grouping: candidates.compactMap(\.rejectionReason), by: { $0.rawValue })
            .mapValues(\.count)
        var tracker = SignalQualityTracker(configuration: configuration, expectedSide: input.expectedSensorSide)
        input.samples.forEach { tracker.observe($0) }
        let quality = tracker.state
        let transitions = tracker.transitions
        let summary = ExperimentalAnalysisResult(
            schemaVersion: ExperimentalAnalysisResult.schemaVersion,
            detectorVersion: ExperimentalAnalysisResult.detectorVersion,
            sourceFilename: URL(fileURLWithPath: input.sourceFilename).lastPathComponent,
            profile: ExperimentalProfile.profile(for: input.selection.selectedProfile ?? .bicepsCurl,
                                                 sensorSide: input.expectedSensorSide),
            configuration: configuration,
            inputSampleCount: input.samples.count,
            resampledSampleCount: resampling.samples.count,
            committedCount: committed,
            provisionalCount: provisional,
            rejectedCount: rejected,
            candidates: candidates,
            rejectionTotals: rejectionTotals,
            qualityTransitions: transitions,
            warnings: ["Experimental thresholds are provisional and orientation-dependent."],
            finalQuality: quality,
            finalPhase: selectedPhase
        )
        return CoreAnalysis(summary: summary,
                            snapshot: DetectionSnapshot(committedCount: committed, provisionalCount: provisional,
                                                        rejectedCount: rejected, quality: quality,
                                                        detectorPhase: selectedPhase,
                                                        candidateIDs: candidates.map(\.id)),
                            neutral: selectedNeutral)
    }
}

struct CoreAnalysis {
    let summary: ExperimentalAnalysisResult
    let snapshot: DetectionSnapshot
    let neutral: NeutralReference?
}

actor ExperimentalV1ProcessingService {
    private let processor = ExperimentalV1Processor()
    private let exporter: ExperimentalV1Exporter

    init(directory: URL? = nil) { exporter = ExperimentalV1Exporter(directory: directory) }

    func run(_ input: ExperimentalProcessorInput) throws -> (ExperimentalProcessorOutput, ExperimentalExportURLs) {
        let output = try processor.process(input)
        let urls = try exporter.export(summary: output.summary, trace: output.trace)
        return (output, urls)
    }

    func reset() async { }
}

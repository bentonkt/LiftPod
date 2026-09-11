import Foundation

enum AnnotationCompleteness: String, Codable, Sendable { case complete, partial, abandoned }

struct RepAnnotation: Codable, Sendable, Equatable {
    let exercise: ExperimentalExercise
    let completionTimestamp: Double
    let completeness: AnnotationCompleteness
    let note: String?
}

struct AnnotationSidecar: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let annotations: [RepAnnotation]

    func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw ExperimentalV1Error.invalidAnnotation("unsupported schema version")
        }
        var previous = -Double.infinity
        for annotation in annotations {
            guard annotation.completionTimestamp.isFinite, annotation.completionTimestamp >= 0 else {
                throw ExperimentalV1Error.invalidAnnotation("timestamps must be finite and nonnegative")
            }
            guard annotation.completionTimestamp >= previous else {
                throw ExperimentalV1Error.invalidAnnotation("annotations must be sorted by timestamp")
            }
            previous = annotation.completionTimestamp
        }
        return self
    }
}

struct AnnotationSidecarWriter: Sendable {
    func write(_ sidecar: AnnotationSidecar, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ExperimentalV1Error.annotationFileExists
        }
        let validated = try sidecar.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(validated).write(to: url, options: .withoutOverwriting)
    }
}

struct EvaluationMetrics: Codable, Sendable, Equatable {
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int
    let partialOrAbandonedTriggers: Int
    let precision: Double
    let recall: Double
    let f1: Double
}

struct ExperimentalEvaluator: Sendable {
    let maximumTimestampTolerance: Double

    init(maximumTimestampTolerance: Double = 0.40) {
        self.maximumTimestampTolerance = maximumTimestampTolerance
    }

    func evaluate(candidates: [RepEvidence], annotations sidecar: AnnotationSidecar) throws -> EvaluationMetrics {
        let annotations = try sidecar.validated().annotations
        var unmatchedCandidates = Set(candidates.indices)
        var truePositives = 0
        var falseNegatives = 0
        var partialTriggers = 0

        for annotation in annotations {
            let nearest = unmatchedCandidates
                .filter { candidates[$0].exercise == annotation.exercise }
                .map { ($0, abs(candidates[$0].completionTimestamp - annotation.completionTimestamp)) }
                .filter { $0.1 <= maximumTimestampTolerance }
                .sorted {
                    if $0.1 != $1.1 { return $0.1 < $1.1 }
                    let left = candidates[$0.0]
                    let right = candidates[$1.0]
                    return (left.completionTimestamp, left.id) < (right.completionTimestamp, right.id)
                }
                .first?.0
            switch annotation.completeness {
            case .complete:
                if let nearest { unmatchedCandidates.remove(nearest); truePositives += 1 }
                else { falseNegatives += 1 }
            case .partial, .abandoned:
                if let nearest { unmatchedCandidates.remove(nearest); partialTriggers += 1 }
            }
        }
        let falsePositives = unmatchedCandidates.count + partialTriggers
        let precisionDenominator = truePositives + falsePositives
        let recallDenominator = truePositives + falseNegatives
        let precision = precisionDenominator == 0 ? 0 : Double(truePositives) / Double(precisionDenominator)
        let recall = recallDenominator == 0 ? 0 : Double(truePositives) / Double(recallDenominator)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        return EvaluationMetrics(truePositives: truePositives, falsePositives: falsePositives,
                                 falseNegatives: falseNegatives, partialOrAbandonedTriggers: partialTriggers,
                                 precision: precision, recall: recall, f1: f1)
    }
}

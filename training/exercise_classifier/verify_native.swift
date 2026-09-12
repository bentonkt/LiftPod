import Foundation

@main struct VerifyNative {
    struct Fixture: Decodable {
        let unfilteredPrefix: [[Double]]
        let filteredWindow: [[Double]]
        let expectedFeatures: [Double]
        let expectedProbabilities: [Double]
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = try JSONDecoder().decode(PortableExerciseModel.self,
            from: Data(contentsOf: root.appendingPathComponent("portable_model.json"))).validated()
        let data = try Data(contentsOf: root.appendingPathComponent("preprocessing_fixtures.json"))
        let object = try JSONSerialization.jsonObject(with: data)
        // Accept the existing artifact without changing its keys or samples.
        let records = object as! [[String: Any]]
        var maxFilter = 0.0, maxFeature = 0.0, maxProbability = 0.0
        var durations: [Double] = []
        for record in records {
            var filter = ExerciseFeatures()
            let prefix = record["unfilteredPrefix"] as! [[Double]]
            let window = try prefix.map { try filter.filter($0) }.suffix(200)
            let expectedWindow = record["filteredWindow"] as! [[Double]]
            for (a,b) in zip(window, expectedWindow) {
                for (x,y) in zip(a,b) { maxFilter = max(maxFilter,abs(x-y)) }
            }
            let start = ProcessInfo.processInfo.systemUptime
            let features = try ExerciseFeatures.extract(Array(window))
            let scores = try model.predict(features)
            durations.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            for (x,y) in zip(features, record["expectedFeatures"] as! [Double]) { maxFeature = max(maxFeature,abs(x-y)) }
            let probabilities = record["finalModelProbabilities"] as! [Double]
            for (x,y) in zip(scores, probabilities) { maxProbability = max(maxProbability,abs(x-y)) }
        }
        print("fixtures=\(records.count) filter_error=\(maxFilter) feature_error=\(maxFeature) probability_error=\(maxProbability) desktop_p95_ms=\(durations.sorted()[Int(Double(durations.count-1)*0.95)])")
        guard records.count == 69, maxFilter < 1e-10, maxFeature < 1e-8, maxProbability <= 1e-4 else {
            throw ClassifierError.invalidModel
        }
    }
}

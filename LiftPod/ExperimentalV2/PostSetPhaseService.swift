import Foundation

/// Serial background analysis. Derived sidecars never enter the recording's hashes.
actor PostSetPhaseService {
    static let shared = PostSetPhaseService()
    private enum Scan: Error { case finished }

    func run(directory: URL, setID: UUID? = nil,
             counted supplied: [PostSetPhaseAnalysis.CountedRep]? = nil,
             reportedCount: Int? = nil) -> PostSetPhaseAnalysis {
        var id = setID ?? UUID()
        var fingerprint = "unavailable"
        let output = supplied == nil ? directory : directory.appendingPathComponent("phase-results/\(id.uuidString)")
        do {
            let decoder = JSONDecoder()
            let counted: [PostSetPhaseAnalysis.CountedRep]
            if let supplied { counted=supplied }
            else {
                let config=try decoder.decode(GenericSessionConfiguration.self,from:Data(contentsOf:directory.appendingPathComponent("generic-configuration.json")))
                id=setID ?? config.setID
                let summary=try decoder.decode(GenericSessionSummary.self,from:Data(contentsOf:directory.appendingPathComponent("summary.json")))
                counted=summary.events.map { .init(id:$0.id,epoch:$0.sourceEpoch,start:$0.startTimestamp,end:$0.completionTimestamp) }
            }
            let lo = supplied == nil ? -Double.infinity : (counted.map(\.start).min() ?? 0)-3
            let hi = supplied == nil ? Double.infinity : (counted.map(\.end).max() ?? 0)+3
            var samples: [PostSetPhaseSample] = []
            do {
                try GenericFrameHistory.lines(directory.appendingPathComponent("prepared-motion.jsonl")) { data in
                    let frame=try decoder.decode(GenericMotionFrame.self,from:data),s=frame.sample
                    if s.sourceTimestamp>hi { throw Scan.finished }
                    guard s.sourceTimestamp>=lo else { return }
                    guard let a=DevicePathMath.world(s.userAcceleration,attitude:s.attitude),
                          let g=DevicePathMath.world(s.gravity,attitude:s.attitude),
                          (0.75...1.25).contains(s.gravity.magnitude) else {
                        samples.append(.init(time:s.sourceTimestamp,epoch:s.epoch,acceleration:.zero,up:.zero));return
                    }
                    samples.append(.init(time:s.sourceTimestamp,epoch:s.epoch,acceleration:a*9.80665,up:-g/s.gravity.magnitude))
                }
            } catch Scan.finished { }
            fingerprint=GenericHash.of([GenericHash.of(samples),GenericHash.of(counted),String(reportedCount ?? counted.count),"post-set-local-drift-v1"])
            let url=output.appendingPathComponent("post-set-phase-analysis.json")
            if let data=try? Data(contentsOf:url),let cached=try? decoder.decode(PostSetPhaseAnalysis.self,from:data),
               cached.setID==id,cached.sourceFingerprint==fingerprint,cached.schemaVersion==1,
               cached.algorithmVersion=="post-set-local-drift-v1",cached.status != .failed { return cached }
            let result=PostSetPhaseAnalyzer.analyze(setID:id,fingerprint:fingerprint,samples:samples,counted:counted,reportedCount:reportedCount)
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try GenericHash.data(result).write(to:url,options:.atomic)
            return result
        } catch {
            var failure=PostSetPhaseAnalysis(setID:id,sourceFingerprint:fingerprint,status:.failed)
            failure.diagnosticReasons=["Phase analysis unavailable: \(error.localizedDescription)"]
            try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try? GenericHash.data(failure).write(to:output.appendingPathComponent("post-set-phase-analysis.json"),options:.atomic)
            return failure
        }
    }
}

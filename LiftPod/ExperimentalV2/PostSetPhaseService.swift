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
            var prepared: [GenericMotionFrame] = []
            do {
                try GenericFrameHistory.lines(directory.appendingPathComponent("prepared-motion.jsonl")) { data in
                    let frame=try decoder.decode(GenericMotionFrame.self,from:data),s=frame.sample
                    if s.sourceTimestamp>hi { throw Scan.finished }
                    guard s.sourceTimestamp>=lo else { return }
                    prepared.append(frame)
                    guard let a=DevicePathMath.world(s.userAcceleration,attitude:s.attitude),
                          let g=DevicePathMath.world(s.gravity,attitude:s.attitude),
                          (0.75...1.25).contains(s.gravity.magnitude) else {
                        samples.append(.init(time:s.sourceTimestamp,epoch:s.epoch,acceleration:.zero,up:.zero));return
                    }
                    samples.append(.init(time:s.sourceTimestamp,epoch:s.epoch,acceleration:a*9.80665,up:-g/s.gravity.magnitude))
                }
            } catch Scan.finished { }
            fingerprint=GenericHash.of([GenericHash.of(samples),GenericHash.of(prepared),GenericHash.of(counted),String(reportedCount ?? counted.count),PostSetPhaseAnalysis.currentAlgorithmVersion])
            let url=output.appendingPathComponent("post-set-phase-analysis.json")
            if let data=try? Data(contentsOf:url),let cached=try? decoder.decode(PostSetPhaseAnalysis.self,from:data),
               cached.setID==id,cached.sourceFingerprint==fingerprint,cached.schemaVersion==1,
               cached.algorithmVersion==PostSetPhaseAnalysis.currentAlgorithmVersion,cached.status != .failed { return cached }
            var result=PostSetPhaseAnalyzer.analyze(setID:id,fingerprint:fingerprint,samples:samples,counted:counted,reportedCount:reportedCount)
            let speedStarted=ProcessInfo.processInfo.systemUptime
            Self.addSpeeds(to:&result,frames:prepared)
            result.processingSeconds += ProcessInfo.processInfo.systemUptime-speedStarted
            result.summary=PostSetPhaseAnalysis.aggregate(result.reps,counted:counted,reportedCount:reportedCount)
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
    /// Fit speed to the newly estimated physical interval. This synthetic metric
    /// request is never added to the authorization ledger or existing speed/RIR data.
    static func addSpeeds(to result: inout PostSetPhaseAnalysis, frames: [GenericMotionFrame]) {
        for i in result.reps.indices {
            result.reps[i].aMeanSpeedMPS=nil;result.reps[i].bMeanSpeedMPS=nil
            result.reps[i].speedQuality=nil;result.reps[i].speedReason=nil
            let rep=result.reps[i]
            guard rep.eligible else { result.reps[i].speedReason="phase timing unavailable";continue }
            guard rep.aDirection != .unknown, rep.bDirection != .unknown else {
                result.reps[i].speedReason="movement direction unknown";continue
            }
            let window=frames.filter { $0.sample.epoch==rep.epoch && $0.time>=rep.start-0.5 && $0.time<=rep.end+0.6 }
            guard !window.isEmpty,window.allSatisfy({ $0.features.count>=3 && $0.features.prefix(3).allSatisfy(\.isFinite) }) else {
                result.reps[i].speedReason="prepared speed signal unavailable";continue
            }
            var estimator=DevicePathMetrics(configuration:.cyclicDevicePath3D)
            for frame in window { estimator.observePreparedGeneric(frame) }
            let event=GenericCycleEvent(id:rep.countedRepID!,setID:result.setID,sourceEpoch:rep.epoch,
                learningEpoch:0,templateHash:"post-set-phase-metric-only",startTimestamp:rep.start,
                completionTimestamp:rep.end,detectionTimestamp:rep.end,authorizationTimestamp:rep.end,
                matchCost:0,turnaroundTimestamp:rep.reversal)
            let metrics=estimator.estimateGeneric(event,at:window.last!.time,policy:.qualityGradedV2)
            guard metrics.status == .available, let a=metrics.outwardMeanSpeed,let b=metrics.returnMeanSpeed,
                  a.isFinite,b.isFinite,a>0,b>0 else {
                result.reps[i].speedReason=metrics.reason?.rawValue ?? "phase speed unavailable";continue
            }
            result.reps[i].aMeanSpeedMPS=a;result.reps[i].bMeanSpeedMPS=b
            result.reps[i].speedQuality=metrics.speedQuality?.rawValue ?? "estimated"
            result.reps[i].speedReason=metrics.reason?.rawValue
        }
    }

}

import XCTest
@testable import LiftPod

final class PostSetPhaseTests: XCTestCase {
    typealias Analysis = PostSetPhaseAnalysis
    func fixture(_ count: Int = 8, horizontal: Bool = false, hold: Double = 0) -> [PostSetPhaseSample] {
        let period=1.6+2*hold
        return (0..<Int((Double(count)*period+2)*50)).map { i in
            let t=Double(i)*0.02,local=t-1
            var a=0.0
            if local>=0 && local<Double(count)*period {
                let r=local.truncatingRemainder(dividingBy:period)
                if r<0.8 { a=2*cos(.pi*r/0.8) }
                else if r>=0.8+hold && r<1.6+hold { a = -2*cos(.pi*(r-0.8-hold)/0.8) }
            }
            return .init(time:t,epoch:0,acceleration:horizontal ? .init(a,0,0):.init(0,0,a),up:.init(0,0,1))
        }
    }
    func counted(_ count: Int) -> [Analysis.CountedRep] {
        (0..<count).map { .init(id:String($0),epoch:0,start:Double($0)*2,end:Double($0)*2+2) }
    }
    func reps(_ count: Int) -> [Analysis.Rep] {
        (0..<count).map { i in
            var r=Analysis.Rep(epoch:0,start:Double(i)*2,reversal:Double(i)*2+0.5,end:Double(i)*2+2)
            r.countedRepID=String(i);r.reason="estimated";r.aDirection = .raising;r.bDirection = .lowering
            return r
        }
    }
    func testAggregationAndRatios() {
        let s=Analysis.aggregate(reps(6),counted:counted(6))
        XCTAssertTrue(s.observationsEnabled);XCTAssertTrue(s.directionObservationsEnabled)
        XCTAssertEqual(s.a?.median,0.5);XCTAssertEqual(s.b?.median,1.5);XCTAssertEqual(s.ratio?.median,3)
        XCTAssertEqual(s.aChange?.percent,0);XCTAssertEqual(s.coverage,1)
    }
    func testFixedTrendWindowsDoNotBorrowMiddleReps() {
        let rows=Array(reps(9).dropFirst(2))
        let s=Analysis.aggregate(rows,counted:counted(9))
        XCTAssertTrue(s.observationsEnabled);XCTAssertNil(s.aChange)
        XCTAssertEqual(s.missingOrAmbiguousReps,2)
    }
    func testUnknownDirectionsAndCoverageGates() {
        var rows=reps(6);rows[0].aDirection = .unknown;rows[1].bDirection = .unknown
        let s=Analysis.aggregate(rows,counted:counted(6))
        XCTAssertTrue(s.observationsEnabled);XCTAssertFalse(s.directionObservationsEnabled);XCTAssertNil(s.lowering)
        XCTAssertFalse(Analysis.aggregate(Array(rows.prefix(2)),counted:counted(6)).observationsEnabled)
        XCTAssertFalse(Analysis.aggregate(rows,counted:counted(6),reportedCount:7).observationsEnabled)
    }
    func testUnmatchedAndAmbiguousDoNotContribute() {
        var rows=reps(6);rows[0].countedRepID=nil;rows[1].reason="ambiguous association"
        let s=Analysis.aggregate(rows,counted:counted(6))
        XCTAssertEqual(s.eligibleReps,4);XCTAssertEqual(s.unmatchedCandidates,1)
        var candidates=[Analysis.Rep(epoch:0,start:1,reversal:2,end:3)]
        PostSetPhaseAnalyzer.associate(&candidates,counted:[.init(id:"a",epoch:0,start:0,end:2),.init(id:"b",epoch:0,start:2,end:4)])
        XCTAssertFalse(candidates[0].eligible)
    }
    func testSyntheticDirectionAndHorizontalFallback() {
        let vertical=PostSetPhaseAnalyzer.analyze(setID:UUID(),fingerprint:"test",samples:fixture(),counted:[])
        XCTAssertGreaterThanOrEqual(vertical.reps.count,7)
        XCTAssertTrue(vertical.reps.contains { $0.aDirection != .unknown })
        let horizontal=PostSetPhaseAnalyzer.analyze(setID:UUID(),fingerprint:"test",samples:fixture(horizontal:true),counted:[])
        XCTAssertTrue(horizontal.reps.allSatisfy { $0.aDirection == .unknown && $0.bDirection == .unknown })
    }
    func testQuietAndGapDoNotInventCycles() {
        let quiet=fixture().map { PostSetPhaseSample(time:$0.time,epoch:0,acceleration:.zero,up:$0.up) }
        XCTAssertTrue(PostSetPhaseAnalyzer.analyze(setID:UUID(),fingerprint:"test",samples:quiet,counted:[]).reps.isEmpty)
        let frames=fixture().filter { $0.time<5 || $0.time>7 }
        let result=PostSetPhaseAnalyzer.analyze(setID:UUID(),fingerprint:"test",samples:frames,counted:[])
        XCTAssertFalse(result.reps.contains { $0.start<5 && $0.end>7 })
    }
    func testSeparatedConventionsDoNotCreateATrend() {
        var rows=reps(6);rows[5].conventionID=1
        let summary=Analysis.aggregate(rows,counted:counted(6))
        XCTAssertFalse(summary.observationsEnabled);XCTAssertNil(summary.aChange)
    }
    func testServiceCacheAndChangedInputAndFailure() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("phase-service-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let history=try GenericFrameHistory(url:directory.appendingPathComponent("prepared-motion.jsonl"))
        for row in fixture() {
            let sample=ResampledMotionSample(sourceTimestamp:row.time,sessionTime:row.time,sensorSide:.right,
                userAcceleration:.init(x:0,y:0,z:row.acceleration.z/9.80665),rotationRate:.init(x:0,y:0,z:0),
                gravity:.init(x:0,y:0,z:-1),attitude:.init(w:1,x:0,y:0,z:0),interpolationStatus:.delivered,epoch:0)
            try history.append(.init(sample:sample,features:[]))
        }
        let id=UUID(), counted=(0..<8).map { Analysis.CountedRep(id:String($0),epoch:0,start:1+Double($0)*1.6,end:1+Double($0+1)*1.6) }
        let first=await PostSetPhaseService.shared.run(directory:directory,setID:id,counted:counted)
        XCTAssertNotEqual(first.status,.failed)
        let again=await PostSetPhaseService.shared.run(directory:directory,setID:id,counted:counted)
        XCTAssertEqual(first,again)
        let changed=await PostSetPhaseService.shared.run(directory:directory,setID:id,counted:counted,reportedCount:9)
        XCTAssertNotEqual(first.sourceFingerprint,changed.sourceFingerprint)
        XCTAssertFalse(changed.summary.observationsEnabled)
        let failed=await PostSetPhaseService.shared.run(directory:directory.appendingPathComponent("missing"),setID:UUID())
        XCTAssertEqual(failed.status,.failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("prepared-motion.jsonl").path))
    }
    func testDirectionalSpeedMeansUsePairedMappedReps() {
        var rows=reps(6)
        rows[0].aMeanSpeedMPS=0.2;rows[0].bMeanSpeedMPS=0.4
        rows[1].aMeanSpeedMPS=0.6;rows[1].bMeanSpeedMPS=0.8
        rows[1].aDirection = .lowering;rows[1].bDirection = .raising
        rows[2].aMeanSpeedMPS=50;rows[2].bMeanSpeedMPS=50;rows[2].aDirection = .unknown
        rows[3].aMeanSpeedMPS=30;rows[3].bMeanSpeedMPS=30;rows[3].reason="ambiguous association"
        let summary=Analysis.aggregate(rows,counted:counted(6))
        XCTAssertEqual(summary.speedMeasuredReps,2)
        XCTAssertEqual(summary.averageRaisingSpeedMPS!,0.5,accuracy:1e-10)
        XCTAssertEqual(summary.averageLoweringSpeedMPS!,0.5,accuracy:1e-10)
        XCTAssertNil(rows[2].raisingMeanSpeedMPS)
        XCTAssertNil(rows[3].loweringMeanSpeedMPS)
    }
    func testPhaseSpeedUsesNewBoundariesAndExistingQualityGates() {
        var pipeline=GenericFeaturePipeline()
        let frames=fixture().compactMap { row -> GenericMotionFrame? in
            let sample=ResampledMotionSample(sourceTimestamp:row.time,sessionTime:row.time,sensorSide:.right,
                userAcceleration:.init(x:0,y:0,z:row.acceleration.z/9.80665),rotationRate:.init(x:0,y:0,z:0),
                gravity:.init(x:0,y:0,z:-1),attitude:.init(w:1,x:0,y:0,z:0),interpolationStatus:.delivered,epoch:0)
            return pipeline.observe(sample)
        }
        var result=Analysis(setID:UUID(),sourceFingerprint:"speed-test",status:.complete)
        var rep=Analysis.Rep(epoch:0,start:4.2,reversal:5,end:5.8)
        rep.countedRepID="2";rep.reason="estimated";rep.aDirection = .raising;rep.bDirection = .lowering
        result.reps=[rep]
        PostSetPhaseService.addSpeeds(to:&result,frames:frames)
        XCTAssertNotNil(result.reps[0].aMeanSpeedMPS,result.reps[0].speedReason ?? "missing speed")
        XCTAssertNotNil(result.reps[0].bMeanSpeedMPS)
        if let up=result.reps[0].raisingMeanSpeedMPS,let down=result.reps[0].loweringMeanSpeedMPS {
            XCTAssertEqual(up,0.324,accuracy:0.10);XCTAssertEqual(down,0.324,accuracy:0.10)
        }
        var invalid=result;invalid.reps[0].aMeanSpeedMPS=nil;invalid.reps[0].bMeanSpeedMPS=nil
        PostSetPhaseService.addSpeeds(to:&invalid,frames:[])
        XCTAssertNil(invalid.reps[0].raisingMeanSpeedMPS)
    }
    func testRecordedOffAxisSetProducesDirectionalSpeeds() async throws {
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/gravity-phase-speed")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at:fixture,to:directory)
        defer { try? FileManager.default.removeItem(at:directory) }
        let result=await PostSetPhaseService.shared.run(directory:directory)
        XCTAssertEqual(result.algorithmVersion,"post-set-local-gravity-speed-v3")
        XCTAssertEqual(result.summary.countedReps,8)
        XCTAssertEqual(result.summary.directionMappedReps,8)
        XCTAssertEqual(result.summary.unmatchedCandidates,0)
        XCTAssertTrue(result.reps.allSatisfy { $0.proposalSource == "gravity-aligned" })
        XCTAssertLessThan(result.reps[0].axisEnergy,0.8)
        // Direction recovery must not weaken the independent speed-fit gates.
        // Seven cycles still require excessive endpoint correction in this capture.
        XCTAssertEqual(result.summary.speedMeasuredReps,1)
        let rejected=result.reps.filter { $0.aMeanSpeedMPS == nil || $0.bMeanSpeedMPS == nil }
        XCTAssertEqual(rejected.count,7)
        XCTAssertTrue(rejected.allSatisfy { $0.speedReason == "excessiveEndpointCorrection" })
        XCTAssertTrue(rejected.allSatisfy { $0.speedUnavailableExplanation?.contains("drift") == true })
        XCTAssertNotNil(result.summary.averageRaisingSpeedMPS)
        XCTAssertNotNil(result.summary.averageLoweringSpeedMPS)
        print("GRAVITY_RECORDED_RESULT",String(decoding:try JSONEncoder().encode(result),as:UTF8.self))
    }
    func testTinyVerticalLeakageDoesNotLabelHorizontalMotion() {
        let samples=fixture(horizontal:true).map { row in
            PostSetPhaseSample(time:row.time,epoch:row.epoch,
                acceleration:row.acceleration + SIMD3<Double>(0,0,0.05*row.acceleration.x),up:row.up)
        }
        let result=PostSetPhaseAnalyzer.analyze(setID:UUID(),fingerprint:"horizontal-leakage",samples:samples,counted:[])
        XCTAssertFalse(result.reps.isEmpty)
        XCTAssertTrue(result.reps.allSatisfy { $0.aDirection == .unknown && $0.bDirection == .unknown })
        XCTAssertTrue(result.reps.allSatisfy { $0.directionReason?.contains("Too little vertical") == true })
    }
    func testSpecificSpeedExclusionExplanations() {
        var rep=reps(1)[0]
        rep.speedReason="excessiveEndpointCorrection"
        XCTAssertTrue(rep.speedUnavailableExplanation!.contains("drift"))
        rep.speedReason="ambiguousBoundary"
        XCTAssertTrue(rep.speedUnavailableExplanation!.contains("boundaries"))
        rep.speedReason="movement direction unknown";rep.directionReason="No clear up/down reversal was found."
        XCTAssertEqual(rep.speedUnavailableExplanation,rep.directionReason)
        rep.aMeanSpeedMPS=0.5;rep.bMeanSpeedMPS=0.5
        XCTAssertNil(rep.speedUnavailableExplanation)
    }
    func testElapsedMeaningAndJSONRoundTrip() throws {
        var value=Analysis(setID:UUID(),sourceFingerprint:"test",status:.complete)
        value.reps=reps(6);value.summary=Analysis.aggregate(value.reps,counted:counted(6))
        let data=try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(Analysis.self,from:data),value)
        let text=String(decoding:data,as:UTF8.self)
        XCTAssertTrue(text.contains("aSeconds"));XCTAssertTrue(text.contains("percent"));XCTAssertTrue(text.contains("may include pauses"))
        let old=WorkoutSetResult(id:UUID(),prescription:.init(),reps:0,averageRepDuration:nil,movementDuration:nil,interrupted:false,finishedAt:Date())
        XCTAssertNil(try JSONDecoder().decode(WorkoutSetResult.self,from:JSONEncoder().encode(old)).phaseAnalysis)
    }
}

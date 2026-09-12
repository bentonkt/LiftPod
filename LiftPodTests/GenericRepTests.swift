import XCTest
import simd
@testable import LiftPod

final class GenericRepTests: XCTestCase {
    private func frame(_ index: Int, period: Double = 2, amplitude: Double = 0.35, epoch: Int = 0) -> ResampledMotionSample {
        let t = Double(index)/50, phase = 2*Double.pi*t/period
        return .init(sourceTimestamp:t,sessionTime:t,sensorSide:.right,
            userAcceleration:.init(x:amplitude*cos(phase),y:amplitude*0.3*sin(phase),z:0),
            rotationRate:.init(x:0,y:0,z:0),gravity:.init(x:0,y:0,z:-1),
            attitude:.init(w:1,x:0,y:0,z:0),interpolationStatus:.delivered,epoch:epoch)
    }
    private func raw(_ index: Int) -> RawMotionSample {
        let s = frame(index)
        return experimentalRawSample(index:UInt64(index),time:s.sourceTimestamp,side:.rightHeadphone,
            acceleration:s.userAcceleration,gravity:s.gravity,rotation:s.rotationRate)
    }
    private func processor(metrics: Bool = false) throws -> GenericRepProcessor {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("generic-test-\(UUID()).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at:file) }
        return try .init(configuration:.init(setID:UUID(uuidString:"10000000-0000-0000-0000-000000000001")!,
            sensorSide:.right,detector:.init(),metricsEnabled:metrics),history:GenericFrameHistory(url:file))
    }

    func testTranslationLearnsThreeCyclesAndBackfillsWithOriginalTimes() throws {
        var p = try processor()
        var firstBatch: [GenericCycleEvent] = []
        var diagnostics: [String] = []
        for i in 0...510 {
            try p.apply(.init(kind:.sample,raw:RawMotionEvent(raw(i))))
            if firstBatch.isEmpty, !p.events.isEmpty { firstBatch = p.events }
            if i % 50 == 0 { diagnostics.append("\(i): \(String(describing:p.snapshot.generic))") }
        }
        XCTAssertGreaterThanOrEqual(p.events.count,4,diagnostics.joined(separator:"\n"))
        XCTAssertLessThanOrEqual(p.events.count,5)
        XCTAssertGreaterThanOrEqual(firstBatch.count,3)
        XCTAssertTrue(firstBatch.allSatisfy { $0.authorizationTimestamp >= $0.detectionTimestamp && $0.detectionTimestamp >= $0.completionTimestamp })
        XCTAssertLessThan(try XCTUnwrap(firstBatch.first).completionTimestamp,3)
        XCTAssertEqual(p.templates.count,1)
        XCTAssertTrue(p.events.allSatisfy { $0.turnaroundTimestamp == nil })
    }

    func testNoCountsForConstantAccelerationOrQuietAndShortSets() throws {
        for kind in 0..<3 {
            var p = try processor()
            let count = kind == 2 ? 190 : 450
            for i in 0...count {
                let sample = kind == 2 ? raw(i) : experimentalRawSample(index:UInt64(i),time:Double(i)/50,
                    acceleration:.init(x:kind == 0 ? 0 : 0.3,y:0,z:0),gravity:.init(x:0,y:0,z:-1))
                try p.apply(.init(kind:.sample,raw:RawMotionEvent(sample)))
            }
            XCTAssertTrue(p.events.isEmpty)
        }
    }

    func testStreamingMatcherRequiresFullCoverageAndHoldsWithoutCounting() throws {
        let config = GenericRepConfiguration()
        var features = GenericFeaturePipeline()
        let frames = (0...100).compactMap { features.observe(frame($0)) }
        let pattern = try XCTUnwrap(GenericPatternMath.pattern(frames,config:config,epoch:0,frozenAt:2,learnedFrom:[0,2]))
        var tracker = GenericPatternTracker(pattern:pattern,config:config)
        for i in 0...40 { XCTAssertNil(tracker.observe(frames[i],departureAllowed:true)) }
        for i in 41...150 {
            let quiet = ResampledMotionSample(sourceTimestamp:Double(i)/50,sessionTime:Double(i)/50,sensorSide:.right,
                userAcceleration:.init(x:0,y:0,z:0),rotationRate:.init(x:0,y:0,z:0),gravity:.init(x:0,y:0,z:-1),
                attitude:.init(w:1,x:0,y:0,z:0),interpolationStatus:.delivered,epoch:0)
            XCTAssertNil(tracker.observe(.init(sample:quiet,features:frames[40].features),departureAllowed:true))
        }
        XCTAssertEqual(tracker.state,.holding)
    }

    func testEndBoundaryAndMetricsCannotChangeCounting() throws {
        var a = try processor(), b = try processor(metrics:true)
        for i in 0...505 {
            if i == 475 {
                try a.apply(.init(kind:.end,timestamp:9.48)); try b.apply(.init(kind:.end,timestamp:9.48))
            }
            let input = GenericSessionInput(kind:.sample,raw:RawMotionEvent(raw(i)))
            if a.state != .complete { try a.apply(input); try b.apply(input) }
        }
        XCTAssertEqual(a.events,b.events)
        XCTAssertEqual(a.state,.complete)
        XCTAssertTrue(a.events.allSatisfy { $0.completionTimestamp <= 9.48 })
        XCTAssertEqual(b.metrics.count,b.events.count)
        XCTAssertTrue(b.metrics.allSatisfy { $0.status != .pending && $0.outwardDuration == nil })
    }

    func testGapCannotJoinCyclesAndPreservesCommittedEvents() throws {
        var p = try processor()
        for i in 0...350 { try p.apply(.init(kind:.sample,raw:RawMotionEvent(raw(i)))) }
        let before = p.events
        for i in 370...800 { try p.apply(.init(kind:.sample,raw:RawMotionEvent(raw(i)))) }
        XCTAssertEqual(Array(p.events.prefix(before.count)),before)
        XCTAssertFalse(p.events.contains { $0.startTimestamp < 7.4 && $0.completionTimestamp > 7 })
        XCTAssertTrue(p.snapshot.generic?.learningEpoch ?? 0 > 0)
    }

    func testSchemaEightReplaysDetectionAndRejectsTamperedInputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generic-bundle-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let session = GenericRepSession()
        try await session.start(side:.right,metricsEnabled:false,directory:root)
        for i in 0...425 {
            if i == 395 { try await session.apply(.init(kind:.end,timestamp:7.88)) }
            let snapshot = await session.snapshot
            if snapshot?.setState != .complete { try await session.apply(.init(kind:.sample,raw:RawMotionEvent(raw(i)))) }
        }
        let bundle = await session.completedBundle
        let urls = try XCTUnwrap(bundle)
        XCTAssertTrue(try GenericReplayVerifier().verify(directory:urls.directory).passed)
        var lines = try String(contentsOf:urls.transactions,encoding:.utf8).split(separator:"\n").map(String.init)
        var record = try JSONDecoder().decode(GenericSessionTransaction.self,from:Data(lines[50].utf8))
        record = .init(sequence:record.sequence,input:record.input,outputHash:"tampered",decision:record.decision)
        lines[50] = String(decoding:try GenericHash.data(record),as:UTF8.self)
        try (lines.joined(separator:"\n")+"\n").write(to:urls.transactions,atomically:true,encoding:.utf8)
        XCTAssertFalse(try GenericReplayVerifier().verify(directory:urls.directory).passed)
    }

    @MainActor func testGenericModeIsExplicitAndCanStartWithoutProfile() {
        let model = ExperimentalV2Model(preferences:UserDefaults(suiteName:"generic-default-test")!)
        XCTAssertEqual(model.countingMode,.exercise)
        model.countingMode = .generic; model.selectedExercise = .overheadPress; model.setupConfirmed = true
        XCTAssertTrue(model.canStart(motionActive:true,sideVerified:true,otherRecordingActive:false))
    }

    func testDominantSecondHarmonicDoesNotDoubleCountSignedPattern() throws {
        var p = try processor()
        for i in 0...620 {
            let t = Double(i)/50, phase = Double.pi*t
            let sample = experimentalRawSample(index:UInt64(i),time:t,side:.rightHeadphone,
                acceleration:.init(x:0.18*cos(phase)+0.35*cos(2*phase),y:0.18*sin(phase),z:0),gravity:.init(x:0,y:0,z:-1))
            try p.apply(.init(kind:.sample,raw:RawMotionEvent(sample)))
        }
        XCTAssertGreaterThanOrEqual(p.events.count,5)
        XCTAssertLessThanOrEqual(p.events.count,6)
        XCTAssertTrue(p.templates.allSatisfy { $0.duration > 1.5 })
    }

    func testSlowdownAndAmplitudeDeclineDoNotCreateNewLearningEpoch() throws {
        var p = try processor()
        var phase = 0.0
        for i in 0...700 {
            let t = Double(i)/50, fraction = min(1,max(0,(t-7)/5))
            phase += 2*Double.pi/(50*(2+fraction))
            let amp = 0.35*(1-0.2*fraction)
            let sample = experimentalRawSample(index:UInt64(i),time:t,side:.rightHeadphone,
                acceleration:.init(x:amp*cos(phase),y:amp*0.3*sin(phase),z:0),gravity:.init(x:0,y:0,z:-1))
            try p.apply(.init(kind:.sample,raw:RawMotionEvent(sample)))
        }
        XCTAssertGreaterThanOrEqual(p.events.count,5)
        XCTAssertEqual(p.templates.count,1)
        XCTAssertEqual(p.snapshot.generic?.learningEpoch,0)
    }

    func testLearningBeyondTwelveSecondsRetainsMetricsInputs() throws {
        var p = try processor(metrics:true)
        for i in 0...970 {
            let s = frame(i,period:6)
            let sample = experimentalRawSample(index:UInt64(i),time:s.sourceTimestamp,side:.rightHeadphone,
                acceleration:s.userAcceleration,gravity:s.gravity,rotation:s.rotationRate)
            try p.apply(.init(kind:.sample,raw:RawMotionEvent(sample)))
        }
        let first = try XCTUnwrap(p.events.first)
        XCTAssertGreaterThan(first.authorizationTimestamp,12)
        XCTAssertLessThan(first.completionTimestamp,7)
        let result = try XCTUnwrap(p.metrics.first)
        XCTAssertNotEqual(result.reason,.invalidInterval)
        XCTAssertNotEqual(result.reason,.ambiguousBoundary)
        XCTAssertNotEqual(result.status,.pending)
    }

    func testPhysicalTurnaroundComesFromAngularEvidence() throws {
        var pipeline = GenericFeaturePipeline()
        var frames: [GenericMotionFrame] = []
        for i in 0...100 {
            let t = Double(i)/50, theta = 0.6*(1-cos(.pi*t))
            let q = simd_quatd(angle:theta,axis:SIMD3(1,0,0))
            let g = q.inverse.act(SIMD3<Double>(0,0,-1))
            let s = ResampledMotionSample(sourceTimestamp:t,sessionTime:t,sensorSide:.right,
                userAcceleration:.init(x:0,y:0,z:0),rotationRate:.init(x:0.6*Double.pi*sin(.pi*t),y:0,z:0),
                gravity:DevicePathMath.record(g),attitude:.init(w:q.real,x:q.imag.x,y:q.imag.y,z:q.imag.z),
                interpolationStatus:.delivered,epoch:0)
            frames.append(try XCTUnwrap(pipeline.observe(s)))
        }
        XCTAssertEqual(try XCTUnwrap(GenericPhysicalPhases.identify(frames)).turnaround,1,accuracy:0.04)
    }

    func testConfigurationTamperingAndWrongSideFailExplicitly() throws {
        var invalid = GenericRepConfiguration(); invalid.maximumMatchCost = .nan
        XCTAssertThrowsError(try invalid.validated())
        var p = try processor()
        let wrong = experimentalRawSample(index:0,time:0,side:.leftHeadphone)
        try p.apply(.init(kind:.sample,raw:RawMotionEvent(wrong)))
        XCTAssertEqual(p.state,.interrupted); XCTAssertEqual(p.interruption,.wrongSensorSide)
    }

    func testRecordedCurlComparisonReportsProxyReferencesWithoutPromotion() throws {
        for name in ["nine-curl-brief-bottoms","latest-continuous-eight-curl"] {
            let fixture = try ContinuousCaptureFixture.load(name:name)
            var p = try processor()
            for raw in fixture.raw { try p.apply(.init(kind:.sample,raw:RawMotionEvent(raw))) }
            let report = GenericRepEvaluation.measure(events:p.events,
                completions:fixture.legacyCommittedEvents.map(\.completionTimestamp),samples:fixture.uniform)
            print("GENERIC_EVALUATION \(name) \(String(decoding:try GenericHash.data(report),as:UTF8.self))")
            XCTAssertEqual(report.referenceCount,fixture.legacyCommittedEvents.count)
            XCTAssertEqual(report.truePositives+report.falsePositives,report.predictedCount)
            XCTAssertTrue(p.events.allSatisfy { $0.authorizationSource == "set-local-pattern" })
        }
    }

    func testStructuralChangeCreatesNewEpochWithoutChangingOldEvents() throws {
        var p = try processor()
        var before: [GenericCycleEvent] = []
        for i in 0...950 {
            if i == 400 { before = p.events }
            if i < 400 { try p.apply(.init(kind:.sample,raw:RawMotionEvent(raw(i)))); continue }
            let t = Double(i)/50, phase = Double.pi*(t-8)
            let q = simd_quatd(angle:0.4*sin(phase),axis:SIMD3(0,0,1))
            let sample = experimentalRawSample(index:UInt64(i),time:t,side:.rightHeadphone,
                acceleration:.init(x:0,y:0,z:0),gravity:.init(x:0,y:0,z:-1),
                rotation:.init(x:0,y:0,z:0.4*Double.pi*cos(phase)),
                attitude:.init(w:q.real,x:q.imag.x,y:q.imag.y,z:q.imag.z))
            try p.apply(.init(kind:.sample,raw:RawMotionEvent(sample)))
        }
        XCTAssertGreaterThanOrEqual(p.templates.count,2)
        XCTAssertEqual(Array(p.events.prefix(before.count)),before)
        XCTAssertTrue(p.events.contains { $0.learningEpoch == 1 })
    }

    func testRepeatedEndRequestDoesNotTurnIntoRecordingFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generic-end-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let session = GenericRepSession()
        try await session.start(side:.right,metricsEnabled:false,directory:root)
        try await session.apply(.init(kind:.sample,raw:RawMotionEvent(raw(0))))
        try await session.apply(.init(kind:.end,timestamp:0))
        do { try await session.apply(.init(kind:.end,timestamp:0)); XCTFail("second end must be rejected") }
        catch { }
        let state = await session.snapshot?.setState
        XCTAssertEqual(state,.finalizing)
    }
}

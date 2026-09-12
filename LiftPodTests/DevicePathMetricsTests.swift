import XCTest
import simd
@testable import LiftPod

final class DevicePathMetricsTests: XCTestCase {
    func testCyclicPathKnown3DTrajectoriesWithoutHoldsAndWithBias() throws {
        let q=simd_quatd(angle:0.7,axis:SIMD3(1,0,0))*simd_quatd(angle:-0.4,axis:SIMD3(0,1,0))
        for exercise in V2Exercise.allCases {
            for bias in [SIMD3<Double>.zero,SIMD3(0.12,-0.05,0.08)] {
                var observer=PassiveRepMetrics(configuration:.cyclicDevicePath3D)
                let event=event(exercise:exercise)
                // Continuous cycles before/after this rep: no quiet anchor at all.
                for i in 0...180 {
                    let t=Double(i)/50
                    let a=SIMD3<Double>(0.3,-0.2,0.8) * (.pi*cos(.pi*(t-1)))+bias
                    observer.observe(frame(t,acceleration:a,gyro:0.6,attitude:q))
                    observer.observeCommitted(i==155 ? [event] : [],at:t)
                }
                let rep=try XCTUnwrap(observer.snapshot.reps.first)
                XCTAssertEqual(rep.status,.available,"\(String(describing:rep.reason))")
                XCTAssertEqual(rep.measurementKind,"cyclic-device-path-3d")
                XCTAssertEqual(try XCTUnwrap(rep.peakLiftingSpeed),simd_length(SIMD3<Double>(0.3,-0.2,0.8)),accuracy:0.10)
                XCTAssertGreaterThan(try XCTUnwrap(rep.peakLiftingSpeed),try XCTUnwrap(rep.peakVerticalLiftingSpeed))
                XCTAssertLessThanOrEqual(try XCTUnwrap(rep.maximumBoundarySpeedChange),0.10)
            }
        }
    }

    func testCyclicPathRejectsNoncyclicAccelerationAndKeepsLegacyVersion() throws {
        var observer=PassiveRepMetrics(configuration:.cyclicDevicePath3D)
        let event=event(exercise:.bicepsCurl)
        for i in 0...180 {
            let t=Double(i)/50
            observer.observe(frame(t,acceleration:SIMD3(1,0,0.5),gyro:0.6))
            observer.observeCommitted(i==155 ? [event] : [],at:t)
        }
        XCTAssertEqual(observer.snapshot.reps.first?.status,.unavailable)
        XCTAssertEqual(observer.snapshot.reps.first?.reason,.excessiveEndpointCorrection)
        XCTAssertEqual(RepMetricsConfiguration.devicePath3D.version,"device-path-metrics-v1")
        XCTAssertNil(RepMetricsConfiguration.devicePath3D.devicePath?.cyclic)
        XCTAssertEqual(try RepMetricsConfiguration.cyclicDevicePath3D.validated(),.cyclicDevicePath3D)
        var invalid=RepMetricsConfiguration.devicePath3D
        invalid.devicePath?.cyclic = .init()
        XCTAssertThrowsError(try invalid.validated())
    }

    func testCyclicPathCannotReconstructAcrossSourceGap() throws {
        var observer=PassiveRepMetrics(configuration:.cyclicDevicePath3D)
        let event=event(exercise:.bicepsCurl)
        for i in 0...180 where !(70...80).contains(i) {
            let t=Double(i)/50
            observer.observe(frame(t,acceleration:SIMD3(0.3,0,0.8) * (.pi*cos(.pi*(t-1))),gyro:0.6))
            observer.observeCommitted(i==155 ? [event] : [],at:t)
        }
        XCTAssertEqual(observer.snapshot.reps.first?.status,.unavailable)
        XCTAssertEqual(observer.snapshot.reps.first?.reason,.invalidInterval)
    }

    func testThreeRepTempoBaselineAndPublishedValuesStayImmutable() throws {
        var observer=PassiveRepMetrics(configuration:.cyclicDevicePath3D)
        let setID=UUID(uuidString:"10000000-0000-0000-0000-000000000001")!
        for i in 0...530 {
            let t=Double(i)/50
            var acceleration=SIMD3<Double>.zero, moving=false
            var committed:[V2CycleEvidence]=[]
            for rep in 0..<3 {
                let start=1+Double(rep)*3, phase=t-start
                if phase>=0 && phase<2 { acceleration=SIMD3(0.3,0,0.8) * (.pi*cos(.pi*phase));moving=true }
                if i==Int((start+2.1)*50) {
                    committed=[.init(id:"rep-\(rep)",setID:setID,exercise:.overheadPress,
                        authorizationSource:.manual,profileID:"test",dspContentHash:"test",detectorEpoch:0,cycleSequence:rep,
                        startTimestamp:start,topTimestamp:start+1,completionTimestamp:start+2,detectionTimestamp:start+2.1,
                        bottom:0,top:2,returned:0,outboundArea:1,returnArea:1,committed:true,rejectionReason:nil)]
                }
            }
            observer.observe(frame(t,acceleration:acceleration,gyro:moving ? 0.6 : 0))
            observer.observeCommitted(committed,at:t)
        }
        let frozen=observer.snapshot
        XCTAssertEqual(frozen.reps.count,3)
        XCTAssertTrue(frozen.reps.allSatisfy { $0.status == .available },"\(frozen.reps.map(\.reason))")
        XCTAssertNotNil(frozen.baselineMeanLiftingSpeed)
        XCTAssertGreaterThan(try XCTUnwrap(frozen.reps[1].bottomPauseDuration),0.5)
        XCTAssertEqual(try XCTUnwrap(frozen.slowdownPercent(for:frozen.reps[2])),0,accuracy:1)
        for i in 531...580 { let t=Double(i)/50;observer.observe(frame(t,acceleration:.zero,gyro:0));observer.observeCommitted([],at:t) }
        XCTAssertEqual(observer.snapshot.reps,frozen.reps)
        XCTAssertEqual(observer.snapshot.baselineMeanLiftingSpeed,frozen.baselineMeanLiftingSpeed)
    }

    func testQuaternionConventionNoncommutingRotationsAndSignEquivalence() throws {
        let q=simd_quatd(angle:0.7,axis:SIMD3(1,0,0))*simd_quatd(angle:-0.4,axis:SIMD3(0,1,0))
        let world=SIMD3<Double>(0.2,-0.4,0.8), device=q.inverse.act(world)
        let attitude=ExperimentalQuaternion(w:q.real,x:q.imag.x,y:q.imag.y,z:q.imag.z)
        let actual=try XCTUnwrap(DevicePathMath.world(DevicePathMath.record(device),attitude:attitude))
        XCTAssertLessThan(simd_length(actual-world),1e-12)
        let opposite=try XCTUnwrap(DevicePathMath.world(DevicePathMath.record(device),attitude:attitude.negated()))
        XCTAssertLessThan(simd_length(opposite-actual),1e-12)
    }

    func testOneEstimatorProducesSame3DSpeedAcrossExerciseLabelsAndMountRotations() throws {
        let q=simd_quatd(angle:0.7,axis:SIMD3(1,0,0))*simd_quatd(angle:-0.4,axis:SIMD3(0,1,0))
        var reference: RepMotionMetrics?
        for exercise in V2Exercise.allCases {
            for attitude in [simd_quatd(angle:0,axis:SIMD3(0,0,1)),q] {
                let rep=try XCTUnwrap(run(exercise:exercise,attitude:attitude).reps.first)
                XCTAssertEqual(rep.status,.available,"\(exercise): \(String(describing:rep.reason)), uncertainty \(String(describing:rep.maximumVelocityStandardDeviation))")
                XCTAssertEqual(rep.measurementKind,"device-path-3d")
                XCTAssertEqual(try XCTUnwrap(rep.peakLiftingSpeed),hypot(0.3,0.8),accuracy:0.10)
                XCTAssertGreaterThan(try XCTUnwrap(rep.peakLiftingSpeed),try XCTUnwrap(rep.peakVerticalLiftingSpeed))
                if let reference {
                    XCTAssertEqual(try XCTUnwrap(rep.peakLiftingSpeed),try XCTUnwrap(reference.peakLiftingSpeed),accuracy:1e-9)
                    XCTAssertEqual(try XCTUnwrap(rep.meanLiftingSpeed),try XCTUnwrap(reference.meanLiftingSpeed),accuracy:1e-9)
                } else { reference=rep }
            }
        }
    }

    func testDirectionalReversalDoesNotZeroTransverseVelocity() throws {
        var observer=PassiveRepMetrics(configuration:.devicePath3D)
        let event=event(exercise:.bicepsCurl)
        for i in 0...180 {
            let t=Double(i)/50
            let x=t>=0.5 && t<1 ? 0.5 : 0
            let z=t>=1 && t<3 ? 0.8 * .pi * cos(.pi*(t-1)) : 0
            observer.observe(frame(t,acceleration:SIMD3(x,0,z),gyro:t>=0.5 ? 0.6 : 0))
            observer.observeBoundaryEvidence(i==155 ? [.init(boundaryID:"vertical-only",sourceSegmentID:"0",
                observedTimestamp:3,confirmedTimestamp:3.10,kind:.continuousReversal,
                associatedCandidateIDs:[event.id],endpointStartTimestamp:2.9,endpointEndTimestamp:3.1,
                returnedTimestamp:3,direction:.loweringToLifting,reversalNormalWorld:.init(x:0,y:0,z:1))] : [],at:t)
            observer.observeCommitted(i==155 ? [event] : [],at:t)
        }
        let result=try XCTUnwrap(observer.snapshot.reps.first)
        XCTAssertGreaterThan(try XCTUnwrap(result.endpointVelocity3D).x,0.15)
        XCTAssertGreaterThan(try XCTUnwrap(result.maximumVelocityStandardDeviation),0.10,
                             "A directional update must retain transverse uncertainty")
        if result.status == .available {
            XCTAssertGreaterThan(try XCTUnwrap(result.peakLiftingSpeed),try XCTUnwrap(result.peakVerticalLiftingSpeed))
        }
    }

    func testMissingInitialAnchorAndBadOrientationDoNotChangeEvents() throws {
        var observer=PassiveRepMetrics(configuration:.devicePath3D)
        let event=event(exercise:.overheadPress)
        for i in 0...180 {
            let t=Double(i)/50
            observer.observe(frame(t,acceleration:SIMD3(0,0,0.5),gyro:0.6))
            observer.observeCommitted(i==155 ? [event] : [],at:t)
        }
        XCTAssertEqual(observer.snapshot.reps.first?.reason,.missingInitialAnchor)
        var bad=PassiveRepMetrics(configuration:.devicePath3D)
        for i in 0...155 {
            let t=Double(i)/50;bad.observe(frame(t,acceleration:.zero,gyro:0))
            bad.observeCommitted(i==155 ? [event] : [],at:t)
        }
        let t=3.12
        let sample=ResampledMotionSample(sourceTimestamp:t,sessionTime:t,sensorSide:.right,
            userAcceleration:.init(x:0,y:0,z:0),rotationRate:.init(x:0,y:0,z:0),gravity:.init(x:1,y:0,z:0),
            attitude:.init(w:1,x:0,y:0,z:0),interpolationStatus:.delivered,epoch:0)
        bad.observe(sample)
        XCTAssertEqual(bad.snapshot.reps.first?.reason,.invalidOrientation)
    }

    func testGapAndFinalizedMetricImmutability() throws {
        var observer=PassiveRepMetrics(configuration:.devicePath3D)
        let event=event(exercise:.lateralRaise)
        for i in 0...155 {
            let t=Double(i)/50
            observer.observe(frame(t,acceleration:.zero,gyro:0))
            observer.observeCommitted(i==155 ? [event] : [],at:t)
        }
        observer.sourceDiscontinuity(at:3.12)
        let frozen=observer.snapshot.reps
        for i in 157...200 {observer.observe(frame(Double(i)/50,acceleration:.zero,gyro:0));observer.observeCommitted([],at:Double(i)/50)}
        XCTAssertEqual(observer.snapshot.reps,frozen)
        XCTAssertEqual(frozen.first?.reason,.invalidInterval)
        XCTAssertEqual(frozen.first?.finalizedAt,3.12)
    }

    func testConfigurationsAreVersionedAndLegacyHashUnchanged() throws {
        XCTAssertEqual(try RepMetricsConfiguration.devicePath3D.validated(),.devicePath3D)
        XCTAssertEqual(RepMetricsConfiguration().contentHash,"4a58add833093280ec49ce3968df6a7d2f4737040ef0ffb2f8984faccd786c5f")
        var changed=RepMetricsConfiguration.devicePath3D
        changed.devicePath?.maximumVelocityNormStandardDeviation=0.19
        XCTAssertNotEqual(changed.contentHash,RepMetricsConfiguration.devicePath3D.contentHash)
        changed.devicePath?.algorithm="unsupported"
        XCTAssertThrowsError(try changed.validated())
    }

    func testNineCurlRecordedWorldGravityConvention() throws {
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/nine-curl-brief-bottoms.json")
        let root=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        let rows=try XCTUnwrap(root["uniformRows"] as? [[Any]])
        var maximum=0.0
        for row in rows {
            let n=row.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            let g=try XCTUnwrap(DevicePathMath.world(.init(x:n[9],y:n[10],z:n[11]),
                attitude:.init(w:n[12],x:n[13],y:n[14],z:n[15])))
            maximum=max(maximum,simd_length(g-SIMD3(0,0,-1)))
        }
        XCTAssertLessThan(maximum,0.001)
    }

    private func run(exercise:V2Exercise,attitude:simd_quatd) -> RepMetricsSnapshot {
        var observer=PassiveRepMetrics(configuration:.devicePath3D)
        let event=event(exercise:exercise)
        for i in 0...180 {
            let t=Double(i)/50
            let factor=t>=1 && t<3 ? .pi*cos(.pi*(t-1)) : 0
            observer.observe(frame(t,acceleration:SIMD3(0.3*factor,0,0.8*factor),gyro:t>=1 && t<3 ? 0.6 : 0,attitude:attitude))
            observer.observeBoundaryEvidence([],at:t)
            observer.observeCommitted(i==155 ? [event] : [],at:t)
        }
        return observer.snapshot
    }
    private func event(exercise:V2Exercise) -> V2CycleEvidence {
        .init(id:"rep",setID:UUID(uuidString:"10000000-0000-0000-0000-000000000001")!,exercise:exercise,
            authorizationSource:.manual,profileID:"test",dspContentHash:"test",detectorEpoch:0,cycleSequence:1,
            startTimestamp:1,topTimestamp:2,completionTimestamp:3,detectionTimestamp:3.1,bottom:0,top:2,
            returned:0,outboundArea:1,returnArea:1,committed:true,rejectionReason:nil)
    }
    private func frame(_ t:Double,acceleration:SIMD3<Double>,gyro:Double,
                       attitude q:simd_quatd=simd_quatd(angle:0,axis:SIMD3(0,0,1))) -> ResampledMotionSample {
        let a=q.inverse.act(acceleration / -9.80665),g=q.inverse.act(SIMD3<Double>(0,0,-1))
        return .init(sourceTimestamp:t,sessionTime:t,sensorSide:.right,
            userAcceleration:DevicePathMath.record(a),rotationRate:.init(x:0,y:gyro,z:0),gravity:DevicePathMath.record(g),
            attitude:.init(w:q.real,x:q.imag.x,y:q.imag.y,z:q.imag.z),interpolationStatus:.delivered,epoch:0)
    }
}

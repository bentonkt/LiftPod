import XCTest
@testable import LiftPod

final class V7DetectorContinuityTests: XCTestCase {
    func testV7ProfileIsSeparateWithoutChangingV6Identity() throws {
        let v6 = try V2DSPProfile.adaptiveCurlV6.validated()
        let v7 = try V2DSPProfile.adaptiveCurlV7.validated()

        XCTAssertEqual(v6.identity.algorithm, .adaptiveAxis)
        XCTAssertEqual(v6.identity.algorithm.rawValue, "adaptive-axis-v6")
        XCTAssertEqual(v7.identity.algorithm, .adaptiveAxisV7)
        XCTAssertEqual(v7.identity.algorithm.rawValue, "adaptive-axis-v7")
        XCTAssertEqual(v7.identity.profileVersion, "experimental-v6")
        XCTAssertNotEqual(v6.contentHash, v7.contentHash)
        XCTAssertEqual(v6.contentHash, "8ef55b2a54b13facada2cc7bc43c29319792f69cfef2432e1bdfb72ac4240c32")
    }

    func testContinuousGripChangePreservesSuccessorAndSharesBoundary() {
        let profile = V2DSPProfile.adaptiveCurlV7
        var detector = V6CurlDetector(profile: profile, descriptor: v2Descriptor(profile: profile))
        let samples = continuousCurls(changeAxis: true)
        var emitted: [V2BoundaryEvidence] = []

        for sample in samples {
            let update = detector.observe(sample, reference: reference(), departureAllowed: true)
            emitted.append(contentsOf: update.boundaryEvidence)
        }

        XCTAssertEqual(detector.events.count, 2)
        XCTAssertEqual(Set(detector.events.map(\.id)).count, 2)
        XCTAssertEqual(detector.boundaries.count, 2)
        let shared = detector.boundaries[0]
        XCTAssertEqual(shared.kind, .continuousReversal)
        XCTAssertEqual(shared.direction, .loweringToLifting)
        XCTAssertEqual(shared.associatedCandidateIDs, detector.events.map(\.id))
        XCTAssertLessThanOrEqual(shared.endpointStartTimestamp, shared.returnedTimestamp ?? -.infinity)
        XCTAssertLessThanOrEqual(shared.returnedTimestamp ?? .infinity, shared.endpointEndTimestamp)
        XCTAssertTrue(emitted.contains { $0.boundaryID == shared.boundaryID && $0.associatedCandidateIDs.count == 1 })
        XCTAssertTrue(emitted.contains { $0.boundaryID == shared.boundaryID && $0.associatedCandidateIDs.count == 2 })

        let firstAxis = detector.events[0].movementAxis
        let secondAxis = detector.events[1].movementAxis
        XCTAssertGreaterThan(abs(firstAxis?.y ?? 0), 0.9)
        XCTAssertGreaterThan(abs(secondAxis?.x ?? 0), 0.9)
    }

    func testEndSetAfterCompletionDiscardsRetainedTailAndAdmitsNoSuccessor() {
        let profile = V2DSPProfile.adaptiveCurlV7
        var detector = V6CurlDetector(profile: profile, descriptor: v2Descriptor(profile: profile))
        var departureAllowed = true

        for sample in continuousCurls(changeAxis: true) {
            _ = detector.observe(sample, reference: reference(), departureAllowed: departureAllowed)
            if detector.events.count == 1 { departureAllowed = false }
        }

        XCTAssertEqual(detector.events.count, 1)
        XCTAssertEqual(detector.boundaries.count, 1)
        XCTAssertEqual(detector.boundaries[0].associatedCandidateIDs, [detector.events[0].id])
    }

    func testSourceDiscontinuityClearsRetainedTailAndCandidateAssociation() {
        let profile = V2DSPProfile.adaptiveCurlV7
        var detector = V6CurlDetector(profile: profile, descriptor: v2Descriptor(profile: profile))
        var reset = false

        for sample in continuousCurls(changeAxis: true) {
            _ = detector.observe(sample, reference: reference(), departureAllowed: true)
            if detector.events.count == 1, !reset {
                detector.reset(discontinuity: true)
                reset = true
            }
        }

        XCTAssertTrue(reset)
        XCTAssertGreaterThanOrEqual(detector.events.count, 1)
        XCTAssertGreaterThanOrEqual(detector.boundaries.count, 1)
        XCTAssertEqual(detector.boundaries[0].associatedCandidateIDs, [detector.events[0].id])
        if detector.boundaries.count > 1 {
            XCTAssertNotEqual(detector.boundaries[0].sourceSegmentID,
                              detector.boundaries[1].sourceSegmentID)
        }
    }

    func testStationaryCompletionEmitsStationaryEndpointEvidence() {
        let profile = V2DSPProfile.adaptiveCurlV7
        var detector = V6CurlDetector(profile: profile, descriptor: v2Descriptor(profile: profile))

        for sample in singleCurlWithEndHold() {
            _ = detector.observe(sample, reference: reference(), departureAllowed: true)
        }

        XCTAssertEqual(detector.events.count, 1)
        XCTAssertEqual(detector.boundaries.count, 1)
        XCTAssertEqual(detector.boundaries[0].kind, .stationary)
        XCTAssertEqual(detector.boundaries[0].direction, .stationary)
        XCTAssertEqual(detector.boundaries[0].associatedCandidateIDs, [detector.events[0].id])
        XCTAssertGreaterThan(detector.boundaries[0].confirmedTimestamp,
                             detector.boundaries[0].observedTimestamp)
    }

    private func continuousCurls(changeAxis: Bool) -> [ResampledMotionSample] {
        (0...250).map { index in
            let time = Double(index) / 50
            if time < 0.40 { return sample(index: index, axis: .y, angle: 0, rate: 0) }
            if time < 2.40 {
                let phase = (time - 0.40) / 2
                return sample(index: index, axis: .y, angle: 2.2 * sin(.pi * phase),
                              rate: 2.2 * .pi / 2 * cos(.pi * phase))
            }
            if time < 4.40 {
                let phase = (time - 2.40) / 2
                return sample(index: index, axis: changeAxis ? .x : .y,
                              angle: 2.2 * sin(.pi * phase),
                              rate: 2.2 * .pi / 2 * cos(.pi * phase))
            }
            return sample(index: index, axis: changeAxis ? .x : .y, angle: 0, rate: 0)
        }
    }

    private func singleCurlWithEndHold() -> [ResampledMotionSample] {
        (0...145).map { index in
            let time = Double(index) / 50
            guard time >= 0.40, time < 2.40 else {
                return sample(index: index, axis: .y, angle: 0, rate: 0)
            }
            let phase = (time - 0.40) / 2
            return sample(index: index, axis: .y, angle: 2.2 * sin(.pi * phase),
                          rate: 2.2 * .pi / 2 * cos(.pi * phase))
        }
    }

    private enum Axis { case x, y }

    private func sample(index: Int, axis: Axis, angle: Double, rate: Double) -> ResampledMotionSample {
        let gravity: ExperimentalVector3
        let rotation: ExperimentalVector3
        switch axis {
        case .x:
            gravity = .init(x: 0, y: sin(angle), z: cos(angle))
            rotation = .init(x: rate, y: 0, z: 0)
        case .y:
            gravity = .init(x: -sin(angle), y: 0, z: cos(angle))
            rotation = .init(x: 0, y: rate, z: 0)
        }
        let time = Double(index) / 50
        return .init(sourceTimestamp: time, sessionTime: time, sensorSide: .right,
                     userAcceleration: .init(x: 0, y: 0, z: 0), rotationRate: rotation,
                     gravity: gravity, attitude: .init(w: 1, x: 0, y: 0, z: 0),
                     interpolationStatus: .delivered, epoch: 0)
    }

    private func reference() -> V2ReferenceMeasurements {
        .init(neutralSignal: 0, referenceAttitude: .init(w: 1, x: 0, y: 0, z: 0),
              referenceGravity: .init(x: 0, y: 0, z: 1), activityMedian: 0,
              activityP90: 0, signalP05: 1, signalP95: 1, signalMAD: 0,
              earlyLateDrift: 0, accelerationNoiseMAD: 0, gyroNoiseMAD: 0,
              observedSampleRate: 50, sampleCount: 25, startTimestamp: 0, endTimestamp: 0.5)
    }
}

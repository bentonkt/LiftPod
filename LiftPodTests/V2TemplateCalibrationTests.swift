import XCTest
@testable import LiftPod

final class V2TemplateMatchingTests: XCTestCase {
    func testTenFeaturesAndPhysicalUpProjection() {
        let sample = v2Uniform(0, signal: 0, acceleration: .init(x: 1, y: 2, z: 3),
                               rotation: .init(x: 4, y: 5, z: 6))
        let channels = V2FeatureExtractor().channels(for: sample)
        XCTAssertEqual(channels.count, 10)
        XCTAssertEqual(Array(channels.prefix(9)), [1, 2, 3, 4, 5, 6, 0, 0, -1])
        XCTAssertEqual(channels[9], 3, accuracy: 1e-12)
    }

    func testResamplingCreatesExactlySixtyFourFrames() {
        let input = (0..<101).map { index in Array(repeating: Double(index) / 100, count: 10) }
        XCTAssertEqual(V2FeatureExtractor().sixtyFourFrames(input).count, 64)
        XCTAssertEqual(V2FeatureExtractor().sixtyFourFrames(input).first, input.first)
    }

    func testSharedPathDTWIsDeterministicAndInsideBand() {
        let frames = (0..<64).map { frame in Array(repeating: Double(frame) / 63, count: 10) }
        let first = V2DynamicTimeWarping().compare(candidate: frames, template: frames,
                                                   scales: Array(repeating: 1, count: 10), bandFraction: 0.20)
        let second = V2DynamicTimeWarping().compare(candidate: frames, template: frames,
                                                    scales: Array(repeating: 1, count: 10), bandFraction: 0.20)
        XCTAssertEqual(first, second); XCTAssertEqual(first?.cost, 0)
        XCTAssertTrue(first?.path.allSatisfy { abs($0.0 - $0.1) <= 12 } == true)
    }

    func testFullCyclePassesAndAscentOnlyFails() throws {
        let samples = templateMotionSamples(returning: true)
        let profile = try makeTemplateProfile(from: samples)
        XCTAssertTrue(V2FullCycleTemplateMatcher(profile: profile).evaluate(samples: samples).accepted)
        let ascentOnly = templateMotionSamples(returning: false)
        XCTAssertFalse(V2FullCycleTemplateMatcher(profile: profile).evaluate(samples: ascentOnly).accepted)
    }

    func testNegativeMarginAndEndpointChecksAreEnforced() throws {
        let samples = templateMotionSamples(returning: true)
        let base = try makeTemplateProfile(from: samples)
        let positive = base.identity.positiveTemplates[0]
        let withNegative = try profile(identity: base.identity, positives: [positive], negatives: [positive],
                                       templateConfiguration: base.identity.templateConfiguration)
        XCTAssertEqual(V2FullCycleTemplateMatcher(profile: withNegative).evaluate(samples: samples).rejectionReason,
                       .negativeMargin)
        var strict = base.identity.templateConfiguration; strict.endpointLimit = 1e-12
        var shifted = samples; shifted[0] = v2Uniform(0, acceleration: .init(x: 0.2, y: 0, z: 0))
        let strictProfile = try profile(identity: base.identity, positives: [positive], negatives: [],
                                        templateConfiguration: strict)
        XCTAssertEqual(V2FullCycleTemplateMatcher(profile: strictProfile).evaluate(samples: shifted).rejectionReason,
                       .endpointMismatch)
    }

    private func templateMotionSamples(returning: Bool) -> [ResampledMotionSample] {
        (0..<90).map { index in
            let position = Double(index) / 89
            let value = returning ? (position <= 0.5 ? position * 2 : (1 - position) * 2) : position
            return v2Uniform(index, signal: 0, acceleration: .init(x: value, y: 0, z: 0))
        }
    }

    private func makeTemplateProfile(from samples: [ResampledMotionSample]) throws -> V2DSPProfile {
        let extractor = V2FeatureExtractor()
        let frames = extractor.sixtyFourFrames(extractor.filtered(samples, coefficients: .v2Fixed4Hz))
        let template = V2Template(frames: frames, landmarks: [0, 16, 32, 48, 63], duration: 1.78,
                                  channelScales: Array(repeating: 0.2, count: 10), negativeSubtype: nil)
        return try profile(identity: V2DSPProfile.bundledCurl.identity, positives: [template], negatives: [],
                           templateConfiguration: .init())
    }

    private func profile(identity: V2DSPIdentity, positives: [V2Template], negatives: [V2Template],
                         templateConfiguration: V2TemplateConfiguration) throws -> V2DSPProfile {
        try V2DSPProfile(profileID: "rep-analysis-v2-test-template",
                         identity: .init(profileVersion: "experimental-v2", exercise: .overheadPress,
                                         expectedSensorSide: .right, setupIdentifier: "test-setup", sampleRate: 50,
                                         signalSource: .userAcceleration, projectionAxis: .y, polarity: 1,
                                         filter: .v2Fixed4Hz, reference: identity.reference,
                                         localCycle: identity.localCycle, templateConfiguration: templateConfiguration,
                                         timing: identity.timing, positiveTemplates: positives,
                                         negativeTemplates: negatives, kind: .fullCycleTemplate),
                         validationStatus: .generatedUnvalidated, descriptiveNotes: nil).validated()
    }
}

final class V2CalibrationTests: XCTestCase {
    func testThreeCoherentDemonstrationsProduceLocalProfile() throws {
        let demos = (0..<3).map { calibrationDemo(sequence: $0, exercise: .bicepsCurl, span: 0.3) }
        let profile = try V2GuidedCalibrator().calibrate(demos, setupIdentifier: "repeatable-setup")
        XCTAssertEqual(profile.identity.kind, .localCycle)
        XCTAssertEqual(profile.validationStatus, .generatedUnvalidated)
        XCTAssertEqual(profile.identity.localCycle.trainedSpan, 0.3, accuracy: 0.03)
    }

    func testOverheadUsesTemplateAndUnsupportedCutoffFails() throws {
        let demos = (0..<3).map { calibrationDemo(sequence: $0, exercise: .overheadPress, span: 0.3) }
        XCTAssertEqual(try V2GuidedCalibrator().calibrate(demos, setupIdentifier: "overhead").identity.kind,
                       .fullCycleTemplate)
        XCTAssertThrowsError(try V2GuidedCalibrator().calibrate(demos, cutoff: 7, setupIdentifier: "overhead"))
    }

    func testInsufficientMotionInvalidOrderingAndDiscontinuityFail() {
        var demo = calibrationDemo(sequence: 0, exercise: .bicepsCurl, span: 0)
        let still = (0..<100).map { v2Uniform($0) }
        demo = .init(exercise: .bicepsCurl, sequenceNumber: 0, samples: still,
                     cueStartTimestamp: 0.2, turnaroundCueTimestamp: 1,
                     returnCueTimestamp: 1.5, endTimestamp: 1.98)
        XCTAssertThrowsError(try V2GuidedCalibrator().calibrate([demo, demo, demo], setupIdentifier: "still"))
        let badOrder = V2CalibrationDemonstration(exercise: .bicepsCurl, sequenceNumber: 1,
                                                  samples: calibrationDemo(sequence: 1, exercise: .bicepsCurl, span: 0.3).samples,
                                                  cueStartTimestamp: 1, turnaroundCueTimestamp: 0.5,
                                                  returnCueTimestamp: 1.5, endTimestamp: 1.98)
        XCTAssertThrowsError(try badOrder.validated(expectedSide: .right))
        var broken = calibrationDemo(sequence: 2, exercise: .bicepsCurl, span: 0.3).samples
        broken[50] = .init(sourceTimestamp: 1.01, sessionTime: 1.01, sensorSide: .right,
                           userAcceleration: broken[50].userAcceleration, rotationRate: broken[50].rotationRate,
                           gravity: broken[50].gravity, attitude: broken[50].attitude,
                           interpolationStatus: .delivered, epoch: 0)
        XCTAssertThrowsError(try V2CalibrationDemonstration(exercise: .bicepsCurl, sequenceNumber: 2,
                                                             samples: broken, cueStartTimestamp: 0.2,
                                                             turnaroundCueTimestamp: 1, returnCueTimestamp: 1.5,
                                                             endTimestamp: 1.98).validated(expectedSide: .right))
    }

    private func calibrationDemo(sequence: Int, exercise: V2Exercise, span: Double) -> V2CalibrationDemonstration {
        let samples = (0..<100).map { index -> ResampledMotionSample in
            let signal: Double
            if index < 25 { signal = -0.5 }
            else if index <= 50 { signal = -0.5 + span * Double(index - 25) / 25 }
            else { signal = -0.5 + span * Double(99 - index) / 49 }
            return v2Uniform(index, signal: signal, acceleration: .init(x: span == 0 ? 0 : 0.1, y: 0, z: 0))
        }
        return .init(exercise: exercise, sequenceNumber: sequence, samples: samples,
                     cueStartTimestamp: 0.2, turnaroundCueTimestamp: 1,
                     returnCueTimestamp: 1.5, endTimestamp: 1.98)
    }
}

import Foundation
@testable import LiftPod

func v2Uniform(_ index: Int, signal: Double = -0.5,
               acceleration: ExperimentalVector3 = .init(x: 0, y: 0, z: 0),
               rotation: ExperimentalVector3 = .init(x: 0, y: 0, z: 0),
               attitude: ExperimentalQuaternion = .init(w: 1, x: 0, y: 0, z: 0),
               side: ExperimentalSensorSide = .right) -> ResampledMotionSample {
    let time = Double(index) * 0.02
    return .init(sourceTimestamp: time, sessionTime: time, sensorSide: side,
                 userAcceleration: acceleration, rotationRate: rotation,
                 gravity: .init(x: signal, y: 0, z: -sqrt(max(0, 1 - signal * signal))),
                 attitude: attitude, interpolationStatus: .delivered, epoch: 0)
}

func v2Raw(_ index: Int, signal: Double = -0.5,
           acceleration: ExperimentalVector3 = .init(x: 0, y: 0, z: 0),
           rotation: ExperimentalVector3 = .init(x: 0, y: 0, z: 0),
           side: HeadphoneSensorLocation = .rightHeadphone) -> RawMotionSample {
    experimentalRawSample(index: UInt64(index), time: Double(index) * 0.02, side: side,
                          acceleration: acceleration, gravity: .init(x: signal, y: 0, z: -0.866),
                          rotation: rotation)
}

func v2Descriptor(profile: V2DSPProfile = .bundledCurl) -> V2SetDescriptor {
    .init(setID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
          exercise: profile.identity.exercise, profileID: profile.profileID,
          dspContentHash: profile.contentHash, authorizationSource: .manual,
          hardwareSetupIdentifier: profile.identity.setupIdentifier)
}

func v2CurlSignals(bottom: Double = 0, top: Double = 1.1, returned: Double = 0) -> [Double] {
    var values = Array(repeating: bottom, count: 3)
    values += [bottom + 0.30, bottom + 0.32, bottom + 0.34]
    for index in 0..<10 { values.append(bottom + 0.34 + (top - bottom - 0.34) * Double(index + 1) / 10) }
    values += Array(repeating: top, count: 3)
    values += [top - 0.04, top - 0.06, top - 0.08]
    for index in 0..<23 { values.append(top + (returned - top) * Double(index + 1) / 23) }
    values += Array(repeating: returned, count: 7)
    return values
}

func v2RunSegmenter(_ values: [Double], profile: V2DSPProfile = .bundledCurl,
                    departureAllowed: Bool = true) -> V2LocalCycleSegmenter {
    var detector = V2LocalCycleSegmenter(profile: profile, setDescriptor: v2Descriptor(profile: profile))
    for (index, value) in values.enumerated() {
        _ = detector.observe(signal: value, gyroscopeMagnitude: 0, timestamp: Double(index) * 0.02,
                             departureAllowed: departureAllowed)
    }
    return detector
}

actor V2TestRecorder: V2RecordingSink {
    var failAppend = false
    var rawCount = 0
    var transactions: [V2ProcessorTransaction] = []
    func start(descriptor: V2SetDescriptor, profile: V2DSPProfile) throws { }
    func appendRaw(_ sample: RawMotionSample) throws {
        if failAppend { throw V2Error.recordingFailure("injected") }
        rawCount += 1
    }
    func appendTransaction(_ transaction: V2ProcessorTransaction) throws { transactions.append(transaction) }
    func addMarker(_ marker: V2SyncMarker) throws { }
    func finalize(state: V2SetState, failure: V2SetInterruption?, snapshot: V2ProcessorSnapshot,
                  reference: V2ReferenceMeasurements?) throws -> V2SessionBundleURLs? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v2-test-recorder")
        return .init(directory: directory, rawCSV: directory.appendingPathComponent("raw.csv"),
                     transactions: directory.appendingPathComponent("transactions.jsonl"),
                     metadata: directory.appendingPathComponent("metadata.json"),
                     summary: directory.appendingPathComponent("summary.json"),
                     manifest: directory.appendingPathComponent("manifest.json"),
                     profile: directory.appendingPathComponent("profile.json"))
    }
    func injectAppendFailure() { failAppend = true }
}

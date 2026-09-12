import Foundation

extension V2DSPProfile {
    static var lateralRaiseV6: Self {
        var reference = V2ReferenceConfiguration()
        reference.rawLower = 0.8
        reference.rawUpper = 1.2
        var cycle = V2LocalCycleConfiguration()
        cycle.startLower = -0.20
        cycle.startUpper = 0.03
        cycle.leaveStart = 0.12
        cycle.apexLower = 0.12
        cycle.leaveApex = 0.08
        cycle.trainedSpan = 1.0
        cycle.minimumOutboundExcursion = 0.40
        cycle.minimumReturnExcursion = 0.30
        cycle.minimumReturnFraction = 0.70
        cycle.maximumPositiveBottomOffsetFraction = 0.45
        cycle.gyroscopeQuietThreshold = 0.80
        return .init(
            profileID: "experimental-lateral-right-v1",
            identity: .init(
                profileVersion: "experimental-v6", exercise: .lateralRaise, expectedSensorSide: .right,
                setupIdentifier: "right-airpod-held-weight", sampleRate: 50, signalSource: .gravity, projectionAxis: .x,
                polarity: 1, filter: .v2Fixed4Hz, reference: reference, localCycle: cycle,
                templateConfiguration: .init(), timing: .init(), positiveTemplates: [], negativeTemplates: [],
                kind: .localCycle, algorithm: .gravityTilt, gravityTilt: .init()),
            validationStatus: .experimental,
            descriptiveNotes:
                "Reference-relative lateral-raise cycles with session direction consistency. Partial-range cycles are eligible; no anatomical range or form assessment."
        )
    }
}

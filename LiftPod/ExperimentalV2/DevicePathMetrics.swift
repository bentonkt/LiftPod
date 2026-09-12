import Foundation
import simd

/// One exercise-independent estimator. All quantities are at the sensor, not
/// at an inferred joint, dumbbell center, or barbell center.
struct DevicePathMetricsConfiguration: Codable, Sendable, Equatable {
    var algorithm = "bounded-world-vector-fit-v1"
    var uncertaintyModel = "principal-velocity-bound-v1"
    var filterAlignmentSamples = 3
    var maximumWorldGravityChange = 0.08
    var maximumVelocityNormStandardDeviation = 0.20
    var maximumBiasNorm = 0.35
    var maximumStationaryResidual = 0.20
    var minimumPeakToUncertaintyRatio = 3.0
    /// Nil preserves the anchored V1 algorithm and its stored hashes.
    var cyclic: CyclicPathConfiguration?

    func validate() throws {
        guard algorithm == "bounded-world-vector-fit-v1", uncertaintyModel == "principal-velocity-bound-v1", filterAlignmentSamples == 3,
              maximumWorldGravityChange.isFinite, (0.001...0.08).contains(maximumWorldGravityChange),
              maximumVelocityNormStandardDeviation.isFinite,
              (0.01...0.20).contains(maximumVelocityNormStandardDeviation),
              maximumBiasNorm.isFinite, (0.01...0.35).contains(maximumBiasNorm),
              maximumStationaryResidual.isFinite, (0.01...0.20).contains(maximumStationaryResidual),
              minimumPeakToUncertaintyRatio.isFinite, minimumPeakToUncertaintyRatio >= 3 else {
            throw V2Error.invalidLifecycle("invalid device-path configuration")
        }
        try cyclic?.validate()
    }
}

struct CyclicPathConfiguration: Codable, Sendable, Equatable {
    var version = "local-soft-return-v1"
    var startVelocityStandardDeviation = 0.30
    var displacementStandardDeviation = 0.05
    var velocityPeriodicityStandardDeviation = 0.10
    // World-frame bias includes orientation/gravity-separation error, not only
    // quiet-window sensor noise. About one degree of tilt is 0.17 m/s².
    var localBiasPriorStandardDeviation = 0.15
    var maximumDisplacementResidual = 0.15
    var maximumVelocityPeriodicityResidual = 0.20
    var startBoundarySearch = 0.40
    func validate() throws {
        guard version == "local-soft-return-v1",
              [startVelocityStandardDeviation, displacementStandardDeviation,
               velocityPeriodicityStandardDeviation, maximumDisplacementResidual,
               maximumVelocityPeriodicityResidual, startBoundarySearch, localBiasPriorStandardDeviation].allSatisfy({ $0.isFinite && $0 > 0 }),
              startVelocityStandardDeviation <= 0.30, displacementStandardDeviation <= 0.05,
              velocityPeriodicityStandardDeviation <= 0.10, maximumDisplacementResidual <= 0.15,
              maximumVelocityPeriodicityResidual <= 0.20, startBoundarySearch <= 0.40,
              localBiasPriorStandardDeviation <= 0.15 else {
            throw V2Error.invalidLifecycle("invalid cyclic path configuration")
        }
    }
}

enum DevicePathMath {
    static func vector(_ value: ExperimentalVector3) -> SIMD3<Double> { .init(value.x, value.y, value.z) }
    static func record(_ value: SIMD3<Double>) -> ExperimentalVector3 { .init(x: value.x, y: value.y, z: value.z) }
    static func world(_ vector: ExperimentalVector3, attitude: ExperimentalQuaternion) -> SIMD3<Double>? {
        guard let q = attitude.normalized() else { return nil }
        let value = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w).act(self.vector(vector))
        return [value.x, value.y, value.z].allSatisfy(\.isFinite) ? value : nil
    }

    /// Symmetric positive-definite 6x6 solve and covariance; fixed pivot ordering
    /// makes replay deterministic. This is a small bounded fit, not a learned model.
    static func inverse(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        var a = matrix, result = (0..<n).map { i in (0..<n).map { i == $0 ? 1.0 : 0.0 } }
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > 1e-14 else { return nil }
            if pivot != col { a.swapAt(pivot, col); result.swapAt(pivot, col) }
            let divisor = a[col][col]
            for j in 0..<n { a[col][j] /= divisor; result[col][j] /= divisor }
            for row in 0..<n where row != col {
                let scale = a[row][col]
                for j in 0..<n { a[row][j] -= scale * a[col][j]; result[row][j] -= scale * result[col][j] }
            }
        }
        return result.flatMap { $0 }.allSatisfy(\.isFinite) ? result : nil
    }
}

struct DevicePathMetrics: Sendable {
    private struct Frame: Sendable {
        let time: Double
        let epoch: Int
        let side: ExperimentalSensorSide?
        let acceleration: SIMD3<Double>
        let rawAcceleration: SIMD3<Double>
        let gravity: SIMD3<Double>
        let accelerationG: Double
        let gyro: Double
        let deviceGravity: SIMD3<Double>
    }
    private struct Anchor: Sendable {
        let id: String
        let time: Double
        let start: Double
        let epoch: Int
        let bias: SIMD3<Double>
        let biasSD: Double
    }
    private struct Observation {
        let time: Double
        let normal: SIMD3<Double>
        let sd: Double
    }
    private struct Fit {
        let velocity: [SIMD3<Double>]
        let bias: SIMD3<Double>
        let uncertainty: Double
        let residual: Double
        let boundaryIDs: [String]
        let decisions: [RepBoundaryMetricDecision]
        var closure: SIMD3<Double>? = nil
    }
    let configuration: RepMetricsConfiguration
    private var settings: DevicePathMetricsConfiguration { configuration.devicePath! }
    private var filters: [ScalarBiquadFilter]
    private var frames: [Frame] = []
    private var anchors: [Anchor] = []
    private var evidence: [V2BoundaryEvidence] = []
    private var events: [V2CycleEvidence] = []
    private var results: [RepMotionMetrics] = []
    private var decisions: [RepBoundaryMetricDecision] = []
    private var referenceGravity: SIMD3<Double>?
    private var lastInvalidReason: RepMetricsReason?

    init(configuration: RepMetricsConfiguration) {
        self.configuration = configuration
        filters = (0..<3).map { _ in ScalarBiquadFilter(coefficients: configuration.filter) }
    }
    var snapshot: RepMetricsSnapshot {
        .init(configuration: configuration, configurationHash: configuration.contentHash,
              reps: results, boundaryDecisions: decisions)
    }
    var pendingDeadline: Double? {
        events.indices.filter { results[$0].status == .pending }
            .map { events[$0].completionTimestamp + configuration.finalizationDeadline! }.max()
    }

    mutating func observe(_ sample: ResampledMotionSample) {
        let t = sample.sourceTimestamp
        guard t.isFinite, sample.sensorSide != nil,
              sample.rotationRate.magnitude.isFinite,
              (configuration.minimumGravityMagnitude...configuration.maximumGravityMagnitude).contains(sample.gravity.magnitude),
              let gravity = DevicePathMath.world(sample.gravity, attitude: sample.attitude),
              let raw = DevicePathMath.world(sample.userAcceleration, attitude: sample.attitude) else {
            invalidate(at: t.isFinite ? t : (frames.last?.time ?? 0), reason: .invalidOrientation); return
        }
        if let previous = frames.last,
           previous.epoch != sample.epoch || previous.side != sample.sensorSide ||
            t <= previous.time || t - previous.time > configuration.maximumUniformInterval + 1e-9 {
            invalidate(at: t, reason: .invalidInterval)
        }
        let normalizedGravity = simd_normalize(gravity)
        if let referenceGravity, simd_length(normalizedGravity - referenceGravity) > settings.maximumWorldGravityChange {
            invalidate(at: t, reason: .invalidOrientation); return
        }
        referenceGravity = referenceGravity ?? normalizedGravity
        let acceleration = raw * (configuration.accelerationSign * configuration.standardGravity)
        let filtered = SIMD3<Double>(filters[0].process(acceleration.x), filters[1].process(acceleration.y), filters[2].process(acceleration.z))
        frames.append(.init(time: t, epoch: sample.epoch, side: sample.sensorSide,
                            acceleration: filtered, rawAcceleration: acceleration, gravity: normalizedGravity,
                            accelerationG: sample.userAcceleration.magnitude, gyro: sample.rotationRate.magnitude,
                            deviceGravity: DevicePathMath.vector(sample.gravity)))
        let cutoff = t - configuration.historyDuration
        frames.removeAll { $0.time < cutoff }; anchors.removeAll { $0.time < cutoff }
        evidence.removeAll { $0.confirmedTimestamp < cutoff }
        acquireStationaryAnchor()
    }

    private func quiet(_ frame: Frame) -> Bool {
        frame.accelerationG <= configuration.quietAccelerationG && frame.gyro <= configuration.quietGyro
    }
    private mutating func acquireStationaryAnchor() {
        guard let end = frames.last else { return }
        let window = frames.filter { $0.time >= end.time - configuration.quietDuration - 1e-9 }
        guard let first = window.first, end.time - first.time >= configuration.quietDuration - 1e-9,
              anchors.last.map({ first.time >= $0.time - 1e-9 }) ?? true,
              window.allSatisfy({ quiet($0) && simd_length($0.gravity - first.gravity) <= configuration.quietGravityVariationG }) else { return }
        let bias = window.reduce(SIMD3<Double>.zero) { $0 + $1.rawAcceleration } / Double(window.count)
        let variance = window.reduce(0.0) { $0 + simd_length_squared($1.rawAcceleration - bias) } / Double(max(1, window.count - 1))
        anchors.append(.init(id: "world-stationary-\(end.epoch)-\(end.time.bitPattern)", time: end.time,
                             start: first.time, epoch: end.epoch, bias: bias,
                             biasSD: max(configuration.minimumInitialBiasStandardDeviation!, sqrt(variance / 3))))
        lastInvalidReason = nil
    }
    mutating func observeBoundaryEvidence(_ values: [V2BoundaryEvidence], at time: Double) {
        for value in values where value.confirmedTimestamp <= time + 1e-9 {
            if let index = evidence.firstIndex(where: { $0.boundaryID == value.boundaryID }) {
                evidence[index] = value
            } else { evidence.append(value) }
        }
    }
    mutating func observeCommitted(_ values: [V2CycleEvidence], at time: Double) {
        for event in values where event.committed && event.rejectionReason == nil && !events.contains(where: { $0.id == event.id && $0.setID == event.setID }) {
            events.append(event)
            var result = RepMotionMetrics(id: event.id, setID: event.setID, updatedAt: time)
            result.measurementKind = settings.cyclic == nil ? "device-path-3d" : "cyclic-device-path-3d"
            result.estimatorVersion = configuration.version
            result.liftingDuration = event.topTimestamp - event.startTimestamp
            result.loweringDuration = event.completionTimestamp - event.topTimestamp
            results.append(result)
        }
        resolve(at: time, force: false)
    }
    mutating func finish(at time: Double, interrupted: Bool) {
        if interrupted { invalidate(at: time, reason: .interrupted) }
        else { resolve(at: time, force: true) }
    }
    mutating func invalidate(at time: Double, reason: RepMetricsReason) {
        for index in results.indices where results[index].status == .pending {
            results[index].status = .unavailable; results[index].reason = reason
            results[index].finalizedAt = time; results[index].updatedAt = time; results[index].revision = 1
        }
        frames.removeAll(); anchors.removeAll(); evidence.removeAll(); referenceGravity = nil
        filters = (0..<3).map { _ in ScalarBiquadFilter(coefficients: configuration.filter) }
        lastInvalidReason = reason
    }
    private mutating func resolve(at time: Double, force: Bool) {
        for index in events.indices where results[index].status == .pending {
            guard force || time + 1e-9 >= events[index].completionTimestamp + configuration.finalizationDeadline! else { continue }
            results[index] = calculate(events[index], at: time)
        }
    }

    /// Batch estimate of [vx,vy,vz,bx,by,bz] from one initial full anchor and
    /// subsequent trusted observations. Reversals have rank one, not rank three.
    private func fit(_ window: [Frame], integrated: [SIMD3<Double>], anchor: Anchor,
                     event: V2CycleEvidence, resolvedAt: Double, perturbation: Double = 0) -> Fit? {
        let start = window[0].time
        var normal = Array(repeating: Array(repeating: 0.0, count: 6), count: 6)
        var rhs = Array(repeating: 0.0, count: 6)
        func add(_ row: [Double], _ target: Double, _ sd: Double) {
            let weight = 1 / (sd * sd)
            for i in 0..<6 { rhs[i] += row[i] * target * weight
                for j in 0..<6 { normal[i][j] += row[i] * row[j] * weight }
            }
        }
        for axis in 0..<3 {
            var row = Array(repeating: 0.0, count: 6); row[axis] = 1
            add(row, 0, configuration.initialVelocityStandardDeviation!)
            row[axis] = 0; row[axis + 3] = 1
            add(row, anchor.bias[axis], anchor.biasSD)
        }
        func solve() -> (values: [Double], covariance: [[Double]])? {
            guard let covariance = DevicePathMath.inverse(normal) else { return nil }
            return ((0..<6).map { i in (0..<6).reduce(0) { $0 + covariance[i][$1] * rhs[$1] } }, covariance)
        }
        func nearest(_ t: Double) -> Int? {
            guard let i = window.indices.min(by: { abs(window[$0].time - t) < abs(window[$1].time - t) }),
                  abs(window[i].time - t) <= configuration.maximumUniformInterval + 1e-9 else { return nil }
            return i
        }
        func row(_ n: SIMD3<Double>, _ dt: Double) -> [Double] { [n.x,n.y,n.z,-dt*n.x,-dt*n.y,-dt*n.z] }
        func projectedVariance(_ h: [Double], _ p: [[Double]]) -> Double {
            (0..<6).reduce(0) { sum, i in sum + (0..<6).reduce(0) { $0 + h[i]*p[i][$1]*h[$1] } }
        }
        var observations: [Observation] = []
        var ids = [anchor.id]
        var fitDecisions: [RepBoundaryMetricDecision] = []
        let laterAnchors = anchors.filter { $0.epoch == anchor.epoch && $0.time > start && $0.time <= window.last!.time }
        // Independent nonoverlapping quiet windows constrain all components.
        for stationary in laterAnchors {
            guard let i = nearest(stationary.time) else { continue }
            for axis in 0..<3 {
                var n = SIMD3<Double>.zero; n[axis] = 1
                add(row(n, window[i].time - start), -integrated[i][axis], configuration.stationaryVelocityObservationStandardDeviation!)
                observations.append(.init(time: window[i].time, normal: n, sd: configuration.stationaryVelocityObservationStandardDeviation!))
            }
            ids.append(stationary.id)
        }
        let boundaries = evidence.filter {
            $0.kind == .continuousReversal && $0.associatedCandidateIDs.contains(event.id) &&
                $0.confirmedTimestamp <= event.completionTimestamp + configuration.finalizationDeadline! + 1e-9
        }.sorted { $0.observedTimestamp == $1.observedTimestamp ? $0.boundaryID < $1.boundaryID : $0.observedTimestamp < $1.observedTimestamp }
        for boundary in boundaries {
            // Existing lowering-to-lifting evidence only supports vertical zero.
            // New detectors can provide another explicit normal in world coordinates.
            let n0 = boundary.reversalNormalWorld.map(DevicePathMath.vector) ?? -(referenceGravity ?? SIMD3(0,0,-1))
            let timestamp = (boundary.returnedTimestamp ?? boundary.observedTimestamp) + perturbation
            guard simd_length(n0).isFinite, simd_length(n0) > 1e-9,
                  boundary.direction == .loweringToLifting,
                  abs(timestamp - event.completionTimestamp) <= configuration.reversalSearchTolerance! + abs(perturbation) + 1e-9,
                  let i = nearest(timestamp), let current = solve() else { continue }
            let n = simd_normalize(n0), h = row(n, window[i].time - start)
            let estimate = zip(h,current.values).reduce(0) { $0 + $1.0 * $1.1 } + simd_dot(n,integrated[i])
            let sd = sqrt(pow(configuration.reversalVelocityObservationBaseStandardDeviation!,2) +
                          pow(abs(simd_dot(n,window[i].acceleration))*configuration.reversalAccelerationStandardDeviationScale!,2))
            let variance = max(0, projectedVariance(h,current.covariance))
            let nis = estimate*estimate/(variance+sd*sd)
            let accepted = abs(estimate) <= configuration.maximumReversalVelocityInnovation! && nis <= configuration.maximumReversalNormalizedInnovationSquared!
            fitDecisions.append(.init(boundaryID: boundary.boundaryID, sourceSegmentID: boundary.sourceSegmentID,
                kind: boundary.kind, observedTimestamp: timestamp, resolvedTimestamp: resolvedAt,
                associatedCandidateIDs: boundary.associatedCandidateIDs, accepted: accepted,
                reason: accepted ? .accepted : .excessiveInnovation, estimatedVelocity: estimate,
                velocityStandardDeviation: sqrt(variance), innovation: -estimate,
                normalizedInnovationSquared: nis, observationStandardDeviation: sd))
            if accepted {
                add(h,-simd_dot(n,integrated[i]),sd)
                observations.append(.init(time: window[i].time, normal: n, sd: sd)); ids.append(boundary.boundaryID)
            }
        }
        guard let solved = solve() else { return nil }
        let v0 = SIMD3(solved.values[0],solved.values[1],solved.values[2])
        let bias = SIMD3(solved.values[3],solved.values[4],solved.values[5])
        let velocity = window.indices.map { v0 + integrated[$0] - bias*(window[$0].time-start) }
        var uncertainty = 0.0
        for frame in window where frame.time >= event.startTimestamp && frame.time <= event.completionTimestamp {
            let dt = frame.time-start
            var covariance=Array(repeating:Array(repeating:0.0,count:3),count:3)
            for i in 0..<3 { for j in 0..<3 {
                covariance[i][j]=solved.covariance[i][j]-dt*(solved.covariance[i+3][j]+solved.covariance[i][j+3])+dt*dt*solved.covariance[i+3][j+3]
            } }
            let processVariance=pow(configuration.accelerationNoiseStandardDeviation!,2)*dt/configuration.sampleRate +
                pow(configuration.biasRandomWalkStandardDeviation!,2)*pow(dt,3)/3
            for axis in 0..<3 { covariance[axis][axis]+=processVariance }
            // Largest absolute row sum bounds the largest eigenvalue. This
            // bounds uncertainty in every velocity direction (including lateral)
            // without incorrectly treating sqrt(trace(P)) as speed's SD.
            let bound=covariance.map { $0.map(abs).reduce(0,+) }.max() ?? .infinity
            uncertainty = max(uncertainty,sqrt(max(0,bound)))
        }
        let directionalResidual = observations.compactMap { observation -> Double? in
            guard let i=nearest(observation.time) else { return nil }
            return abs(simd_dot(observation.normal,velocity[i]))
        }.max() ?? simd_length(v0)
        let stationaryResidual = laterAnchors.compactMap { anchor -> Double? in
            guard let i=nearest(anchor.time) else { return nil }; return simd_length(velocity[i])
        }.max() ?? 0
        let residual = max(directionalResidual,stationaryResidual,simd_length(v0))
        return .init(velocity: velocity,bias: bias,uncertainty: uncertainty,residual: residual,
                     boundaryIDs: ids,decisions: fitDecisions)
    }

    /// Fit a local out-and-back path. Closure and velocity periodicity are SOFT
    /// model observations, not measured stationary endpoints. Unobservable steady
    /// body translation is excluded: this estimates the cyclic component of speed.
    private func cyclicFit(_ window: [Frame], integrated: [SIMD3<Double>], event: V2CycleEvidence) -> Fit? {
        guard let c=settings.cyclic, let first=window.first, let last=window.last else { return nil }
        let duration=last.time-first.time
        guard duration > 2*configuration.minimumLegDuration else { return nil }
        var accelerationDisplacement=SIMD3<Double>.zero
        for i in 1..<window.count {
            accelerationDisplacement += (integrated[i-1]+integrated[i])*0.5*(window[i].time-window[i-1].time)
        }
        // Identical scalar 2x2 fit on each world axis; no axis selection or
        // independent candidate amplitude normalization.
        let rows:[(Double,Double,Double)] = [
            (1,0,c.startVelocityStandardDeviation),
            (0,1,c.localBiasPriorStandardDeviation),
            (duration,-0.5*duration*duration,c.displacementStandardDeviation),
            (0,-duration,c.velocityPeriodicityStandardDeviation)]
        var aa=0.0,ab=0.0,bb=0.0
        for (a,b,sd) in rows { aa+=a*a/(sd*sd);ab+=a*b/(sd*sd);bb+=b*b/(sd*sd) }
        let det=aa*bb-ab*ab
        guard det>1e-12 else { return nil }
        let p00=bb/det,p01 = -ab/det,p11=aa/det
        var v0=SIMD3<Double>.zero,bias=SIMD3<Double>.zero
        for axis in 0..<3 {
            let targets=[0.0,0.0,-accelerationDisplacement[axis],-integrated.last![axis]]
            var ra=0.0,rb=0.0
            for (i,row) in rows.enumerated() {
                ra+=row.0*targets[i]/(row.2*row.2);rb+=row.1*targets[i]/(row.2*row.2)
            }
            v0[axis]=p00*ra+p01*rb;bias[axis]=p01*ra+p11*rb
        }
        let velocity=window.indices.map { v0+integrated[$0]-bias*(window[$0].time-first.time) }
        let closure=v0*duration+accelerationDisplacement-bias*(0.5*duration*duration)
        let residual=simd_length(velocity.last!-velocity.first!)
        var uncertainty=0.0
        for frame in window {
            let dt=frame.time-first.time
            let process=pow(configuration.accelerationNoiseStandardDeviation!,2)*dt/configuration.sampleRate +
                pow(configuration.biasRandomWalkStandardDeviation!,2)*pow(dt,3)/3
            uncertainty=max(uncertainty,sqrt(max(0,p00-2*dt*p01+dt*dt*p11+process)))
        }
        return .init(velocity:velocity,bias:bias,uncertainty:uncertainty,residual:residual,
                     boundaryIDs:["cyclic-start-\(event.id)","cyclic-return-\(event.id)"],decisions:[],closure:closure)
    }

    private func cyclicWindow(_ event: V2CycleEvidence, at time: Double,
                              startShift: Double=0, endShift: Double=0) -> (window:[Frame], integral:[SIMD3<Double>], fit:Fit)? {
        func nearest(_ t:Double) -> Int? {
            frames.indices.min(by: { abs(frames[$0].time-t)<abs(frames[$1].time-t) })
        }
        func bottom(_ timestamp:Double,_ radius:Double) -> Double {
            guard let axis=event.movementAxis.map(DevicePathMath.vector),simd_length(axis)>0.9,
                  let center=nearest(timestamp) else { return timestamp }
            let n=simd_normalize(axis),g=frames[center].deviceGravity
            let indices=frames.indices.filter { abs(frames[$0].time-timestamp)<=radius+1e-9 }
            func progress(_ i:Int) -> Double {
                let h=frames[i].deviceGravity
                return -atan2(simd_dot(n,simd_cross(g,h)),simd_dot(g,h)-simd_dot(g,n)*simd_dot(h,n))
            }
            guard let index=indices.min(by: { progress($0)<progress($1) }) else { return timestamp }
            return frames[index].time
        }
        guard let c=settings.cyclic,
              let first=frames.first,let last=frames.last,
              first.time<=event.startTimestamp+1e-9,last.time>=event.completionTimestamp,
              let lo=nearest(bottom(event.startTimestamp,c.startBoundarySearch)+startShift),
              let hi=nearest(bottom(event.completionTimestamp,configuration.reversalSearchTolerance!)+endShift),
              hi>lo,frames[lo].time<event.topTimestamp,frames[hi].time>event.topTimestamp,
              frames[hi].time-frames[lo].time<=configuration.maximumCycleDuration else { return nil }
        let delay=settings.filterAlignmentSamples
        guard hi+delay<frames.count,frames[hi+delay].time<=time+1e-9,
              abs(frames[lo].time-event.startTimestamp)<=c.startBoundarySearch+abs(startShift)+0.021,
              abs(frames[hi].time-event.completionTimestamp)<=configuration.reversalSearchTolerance!+abs(endShift)+0.021,
              frames[lo...(hi+delay)].allSatisfy({ $0.epoch == frames[lo].epoch }) else { return nil }
        let window=Array(frames[lo...hi])
        var integral=[SIMD3<Double>.zero]
        for i in 1..<window.count {
            integral.append(integral[i-1]+(frames[lo+i+delay-1].acceleration+frames[lo+i+delay].acceleration)*0.5*(window[i].time-window[i-1].time))
        }
        guard let fit=cyclicFit(window,integrated:integral,event:event) else { return nil }
        return (window,integral,fit)
    }

    private mutating func calculate(_ event: V2CycleEvidence, at time: Double) -> RepMotionMetrics {
        var result = RepMotionMetrics(id: event.id, setID: event.setID, updatedAt: time)
        result.measurementKind = "device-path-3d"; result.estimatorVersion = configuration.version
        result.finalizedAt = time; result.revision = 1
        result.liftingDuration = event.topTimestamp-event.startTimestamp
        result.loweringDuration = event.completionTimestamp-event.topTimestamp
        func fail(_ reason: RepMetricsReason) -> RepMotionMetrics { var r=result; r.status = .unavailable; r.reason=reason; return r }
        guard event.startTimestamp.isFinite,event.topTimestamp.isFinite,event.completionTimestamp.isFinite,
              event.startTimestamp < event.topTimestamp, event.topTimestamp < event.completionTimestamp,
              event.completionTimestamp-event.startTimestamp <= configuration.maximumCycleDuration else { return fail(.invalidLandmarks) }
        var window:[Frame],integral:[SIMD3<Double>],fitted:Fit
        var anchor:Anchor?
        if settings.cyclic != nil {
            result.measurementKind="cyclic-device-path-3d"
            guard let local=cyclicWindow(event,at:time) else { return fail(lastInvalidReason ?? .ambiguousBoundary) }
            window=local.window;integral=local.integral;fitted=local.fit
        } else {
        guard let initialAnchor=anchors.last(where: { $0.time <= event.startTimestamp+1e-9 }) else { return fail(lastInvalidReason ?? .missingInitialAnchor) }
        anchor=initialAnchor
        let anchor=initialAnchor
        guard event.completionTimestamp-anchor.time <= configuration.maximumAnchorAge! else { return fail(.staleAnchor) }
        let delay=settings.filterAlignmentSamples
        guard let lo=frames.firstIndex(where: { $0.time >= anchor.time-1e-9 }), frames.count > lo+delay else { return fail(.invalidInterval) }
        let latest=min(event.completionTimestamp+configuration.reversalSearchTolerance!,time-Double(delay)/configuration.sampleRate)
        guard let hi=frames.lastIndex(where: { $0.time <= latest+1e-9 }), hi>lo,
              frames[hi].time >= event.completionTimestamp-1e-9, hi+delay < frames.count else { return fail(.ambiguousBoundary) }
        window=Array(frames[lo...hi])
        guard frames[lo...(hi+delay)].allSatisfy({ $0.epoch == anchor.epoch }) else { return fail(.invalidInterval) }
        integral=[SIMD3<Double>.zero]
        for i in 1..<window.count {
            integral.append(integral[i-1]+(frames[lo+i+delay-1].acceleration+frames[lo+i+delay].acceleration)*0.5*(window[i].time-window[i-1].time))
        }
        guard let anchoredFit=fit(window,integrated: integral,anchor: anchor,event: event,resolvedAt: time) else { return fail(.excessiveUncertainty) }
        fitted=anchoredFit
        }
        decisions.append(contentsOf: fitted.decisions); if decisions.count>64 { decisions.removeFirst(decisions.count-64) }
        result.integrationStart=window.first!.time; result.integrationEnd=window.last!.time
        result.accelerationBias3D=DevicePathMath.record(fitted.bias)
        result.endpointVelocity3D=DevicePathMath.record(fitted.velocity.last!)
        result.equivalentAccelerationBias=simd_length(fitted.bias)
        result.endpointVelocityResidual=fitted.residual; result.maximumVelocityStandardDeviation=fitted.uncertainty
        result.boundaryIDs=fitted.boundaryIDs
        if let c=settings.cyclic,let closure=fitted.closure {
            result.pathClosure3D=DevicePathMath.record(closure)
            guard simd_length(closure)<=c.maximumDisplacementResidual,
                  fitted.residual<=c.maximumVelocityPeriodicityResidual else { return fail(.excessiveEndpointCorrection) }
        }
        guard simd_length(fitted.bias) <= settings.maximumBiasNorm,
              fitted.residual <= settings.maximumStationaryResidual else { return fail(.excessiveEndpointCorrection) }
        guard fitted.uncertainty <= settings.maximumVelocityNormStandardDeviation else { return fail(.excessiveUncertainty) }
        let speed=fitted.velocity.map(simd_length), up = -(referenceGravity ?? SIMD3(0,0,-1))
        let vertical=fitted.velocity.map { simd_dot($0,up) }
        func region(_ start: Double,_ end: Double) -> ClosedRange<Int>? {
            let indices=window.indices.filter { window[$0].time >= start && window[$0].time <= end && speed[$0]>configuration.movementSpeed }
            guard let peak=indices.max(by: { speed[$0]<speed[$1] }) else { return nil }
            var l=peak,h=peak
            // Merge brief near-zero interruptions within one supported leg.
            for i in indices.reversed() where i<l {
                if window[l].time-window[i].time <= configuration.movementInterruptionMergeDuration!+1/configuration.sampleRate+1e-9 { l=i }
                else { break }
            }
            for i in indices where i>h {
                if window[i].time-window[h].time <= configuration.movementInterruptionMergeDuration!+1/configuration.sampleRate+1e-9 { h=i }
                else { break }
            }
            return window[h].time-window[l].time >= configuration.minimumLegDuration ? l...h : nil
        }
        guard let lift=region(event.startTimestamp,event.topTimestamp),
              let lower=region(event.topTimestamp,event.completionTimestamp) else { return fail(.ambiguousDirection) }
        func metrics(_ values: [Double],_ range: ClosedRange<Int>) -> (Double,Double) {
            var area=0.0,peak=0.0
            for i in range.dropFirst() { area+=(values[i-1]+values[i])*0.5*(window[i].time-window[i-1].time) }
            let half=configuration.peakWindowSamples/2
            if range.count>=configuration.peakWindowSamples {
                for i in (range.lowerBound+half)...(range.upperBound-half) {
                    peak=max(peak,values[(i-half)...(i+half)].reduce(0,+)/Double(2*half+1))
                }
            }
            return (area/(window[range.upperBound].time-window[range.lowerBound].time),peak)
        }
        let lm=metrics(speed,lift),em=metrics(speed,lower)
        guard min(lm.1,em.1) >= settings.minimumPeakToUncertaintyRatio*fitted.uncertainty else { return fail(.excessiveUncertainty) }
        // Compare accepted directional observations at ±40 ms without changing
        // the published result or any previously committed count.
        if let anchor, fitted.decisions.contains(where: \.accepted) {
            for delta in [-configuration.boundaryPerturbation!,configuration.boundaryPerturbation!] {
                guard let perturbed=fit(window,integrated: integral,anchor: anchor,event: event,resolvedAt: time,perturbation: delta),
                      Set(perturbed.decisions.filter(\.accepted).map(\.boundaryID)) == Set(fitted.decisions.filter(\.accepted).map(\.boundaryID)) else { return fail(.ambiguousBoundary) }
                let p=perturbed.velocity.map(simd_length),pl=metrics(p,lift),pe=metrics(p,lower)
                for (a,b) in [(lm.0,pl.0),(lm.1,pl.1),(em.0,pe.0),(em.1,pe.1)] {
                    if abs(a-b)>max(configuration.maximumBoundaryPerturbationSpeed!,abs(a)*configuration.maximumBoundaryPerturbationFraction!) { return fail(.ambiguousBoundary) }
                }
            }
        }
        if settings.cyclic != nil {
            result.maximumBoundarySpeedChange=0
            // Perturb BOTH independently inferred endpoints, including cases
            // without detector-provided reversal observations.
            for ds in [-configuration.boundaryPerturbation!,0,configuration.boundaryPerturbation!] {
                for de in [-configuration.boundaryPerturbation!,0,configuration.boundaryPerturbation!] where ds != 0 || de != 0 {
                    guard let other=cyclicWindow(event,at:time,startShift:ds,endShift:de) else { return fail(.ambiguousBoundary) }
                    // Compare on identical movement timestamps, not shifted array indices.
                    let p=window.map { frame -> Double in
                        // Valid uniform samples lie on the same 50 Hz grid.
                        let offset=Int(((frame.time-other.window[0].time)*configuration.sampleRate).rounded())
                        let j=max(0,min(other.window.count-1,offset))
                        return simd_length(other.fit.velocity[j])
                    }
                    let pl=metrics(p,lift),pe=metrics(p,lower)
                    for (a,b) in [(lm.0,pl.0),(lm.1,pl.1),(em.0,pe.0),(em.1,pe.1)] {
                        result.maximumBoundarySpeedChange=max(result.maximumBoundarySpeedChange ?? 0,abs(a-b))
                        if abs(a-b)>max(configuration.maximumBoundaryPerturbationSpeed!,abs(a)*configuration.maximumBoundaryPerturbationFraction!) { return fail(.ambiguousBoundary) }
                    }
                }
            }
        }
        let vl=metrics(vertical.map { max(0,$0) },lift),ve=metrics(vertical.map { max(0,-$0) },lower)
        result.meanLiftingSpeed=lm.0; result.peakLiftingSpeed=lm.1; result.meanLoweringSpeed=em.0; result.peakLoweringSpeed=em.1
        result.meanVerticalLiftingSpeed=vl.0; result.peakVerticalLiftingSpeed=vl.1
        result.meanVerticalLoweringSpeed=ve.0; result.peakVerticalLoweringSpeed=ve.1
        result.movementStart=window[lift.lowerBound].time; result.liftEnd=window[lift.upperBound].time
        result.loweringStart=window[lower.lowerBound].time; result.movementEnd=window[lower.upperBound].time
        result.liftingDuration=result.liftEnd!-result.movementStart!; result.loweringDuration=result.movementEnd!-result.loweringStart!
        result.timingSource = .devicePathMotion
        // Pauses need positive quiet evidence. Unknown does not mean zero.
        func stationaryDwell(from start:Double,to end:Double) -> Double? {
            var began:Double?,longest=0.0
            for frame in frames where frame.time >= start && frame.time <= end {
                if quiet(frame) { began=began ?? frame.time;longest=max(longest,frame.time-began!) }
                else { began=nil }
            }
            return longest>=configuration.quietDuration-1e-9 ? longest : nil
        }
        result.topPauseDuration=stationaryDwell(from:result.liftEnd!,to:result.loweringStart!)
        if let index=events.firstIndex(where: { $0.id==event.id && $0.setID==event.setID }),index>0 {
            if evidence.contains(where: { $0.kind == .continuousReversal &&
                $0.associatedCandidateIDs.contains(event.id) && $0.associatedCandidateIDs.contains(events[index-1].id) }) {
                result.bottomPauseDuration=0
            } else {
                result.bottomPauseDuration=stationaryDwell(from:events[index-1].completionTimestamp,to:result.movementStart!)
            }
        }
        result.status = .available; result.reason=nil
        return result
    }
}

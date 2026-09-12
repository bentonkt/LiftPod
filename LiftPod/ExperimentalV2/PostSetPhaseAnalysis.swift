import Foundation
import simd

/// Derived estimates, never counter authorizations or calibrated anatomical timing.
struct PostSetPhaseAnalysis: Codable, Equatable, Sendable {
    static let currentAlgorithmVersion = "post-set-local-drift-speed-v2"
    enum Status: String, Codable, Sendable { case pending, complete, insufficientEvidence, failed }
    enum Direction: String, Codable, Sendable { case raising, lowering, unknown }
    struct CountedRep: Codable, Equatable, Sendable {
        let id: String
        let epoch: Int
        let start: Double
        let end: Double
    }
    struct Rep: Codable, Equatable, Sendable {
        let epoch: Int
        let start: Double
        let reversal: Double
        let end: Double
        var conventionID = 0
        var countedRepID: String?
        var countedRepNumber: Int?
        var aMeanSpeedMPS: Double?
        var bMeanSpeedMPS: Double?
        var speedQuality: String?
        var speedReason: String?
        var raisingMeanSpeedMPS: Double? {
            guard eligible else { return nil }; return aDirection == .raising ? aMeanSpeedMPS : (bDirection == .raising ? bMeanSpeedMPS : nil)
        }
        var loweringMeanSpeedMPS: Double? {
            guard eligible else { return nil }; return aDirection == .lowering ? aMeanSpeedMPS : (bDirection == .lowering ? bMeanSpeedMPS : nil)
        }
        var reason = "unmatched"
        var aDirection = Direction.unknown
        var bDirection = Direction.unknown
        var axisEnergy: Double = 0
        var verticalAlignment: Double = 0
        var verticalP95: Double = 0
        var aSignTravel: Double = 0
        var bSignTravel: Double = 0
        let aSeconds: Double
        let bSeconds: Double
        let ratio: Double
        init(epoch: Int, start: Double, reversal: Double, end: Double) {
            self.epoch=epoch;self.start=start;self.reversal=reversal;self.end=end
            aSeconds=reversal-start;bSeconds=end-reversal;ratio=(end-reversal)/(reversal-start)
        }
        var eligible: Bool { reason == "estimated" && countedRepID != nil }
    }
    struct Distribution: Codable, Equatable, Sendable {
        let median: Double
        let q25: Double
        let q75: Double
        let medianAbsoluteDeviation: Double
        init(_ values: [Double]) {
            median = PhaseDSP.quantile(values, 0.5)
            q25 = PhaseDSP.quantile(values, 0.25); q75 = PhaseDSP.quantile(values, 0.75)
            medianAbsoluteDeviation = PhaseDSP.quantile(values.map { abs($0 - PhaseDSP.quantile(values, 0.5)) }, 0.5)
        }
    }
    struct Change: Codable, Equatable, Sendable {
        let earlyMedian: Double
        let lateMedian: Double
        var seconds: Double { lateMedian - earlyMedian }
        var percent: Double { 100 * seconds / earlyMedian }
        // Computed values are explicitly encoded for downstream coach consumers.
        enum CodingKeys: String, CodingKey { case earlyMedian, lateMedian, seconds, percent }
        init(early: Double, late: Double) { earlyMedian = early; lateMedian = late }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            earlyMedian = try c.decode(Double.self, forKey: .earlyMedian)
            lateMedian = try c.decode(Double.self, forKey: .lateMedian)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(earlyMedian, forKey: .earlyMedian); try c.encode(lateMedian, forKey: .lateMedian)
            try c.encode(seconds, forKey: .seconds); try c.encode(percent, forKey: .percent)
        }
    }
    struct Summary: Codable, Equatable, Sendable {
        var countedReps = 0
        var eligibleReps = 0
        var missingOrAmbiguousReps = 0
        var unmatchedCandidates = 0
        var directionMappedReps = 0
        var coverage: Double?
        var directionCoverage: Double?
        var averageRaisingSpeedMPS: Double?
        var averageLoweringSpeedMPS: Double?
        var speedMeasuredReps: Int?
        var speedMeaning: String?
        var observationsEnabled = false
        var directionObservationsEnabled = false
        var a: Distribution?
        var b: Distribution?
        var ratio: Distribution?
        var raising: Distribution?
        var lowering: Distribution?
        var aChange: Change?
        var bChange: Change?
        var raisingChange: Change?
        var loweringChange: Change?
        var reasons: [String] = []
        var durationMeaning = "estimated elapsed phase time; may include pauses"
        var interpretation = "Timing differences do not establish poor control, fatigue, muscle tension, or an ideal tempo. A/B are not anatomical phases."
    }
    var schemaVersion = 1
    var algorithmVersion = PostSetPhaseAnalysis.currentAlgorithmVersion
    let setID: UUID
    let sourceFingerprint: String
    var status: Status
    var reps: [Rep] = []
    var summary = Summary()
    var diagnosticReasons: [String] = []
    var processingSeconds: Double = 0

    static func aggregate(_ reps: [Rep], counted: [CountedRep], reportedCount: Int? = nil) -> Summary {
        let good = reps.filter(\.eligible)
        let mapped = good.filter { $0.aDirection != .unknown && $0.bDirection != .unknown }
        var s = Summary()
        s.countedReps = reportedCount ?? counted.count
        s.eligibleReps = good.count; s.missingOrAmbiguousReps = max(0, s.countedReps - good.count)
        s.unmatchedCandidates = reps.filter { $0.countedRepID == nil }.count
        s.directionMappedReps = mapped.count
        let speedPairs = mapped.filter { r in
            guard let up=r.raisingMeanSpeedMPS, let down=r.loweringMeanSpeedMPS else { return false }
            return up.isFinite && down.isFinite && up>0 && down>0
        }
        s.speedMeasuredReps = speedPairs.count
        s.speedMeaning = "arithmetic mean of per-rep estimated 3D path speeds; elapsed phases may include pauses"
        if !speedPairs.isEmpty {
            s.averageRaisingSpeedMPS = speedPairs.compactMap(\.raisingMeanSpeedMPS).reduce(0,+)/Double(speedPairs.count)
            s.averageLoweringSpeedMPS = speedPairs.compactMap(\.loweringMeanSpeedMPS).reduce(0,+)/Double(speedPairs.count)
        }
        s.coverage = s.countedReps > 0 ? Double(good.count) / Double(s.countedReps) : nil
        s.directionCoverage = good.isEmpty ? nil : Double(mapped.count) / Double(good.count)
        let oneEpoch = Set(good.map { "\($0.epoch):\($0.conventionID)" }).count == 1
        s.observationsEnabled = good.count >= 3 && (s.coverage ?? 0) >= 0.6 && oneEpoch && s.countedReps == counted.count
        s.directionObservationsEnabled = s.observationsEnabled && mapped.count >= 3 && (s.directionCoverage ?? 0) >= 0.8
        if !s.observationsEnabled { s.reasons.append("insufficient coverage, mixed epochs, or corrected count") }
        if !s.directionObservationsEnabled { s.reasons.append("insufficient direction evidence") }
        if s.observationsEnabled {
            s.a = .init(good.map(\.aSeconds)); s.b = .init(good.map(\.bSeconds)); s.ratio = .init(good.map(\.ratio))
        }
        func duration(_ r: Rep, _ direction: Direction) -> Double { r.aDirection == direction ? r.aSeconds : r.bSeconds }
        if s.directionObservationsEnabled {
            s.raising = .init(mapped.map { duration($0, .raising) }); s.lowering = .init(mapped.map { duration($0, .lowering) })
        }
        let ordered = counted.sorted { $0.start < $1.start }
        if ordered.count >= 6 && s.observationsEnabled {
            let earlyIDs = Set(ordered.prefix(3).map(\.id)), lateIDs = Set(ordered.suffix(3).map(\.id))
            func change(_ rows: [Rep], _ value: (Rep) -> Double) -> Change? {
                let early = rows.filter { earlyIDs.contains($0.countedRepID ?? "") }
                let late = rows.filter { lateIDs.contains($0.countedRepID ?? "") }
                guard early.count >= 2, late.count >= 2, Set((early + late).map { "\($0.epoch):\($0.conventionID)" }).count == 1 else { return nil }
                return .init(early: PhaseDSP.quantile(early.map(value), 0.5), late: PhaseDSP.quantile(late.map(value), 0.5))
            }
            s.aChange = change(good, { $0.aSeconds }); s.bChange = change(good, { $0.bSeconds })
            if s.directionObservationsEnabled {
                s.raisingChange = change(mapped, { duration($0, .raising) }); s.loweringChange = change(mapped, { duration($0, .lowering) })
            }
        }
        return s
    }
}

/// Frozen offline DSP. Double precision; filter padding and local-envelope edge
/// handling match scipy's odd SOS padding / reflect ndimage conventions.
enum PhaseDSP {
    static let low = [[0.02785976611713603,0.05571953223427206,0.02785976611713603,1,-1.475480443592646,0.5869195080611902]]
    static let band = [[0.026226015417541416,0.05245203083508283,0.026226015417541416,1,-1.501850249570384,0.6080782836864617], [1,-2,1,1,-1.9823004460650457,0.9824671998577974]]
    static func quantile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted(), k = Double(x.count-1)*p, i = Int(k)
        return s[i] + (s[min(i+1,s.count-1)]-s[i])*(k-Double(i))
    }
    static func reflect(_ index: Int, _ count: Int) -> Int {
        var i = index
        while i < 0 || i >= count { i = i < 0 ? -i-1 : 2*count-i-1 }
        return i
    }
    static func filter(_ input: [Double], _ sos: [[Double]]) -> [Double] {
        let pad = 3*(2*sos.count+1)
        guard input.count > pad else { return input }
        let left = (1...pad).reversed().map { 2.0*input[0]-input[$0] }
        let right = (1...pad).map { 2.0*input[input.count-1]-input[input.count-1-$0] }
        var x = left + input + right
        func pass(_ values: [Double]) -> [Double] {
            var y = values
            for c in sos {
                let gain = (c[0]+c[1]+c[2])/(1+c[4]+c[5])
                var z1 = (gain-c[0])*y[0], z2 = (c[2]-c[5]*gain)*y[0]
                for i in y.indices {
                    let v = y[i], out = c[0]*v+z1
                    z1 = c[1]*v-c[4]*out+z2; z2 = c[2]*v-c[5]*out; y[i] = out
                }
            }
            return y
        }
        x = Array(pass(Array(pass(x).reversed())).reversed())
        return Array(x[pad..<(x.count-pad)])
    }
    static func velocity(_ acceleration: [Double], _ time: [Double]) -> [Double] {
        let a = filter(acceleration, low)
        var v = [Double](repeating: 0, count: a.count)
        for i in 1..<a.count { v[i] = v[i-1] + (a[i]+a[i-1])*0.5*(time[i]-time[i-1]) }
        let width = min(301, v.count % 2 == 1 ? v.count : v.count-1), half = width/2
        // Prefix moments yield the exact local linear least-squares trend,
        // including scipy mode=interp at either edge, in O(n).
        var sums = [0.0], moments = [0.0]
        for i in v.indices { sums.append(sums.last!+v[i]); moments.append(moments.last!+Double(i)*v[i]) }
        return v.indices.map { i in
            let first = min(max(0,i-half),v.count-width), last = first+width
            let center = Double(first)+Double(width-1)/2
            let mean = (sums[last]-sums[first])/Double(width)
            let denominator = Double(width)*Double(width*width-1)/12
            let slope = (moments[last]-moments[first]-center*(sums[last]-sums[first]))/denominator
            return v[i] - (mean+slope*(Double(i)-center))
        }
    }
    static func principal(_ x: [SIMD3<Double>]) -> (SIMD3<Double>, Double) {
        let mean = x.reduce(.zero,+)/Double(x.count)
        var matrix = simd_double3x3(0)
        for v in x { let d = v-mean; matrix += simd_double3x3(columns: (d*d.x,d*d.y,d*d.z)) }
        var axis = SIMD3<Double>(1,0,0)
        if matrix[1,1] > matrix[0,0] { axis = .init(0,1,0) }
        if matrix[2,2] > max(matrix[0,0],matrix[1,1]) { axis = .init(0,0,1) }
        for _ in 0..<100 { let next = matrix*axis; if simd_length(next) > 1e-15 { axis = simd_normalize(next) } }
        let largest = (0..<3).max { abs(axis[$0]) < abs(axis[$1]) }!
        if axis[largest] < 0 { axis = -axis }
        return (axis, simd_dot(axis,matrix*axis)/max(matrix[0,0]+matrix[1,1]+matrix[2,2],1e-20))
    }
    static func normalize(_ x: [Double]) -> [Double] {
        let floor = max(quantile(x.map(abs),0.95)*0.25,1e-12)
        let envelope = x.indices.map { i in (-50...50).map { abs(x[reflect(i+$0,x.count)]) }.sorted()[90] }
        let weights = (-40...40).map { exp(-0.5*pow(Double($0)/10,2)) }, total = weights.reduce(0,+)
        return x.indices.map { i in
            var e = 0.0
            for j in -40...40 { e += weights[j+40]*envelope[reflect(i+j,x.count)] }
            return x[i]/max(e/total,floor)
        }
    }
    static func lobes(_ raw: [Double]) -> [(Int,Double)] {
        let scale = max(quantile(raw.map(abs),0.95),1e-12), s = raw.map { $0/scale }
        var peaks: [(Int,Double)] = []
        for sign in [1.0,-1.0] {
            let v = s.map { $0*sign }
            var local: [Int] = [], i = 1
            while i < v.count-1 {
                if v[i] > v[i-1] {
                    var end = i
                    while end+1 < v.count && v[end+1] == v[i] { end += 1 }
                    if end+1 < v.count && v[end] > v[end+1] { local.append((i+end)/2) }
                    i = end
                }
                i += 1
            }
            var retained: [Int] = []
            for p in local.filter({ v[$0] >= 0.35 }).sorted(by: { v[$0] == v[$1] ? $0 > $1 : v[$0] > v[$1] }) {
                if retained.contains(where: { abs($0-p) < 15 }) { continue }
                retained.append(p)
            }
            for p in retained {
                var l=p, r=p, lm=v[p], rm=v[p]
                while l>0 && v[l-1] <= v[p] { l-=1; lm=min(lm,v[l]) }
                while r<v.count-1 && v[r+1] <= v[p] { r+=1; rm=min(rm,v[r]) }
                if v[p]-max(lm,rm) >= 0.25 { peaks.append((p,sign)) }
            }
        }
        var result: [(Int,Double)] = []
        for p in peaks.sorted(by: { $0.0 < $1.0 }) {
            if result.last?.1 == p.1 {
                if abs(s[p.0]) > abs(s[result.last!.0]) { result[result.count-1] = p }
            } else { result.append(p) }
        }
        return result
    }
    static func cycles(_ time: [Double], _ raw: [Double], epoch: Int) -> [PostSetPhaseAnalysis.Rep] {
        var signal = normalize(raw), ls = lobes(signal), chosen = 0
        func crossing(_ p: Int, _ n: Int, _ s: [Double]) -> Int? {
            let candidates = (p..<n).filter { s[$0] >= 0 && s[$0+1] < 0 }
            let center = Double(p+n)/2
            return candidates.min { abs(Double($0)-center) < abs(Double($1)-center) }
        }
        if ls.count >= 2 {
            for j in 0..<min(3,ls.count-1) {
                let p=ls[j].0, n=ls[j+1].0, s=raw.map { $0*ls[j].1 }
                guard s[p]>0, s[n]<0, let z=crossing(p,n,s) else { continue }
                var a=p,b=n
                while a>0 && s[a]>0.12*s[p] { a-=1 }
                while b<s.count-1 && s[b]<0.12*s[n] { b+=1 }
                func area(_ lo: Int,_ hi: Int,_ sign: Double) -> Double {
                    guard hi>lo else { return 0 }
                    var sum = 0.0
                    for i in lo..<hi {
                        let mean = 0.5 * (max(0.0,s[i]*sign)+max(0.0,s[i+1]*sign))
                        sum += mean * (time[i+1]-time[i])
                    }
                    return sum
                }
                let up=area(a,z,1),down=area(z+1,b,-1)
                if a>0 && b<s.count-1 && (0.6...12).contains(time[b]-time[a]) && min(up,down)/max(up,down,1e-12)>=0.35 { chosen=j;break }
            }
        }
        if chosen>0 {
            let lo=ls[chosen-1].0, hi=ls[chosen].0
            let z=(lo...hi).min { abs(signal[$0])<abs(signal[$1]) }!
            for i in 0...z { signal[i]=0 }
            ls=lobes(signal)
        }
        let polarity=ls.first?.1 ?? 1, s=signal.map { $0*polarity }
        var result: [PostSetPhaseAnalysis.Rep] = []
        var j=0
        while j+1<ls.count {
            let p=ls[j].0,n=ls[j+1].0; j+=2
            guard let z=crossing(p,n,s) else { continue }
            let reversal=time[z]+(time[z+1]-time[z])*s[z]/(s[z]-s[z+1])
            var a=p,b=n
            while a>0 && s[a]>0.12*s[p] { a-=1 }
            while b<s.count-1 && s[b]<0.12*s[n] { b+=1 }
            if a>0 && b<s.count-1 && (0.6...12).contains(time[b]-time[a]) && min(reversal-time[a],time[b]-reversal)>=0.2 {
                result.append(.init(epoch:epoch,start:time[a],reversal:reversal,end:time[b]))
            }
        }
        return result
    }
}

struct PostSetPhaseSample: Codable, Sendable {
    let time: Double
    let epoch: Int
    let acceleration: SIMD3<Double> // world, m/s²
    let up: SIMD3<Double>
}

enum PostSetPhaseAnalyzer {
    static func analyze(setID: UUID, fingerprint: String, samples: [PostSetPhaseSample],
                        counted: [PostSetPhaseAnalysis.CountedRep], reportedCount: Int? = nil) -> PostSetPhaseAnalysis {
        let began = ProcessInfo.processInfo.systemUptime
        var result = PostSetPhaseAnalysis(setID:setID,sourceFingerprint:fingerprint,status:.insufficientEvidence)
        var epochs: [[PostSetPhaseSample]] = [], current: [PostSetPhaseSample] = []
        for sample in samples {
            let valid = sample.time.isFinite && (0..<3).allSatisfy { sample.acceleration[$0].isFinite && sample.up[$0].isFinite } && simd_length(sample.up)>0.9
            if !valid || current.last.map({ sample.epoch != $0.epoch || sample.time-$0.time>0.030001 || sample.time<=$0.time || simd_length(sample.up-$0.up)>0.08 }) == true {
                if !current.isEmpty { epochs.append(current) }; current=[]
            }
            if valid { current.append(sample) }
        }
        if !current.isEmpty { epochs.append(current) }
        for (convention, frames) in epochs.enumerated() {
            guard frames.count >= 35 else { result.diagnosticReasons.append("short or partial epoch");continue }
            let t=frames.map(\.time), world=frames.map(\.acceleration)
            let xyz=(0..<3).map { axis in PhaseDSP.filter(world.map { $0[axis] },PhaseDSP.band) }
            let filtered=t.indices.map { SIMD3<Double>(xyz[0][$0],xyz[1][$0],xyz[2][$0]) }
            let (axis,energy)=PhaseDSP.principal(filtered)
            let raw=PhaseDSP.velocity(world.map { simd_dot($0,axis) },t)
            let vertical=PhaseDSP.velocity(frames.map { simd_dot($0.acceleration,$0.up) },t)
            let verticalP95=PhaseDSP.quantile(vertical.map(abs),0.95)
            let alignment=abs(simd_dot(axis,frames[0].up))
            let signalAvailable=PhaseDSP.quantile(raw.map(abs),0.95)>=0.025 && PhaseDSP.quantile(world.map { simd_length($0) },0.95)>=0.35
            var cycles=PhaseDSP.cycles(t,raw,epoch:frames[0].epoch)
            for i in cycles.indices {
                cycles[i].conventionID=convention
                cycles[i].axisEnergy=energy;cycles[i].verticalAlignment=alignment;cycles[i].verticalP95=verticalP95
                if !signalAvailable { cycles[i].reason="weak motion signal" }
                func direction(_ start: Double,_ end: Double) -> (PostSetPhaseAnalysis.Direction,Double) {
                    var positive=0.0,negative=0.0
                    for j in 0..<t.count-1 {
                        let lo=max(start,t[j]),hi=min(end,t[j+1]);if hi<=lo { continue }
                        let mean=(vertical[j]+vertical[j+1])*0.5
                        positive+=max(0,mean)*(hi-lo);negative+=max(0,-mean)*(hi-lo)
                    }
                    let fraction=max(positive,negative)/max(positive+negative,1e-12)
                    guard energy>=0.8,alignment>=0.5,verticalP95>=0.025,fraction>=0.8 else { return (.unknown,fraction) }
                    return (positive>negative ? .raising:.lowering,fraction)
                }
                let a=direction(cycles[i].start,cycles[i].reversal),b=direction(cycles[i].reversal,cycles[i].end)
                cycles[i].aSignTravel=a.1;cycles[i].bSignTravel=b.1
                if a.0 != .unknown && b.0 != .unknown && a.0 != b.0 { cycles[i].aDirection=a.0;cycles[i].bDirection=b.0 }
            }
            result.reps += cycles
        }
        result.reps.sort { $0.start < $1.start }
        associate(&result.reps,counted:counted)
        result.summary=PostSetPhaseAnalysis.aggregate(result.reps,counted:counted,reportedCount:reportedCount)
        result.status=result.summary.observationsEnabled ? .complete:.insufficientEvidence
        result.processingSeconds=ProcessInfo.processInfo.systemUptime-began
        return result
    }

    static func associate(_ cycles: inout [PostSetPhaseAnalysis.Rep], counted: [PostSetPhaseAnalysis.CountedRep]) {
        let refs=counted.sorted { $0.start < $1.start },n=cycles.count,m=refs.count
        guard n>0,m>0 else { return }
        func overlap(_ a: PostSetPhaseAnalysis.Rep,_ b: PostSetPhaseAnalysis.CountedRep) -> Double {
            guard a.epoch==b.epoch else { return 0 }
            return max(0,min(a.end,b.end)-max(a.start,b.start))/max(1e-12,max(a.end,b.end)-min(a.start,b.start))
        }
        let scores=cycles.map { a in refs.map { overlap(a,$0) } }
        var counts=Array(repeating:Array(repeating:0,count:m+1),count:n+1)
        var sums=Array(repeating:Array(repeating:0.0,count:m+1),count:n+1)
        var actions=counts
        for i in 1...n { for j in 1...m {
            counts[i][j]=counts[i-1][j];sums[i][j]=sums[i-1][j];actions[i][j]=1
            func better(_ count: Int,_ sum: Double) -> Bool { count>counts[i][j] || count==counts[i][j] && sum>sums[i][j] }
            if better(counts[i][j-1],sums[i][j-1]) { counts[i][j]=counts[i][j-1];sums[i][j]=sums[i][j-1];actions[i][j]=2 }
            if scores[i-1][j-1]>=0.3 && better(counts[i-1][j-1]+1,sums[i-1][j-1]+scores[i-1][j-1]) {
                counts[i][j]=counts[i-1][j-1]+1;sums[i][j]=sums[i-1][j-1]+scores[i-1][j-1];actions[i][j]=3
            }
        } }
        var i=n,j=m
        while i>0 && j>0 {
            switch actions[i][j] {
            case 3:
                let value=scores[i-1][j-1]
                let ambiguous=(0..<m).contains { $0 != j-1 && scores[i-1][$0]>=0.3 && scores[i-1][$0]>=value-0.1 } || (0..<n).contains { $0 != i-1 && scores[$0][j-1]>=0.3 && scores[$0][j-1]>=value-0.1 }
                cycles[i-1].countedRepID=refs[j-1].id
                cycles[i-1].countedRepNumber=j
                if ambiguous { cycles[i-1].reason="ambiguous association" }
                else if cycles[i-1].reason=="unmatched" { cycles[i-1].reason="estimated" }
                i-=1;j-=1
            case 1:i-=1
            default:j-=1
            }
        }
    }
}

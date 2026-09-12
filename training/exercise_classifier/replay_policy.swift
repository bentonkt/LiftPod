import Foundation

@main struct ReplayPolicy {
    struct Row: Decodable { let time: Double; let epoch: Int; let scores: [Double]?; let reset: Bool; let count: Int? }
    struct Capture: Decodable { let id: String; let rows: [Row] }
    struct Change: Encodable, Equatable { let time: Double; let a: String?; let b: String?; let c: String?; let status: String }
    struct Output: Encodable { let id: String; let changes: [Change] }
    static func main() throws {
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var output: [Output] = []
        for capture in captures {
            var policy = ExerciseLabelPolicy(); policy.start(now:0)
            var previousEpoch: Int?, a: ExerciseLabel?, changes: [Change] = []
            for row in capture.rows {
                if let previousEpoch, previousEpoch != row.epoch {
                    policy.discontinuity(now:row.time); a = nil
                }
                previousEpoch = row.epoch
                policy.sample(source:row.time,now:row.time)
                if row.reset { policy.resetEvidence(reason:"patternChanged"); a = nil }
                policy.tick(now:row.time)
                if let scores = row.scores {
                    a = ExerciseLabelPolicy.qualified(scores)
                    policy.accept(.init(captureID:UUID(),epoch:row.epoch,windowStart:row.time-3.98,
                        windowEnd:row.time,completedAt:row.time,scores:scores))
                }
                if policy.state.status == .unavailable { a = nil }
                let b = policy.state.label?.rawValue
                let change = Change(time:row.time,a:a?.rawValue,b:b,c:(row.count ?? 0)>=3 ? b : nil,
                    status:policy.state.status.rawValue)
                if let last = changes.last, last.a == change.a, last.b == change.b,
                   last.c == change.c, last.status == change.status { continue }
                changes.append(change)
            }
            if let row = capture.rows.last, let last = changes.last {
                changes.append(.init(time:row.time,a:last.a,b:last.b,c:last.c,status:last.status))
            }
            output.append(.init(id:capture.id,changes:changes))
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(output))
    }
}

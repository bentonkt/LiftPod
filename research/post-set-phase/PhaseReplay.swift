import Foundation
struct PhaseReplayInput: Codable {
    let setID: UUID
    let samples: [PostSetPhaseSample]
    let counted: [PostSetPhaseAnalysis.CountedRep]
}
@main enum PhaseReplay {
    static func main() throws {
        while let line = readLine() {
            let data=Data(line.utf8)
            let input=try JSONDecoder().decode(PhaseReplayInput.self,from:data)
            let result=PostSetPhaseAnalyzer.analyze(setID:input.setID,fingerprint:"replay",samples:input.samples,counted:input.counted)
            print(String(data:try JSONEncoder().encode(result),encoding:.utf8)!)
        }
    }
}

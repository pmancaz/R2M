import Foundation

@main struct ReadingPlanTests {
    static func main() throws {
        let author = "An 🧪 result (Latour, 1994) was stable at 3.1. It was repeated.1"
        let citation = (author as NSString).range(of: " (Latour, 1994)")
        let edits = [
            PassageEdit(at: citation.location, length: citation.length, reason: "Citation", group: "references", replacement: ""),
            PassageEdit(at: (author as NSString).length - 1, length: 1, reason: "Footnote", group: "cleanup", replacement: "")
        ]
        let units = [
            Passage(raw: "Study title", edits: [], order: 0, kind: "title", reason: nil, group: nil, joinFrom: nil, label: nil),
            Passage(raw: author, edits: edits, order: 10, kind: "text", reason: nil, group: nil, joinFrom: nil, label: nil),
            Passage(raw: "Latour, B. (1994). Technical mediation.", edits: [], order: 20, kind: "text", reason: "Bibliography entry", group: "references", joinFrom: nil, label: nil)
        ]
        let plan = ReadingPlan(units: units, classifierCount: 0)
        let original = units.map(\.raw).joined(separator: "\n\n")
        precondition(plan.render(skipReferences: false, cleanup: false, restored: []) == original)
        precondition(plan.render(skipReferences: true, cleanup: false, restored: []) == "Study title\n\nAn 🧪 result was stable at 3.1. It was repeated.1")
        precondition(plan.render(skipReferences: false, cleanup: true, restored: []) == "Study title\n\nAn 🧪 result (Latour, 1994) was stable at 3.1. It was repeated.\n\n" + units[2].raw)
        precondition(plan.render(skipReferences: true, cleanup: true, restored: []) == "Study title\n\nAn 🧪 result was stable at 3.1. It was repeated.")
        precondition(plan.render(skipReferences: true, cleanup: true, restored: Set(plan.changes().map(\.id))) == original)
        precondition(plan.changes().first(where: { $0.id == "1:edit:0" })?.excerpt == " (Latour, 1994)")
        let restored = try JSONDecoder().decode(ReadingPlan.self, from: JSONEncoder().encode(plan))
        precondition(restored.render(skipReferences: true, cleanup: true, restored: ["1:edit:0"]) == "Study title\n\nAn 🧪 result (Latour, 1994) was stable at 3.1. It was repeated.")

        // Damaged persisted edits must be ignored in both Review changes and
        // narration. Positive overflow, negative lengths and past-end ranges
        // previously crashed Foundation or Swift arithmetic.
        let invalid = [(-1, 1), (0, -1), (Int.max, 1), (1, Int.max), (100, 1), (0, 0)]
        for (at, length) in invalid {
            let edit = PassageEdit(at: at, length: length, reason: "Damaged edit", group: "cleanup", replacement: "")
            let unit = Passage(raw: "Author text", edits: [edit], order: 0, kind: "text", reason: nil, group: nil, joinFrom: nil, label: nil)
            let damaged = ReadingPlan(units: [unit], classifierCount: 0)
            precondition(damaged.changes().isEmpty)
            precondition(damaged.render(skipReferences: true, cleanup: true, restored: []) == "Author text")
        }
        print("PASS: UTF16 edits, independent cleanup/reference controls, review restoration, persistence and damaged-plan safety")
    }
}

import Foundation

struct PassageEdit: Codable {
    let at: Int
    let length: Int
    let reason: String
    let group: String
    let replacement: String
    func validatedRange(within limit: Int) -> NSRange? {
        // A malformed saved plan must not overflow Int or crash NSString.
        guard at >= 0, length > 0, at <= limit, length <= limit - at else { return nil }
        return NSRange(location: at, length: length)
    }
}
struct Passage: Codable {
    let raw: String
    let edits: [PassageEdit]
    let order: Int
    let kind: String
    let reason: String?
    let group: String?
    let joinFrom: Int?
    let label: String?
}
struct ReadingChange: Identifiable {
    let id: String
    let reason: String
    let excerpt: String
    let group: String
}
struct ReadingPlan: Codable {
    let units: [Passage]
    let classifierCount: Int
    static func decode(_ value: Any?) throws -> ReadingPlan {
        let data = try JSONSerialization.data(withJSONObject: value ?? [:])
        return try JSONDecoder().decode(ReadingPlan.self, from: data)
    }
    func changes() -> [ReadingChange] {
        var result: [ReadingChange] = []
        for (i, u) in units.enumerated() {
            if let reason = u.reason {
                result.append(.init(id: "\(i):block", reason: reason, excerpt: u.raw, group: u.group ?? "cleanup"))
            }
            if u.order != i * 10 {
                result.append(.init(id: "\(i):order", reason: "Move into reading order", excerpt: u.raw, group: "cleanup"))
            }
            if let previous = u.joinFrom, units.indices.contains(previous) {
                result.append(.init(id: "\(i):join", reason: "Join a split paragraph", excerpt: String(units[previous].raw.suffix(65)) + " ⏎ " + String(u.raw.prefix(65)), group: "cleanup"))
            }
            if let label = u.label {
                result.append(.init(id: "\(i):label", reason: "Spoken section heading", excerpt: label, group: "cleanup"))
            }
            let raw = u.raw as NSString
            for (n, edit) in u.edits.enumerated() {
                guard let range = edit.validatedRange(within: raw.length) else { continue }
                let excerpt = raw.substring(with: range)
                result.append(.init(id: "\(i):edit:\(n)", reason: edit.reason, excerpt: excerpt, group: edit.group))
            }
        }
        return result
    }
    func render(skipReferences: Bool, cleanup: Bool, restored: Set<String>) -> String {
        func enabled(_ group: String, _ id: String) -> Bool {
            (group == "references" ? skipReferences : cleanup) && !restored.contains(id)
        }
        func rank(_ i: Int) -> Int { enabled("cleanup", "\(i):order") ? units[i].order : i * 10 }
        let indices = units.indices.sorted { rank($0) < rank($1) }
        var output = ""
        var previous = -1
        for i in indices {
            let u = units[i]
            if u.reason != nil && enabled(u.group ?? "cleanup", "\(i):block") { continue }
            let text = NSMutableString(string: u.raw)
            // Apply edits against the immutable extraction, from right to left.
            let edits = u.edits.enumerated().sorted { $0.element.at > $1.element.at }
            var boundary = text.length
            for (n, edit) in edits where enabled(edit.group, "\(i):edit:\(n)") {
                guard let range = edit.validatedRange(within: boundary) else { continue }
                text.replaceCharacters(in: range, with: edit.replacement)
                boundary = edit.at
            }
            let value = (text as String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if !output.isEmpty {
                output += (u.joinFrom == previous && enabled("cleanup", "\(i):join")) ? " " : "\n\n"
            }
            if let label = u.label, enabled("cleanup", "\(i):label") { output += label + "\n\n" }
            output += value
            previous = i
        }
        return output
    }
}

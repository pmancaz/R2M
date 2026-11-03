import Foundation

struct Draft: Codable {
    var title = ""
    var text = ""
    var note = ""
    // Optional fields keep drafts saved by 1.0 readable.
    var pdf: Bool?
    var roles: [String]?
    var plan: ReadingPlan?
    var restored: Set<String>?
    // Optional so older saved drafts continue to load. Set only after a successful import.
    var sourceURL: String?
    var originalURL: URL? { sourceURL.flatMap(SourceLocation.validated) }
    var isPaper: Bool { pdf ?? (note.range(of: #"^\d+ pages?(?:$| ·)"#, options: .regularExpression) != nil) }
}

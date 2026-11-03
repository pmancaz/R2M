import Foundation

@main struct SourceLocationTests {
    static func main() throws {
        let legacy = Data(#"{"title":"Legacy article","text":"Original words","note":"example.org"}"#.utf8)
        var draft = try JSONDecoder().decode(Draft.self, from: legacy)
        precondition(draft.sourceURL == nil && draft.originalURL == nil)
        precondition(draft.text == "Original words")

        let website = SourceLocation.imported(kind: "link", source: " example.org/article?section=2#figure-1 \n")!
        precondition(website.absoluteString == "https://example.org/article?section=2#figure-1")
        draft.sourceURL = website.absoluteString
        let restored = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(draft))
        precondition(restored.originalURL == website && restored.text == draft.text)
        precondition(SourceLocation.imported(kind: "link", source: "https://example.org/a.pdf?download=1")!.query == "download=1")

        let pdf = SourceLocation.imported(kind: "pdf", source: "/tmp/R2M papers/A #1.pdf")!
        precondition(pdf.isFileURL && pdf.path == "/tmp/R2M papers/A #1.pdf")
        for value in ["javascript:alert(1)", "mailto:reader@example.org", "ftp://example.org/a.pdf", "https://", "https://user:password@example.org/"] {
            precondition(SourceLocation.validated(value) == nil, "Unexpected source: " + value)
        }
        precondition(SourceLocation.imported(kind: "speech", source: "example.org") == nil)
        print("PASS: legacy drafts, source persistence, exact URLs/fragments, PDF paths and source validation")
    }
}

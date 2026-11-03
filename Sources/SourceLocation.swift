import Foundation

// Persist the exact imported source separately from extracted text and metadata.
// Keep this compatible with older drafts that have no source location.
enum SourceLocation {
    static func validated(_ value: String) -> URL? {
        guard let url = URL(string: value) else { return nil }
        if url.isFileURL { return url }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func imported(kind: String, source: String) -> URL? {
        if kind == "pdf" {
            return URL(fileURLWithPath: source).standardizedFileURL
        }
        guard kind == "link" else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return validated(trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }
}

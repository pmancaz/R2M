import Foundation

enum AudioExport {
    static func filename(for title: String) -> String {
        // PDF metadata may contain control characters or extremely long Unicode
        // graphemes. A Character count alone does not bound filesystem name size.
        let sanitized = title.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == ":" { return "-" }
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { return " " }
            return String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var base = ""
        for character in sanitized.prefix(100) {
            let next = String(character)
            // Leave room for the extension and collision suffixes on common
            // Mac, external and network volumes. Keep whole graphemes intact.
            if base.utf8.count + next.utf8.count > 200 { break }
            base += next
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? "Narration" : base) + ".mp3"
    }
}

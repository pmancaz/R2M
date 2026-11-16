import Foundation

@main struct AudioExportTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("R2M-export-tests-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        precondition(AudioExport.filename(for: "A useful article") == "A useful article.mp3")
        precondition(AudioExport.filename(for: "  Article: methods/results  ") == "Article- methods-results.mp3")
        precondition(AudioExport.filename(for: " \n\t") == "Narration.mp3")
        precondition(AudioExport.filename(for: "A\u{0000}B") == "A B.mp3")
        let family = "👨‍👩‍👧‍👦"
        precondition(AudioExport.filename(for: family) == family + ".mp3")

        for title in [String(repeating: family, count: 100),
                      String(repeating: "a" + String(repeating: "\u{0301}", count: 10), count: 100),
                      "a" + String(repeating: "\u{0301}", count: 300),
                      String(repeating: "字", count: 100),
                      "A\u{0000}B\nC"] {
            let name = AudioExport.filename(for: title)
            precondition(name.utf8.count <= 204)
            let url = directory.appendingPathComponent(name)
            try Data("first recording".utf8).write(to: url)
            let saved = try Data(contentsOf: url)
            precondition(saved == Data("first recording".utf8))
            try fm.removeItem(at: url)
        }
        print("Audio export filename checks passed")
    }
}

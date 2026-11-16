import Foundation
import SwiftUI
import CryptoKit
import Darwin

// Compile the real chat controller and view without the application's @main.
final class Studio: ObservableObject {
    @Published var draft = Draft()
}

@main
struct ChatPersistenceTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func legacyKey(_ title: String, _ source: String) -> String {
        SHA256.hash(data: Data((title + "\n" + source).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func main() throws {
        guard let override = ProcessInfo.processInfo.environment["R2M_DATA_DIR"],
              override.contains("work/") || override.contains("/tmp/") || override.contains("/private/var/") else {
            fatalError("Run with an isolated R2M_DATA_DIR")
        }
        // A fresh namespace makes repeated regression runs independent while
        // keeping every fixture below the caller's isolated audit directory.
        let runDirectory = URL(fileURLWithPath: override, isDirectory: true)
            .appendingPathComponent("ChatPersistence-" + UUID().uuidString, isDirectory: true)
        setenv("R2M_DATA_DIR", runDirectory.path, 1)
        let fm = FileManager.default
        let library = R2MPaths.dataDirectory.appendingPathComponent("Chats")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)

        let chat = PaperChat()
        chat.bind(title: "A\nB", source: "C")
        chat.messages = [ChatTurn(role: "assistant", content: "First paper's private conversation")]
        chat.bind(title: "A", source: "B\nC")
        check(chat.messages.isEmpty, "Changing to a distinct title/source pair must not retain the previous paper's conversation")
        chat.messages = [ChatTurn(role: "assistant", content: "Second paper's conversation")]
        chat.close()
        chat.bind(title: "A\nB", source: "C")
        check(chat.messages.first?.content == "First paper's private conversation", "The first paper's saved chat must remain independent")
        chat.close()

        let unicodeTitle = "Δοκιμή 👩🏿‍🚀"
        let unicodeSource = "α ≤ β\n\nThe author’s second paragraph."
        let saved = ChatTurn(role: "assistant", content: "An explanation [P2].", sources: [PaperSource(number: 2, text: "The author’s second paragraph.")], notice: "Response stopped.")
        chat.bind(title: unicodeTitle, source: unicodeSource)
        chat.messages = [ChatTurn(role: "user", content: "What does α mean?"), saved]
        chat.close()
        let reopened = PaperChat()
        reopened.bind(title: unicodeTitle, source: unicodeSource)
        check(reopened.messages.count == 2, "Conversation should survive closing and reopening")
        check(reopened.messages.last?.sources.first?.text == saved.sources.first?.text, "Exact Unicode source passages must survive persistence")
        check(reopened.messages.last?.notice == saved.notice, "Stopped-response notices must survive persistence")
        reopened.close()

        let legacyTitle = "Legacy paper"
        let legacySource = "A paper saved by version 3.1.1."
        let legacyURL = library.appendingPathComponent(legacyKey(legacyTitle, legacySource) + ".json")
        let oldBytes = try JSONEncoder().encode([ChatTurn(role: "user", content: "A previous question"), ChatTurn(role: "assistant", content: "A previous answer")])
        try oldBytes.write(to: legacyURL)
        let oldFileCount = try fm.contentsOfDirectory(atPath: library.path).count
        let migrated = PaperChat()
        migrated.bind(title: legacyTitle, source: legacySource)
        check(migrated.messages.last?.content == "A previous answer", "Existing chat files must remain readable")
        migrated.close()
        let retainedLegacyBytes = try Data(contentsOf: legacyURL)
        let newFileCount = try fm.contentsOfDirectory(atPath: library.path).count
        check(retainedLegacyBytes == oldBytes, "Legacy history must not be deleted or modified")
        check(newFileCount == oldFileCount + 1, "Future saves must use an unambiguous new document key")

        let stopped = PaperChat()
        stopped.bind(title: "Interrupted answer", source: "A test article.")
        stopped.messages = [ChatTurn(role: "user", content: "Explain this."), ChatTurn(role: "assistant", content: "A partial explanation")]
        stopped.busy = true
        stopped.stop()
        check(!stopped.busy && stopped.messages.last?.notice == "Response stopped.", "Stopping should preserve and label a partial answer")
        stopped.close()

        let emptyPaper = PaperChat()
        emptyPaper.bind(title: "Blank article", source: " \n\t")
        emptyPaper.send("Explain this.", thinking: false)
        check(!emptyPaper.busy && emptyPaper.messages.isEmpty && emptyPaper.problem == nil, "Whitespace-only articles must not start a model job or consume a question")
        emptyPaper.close()

        let beforeCorruptFixture = Set(try fm.contentsOfDirectory(atPath: library.path))
        let corruptFixture = PaperChat()
        corruptFixture.bind(title: "Corrupt saved conversation", source: "An unchanged test article.")
        corruptFixture.close()
        let afterCorruptFixture = Set(try fm.contentsOfDirectory(atPath: library.path))
        guard let corruptName = afterCorruptFixture.subtracting(beforeCorruptFixture).first else {
            fatalError("A fresh fixture should create its own saved conversation")
        }
        let corruptURL = library.appendingPathComponent(corruptName)
        let damagedBytes = Data("{\"interrupted JSON\":".utf8)
        try damagedBytes.write(to: corruptURL)
        let recovered = PaperChat()
        recovered.bind(title: "Corrupt saved conversation", source: "An unchanged test article.")
        check(recovered.problem != nil, "Unreadable saved history must be reported")
        recovered.close()
        let preservedOnClose = try Data(contentsOf: corruptURL)
        check(preservedOnClose == damagedBytes, "Opening and closing must not overwrite unreadable history with an empty conversation")
        recovered.messages = [ChatTurn(role: "user", content: "A new question"), ChatTurn(role: "assistant", content: "A new answer")]
        recovered.close()
        let newHistory = try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: corruptURL))
        check(newHistory.last?.content == "A new answer", "New conversations should still be saved after recovery")
        let archives = try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        check(archives.contains { (try? Data(contentsOf: $0)) == damagedBytes }, "The unreadable original must be preserved before replacement")

        let damagedLegacyURL = library.appendingPathComponent(legacyKey("Damaged legacy paper", "Legacy source.") + ".json")
        try damagedBytes.write(to: damagedLegacyURL)
        let damagedLegacy = PaperChat()
        damagedLegacy.bind(title: "Damaged legacy paper", source: "Legacy source.")
        let legacyFileCount = try fm.contentsOfDirectory(atPath: library.path).count
        damagedLegacy.close()
        let countAfterEmptyClose = try fm.contentsOfDirectory(atPath: library.path).count
        check(countAfterEmptyClose == legacyFileCount, "Unreadable legacy history must not be hidden behind a newly saved empty file")
        damagedLegacy.messages = [ChatTurn(role: "user", content: "A fresh conversation")]
        damagedLegacy.close()
        let damagedLegacyOriginal = try Data(contentsOf: damagedLegacyURL)
        check(damagedLegacyOriginal == damagedBytes, "Starting a new conversation must preserve the unreadable legacy original")

        if geteuid() != 0 {
            // The owner can read the history but cannot create its protective
            // backup. Saving must fail closed instead of replacing the file.
            try damagedBytes.write(to: corruptURL)
            let blocked = PaperChat()
            blocked.bind(title: "Corrupt saved conversation", source: "An unchanged test article.")
            blocked.messages = [ChatTurn(role: "user", content: "An unsaved fresh question")]
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.path)
            blocked.close()
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.path)
            let unmodified = try Data(contentsOf: corruptURL)
            check(unmodified == damagedBytes && blocked.problem != nil, "An unsuccessful backup must leave the original history unchanged")
        }
        print("PASS: chat isolation, Unicode sources, legacy compatibility, stopped answers, whitespace guard, and corrupt-history preservation")
    }
}

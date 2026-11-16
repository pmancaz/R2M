import Foundation

@main struct DraftStoreTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("R2M-draft-tests-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fm.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("Current Draft.json")
        let absent = DraftStore(file: file)
        let missing = try absent.load()
        precondition(missing == nil)

        // Old drafts remain readable without any optional modern fields.
        let legacy = directory.appendingPathComponent("Legacy Draft.json")
        let legacyBytes = Data(#"{"title":"Legacy title","text":"Legacy αβ café 🧪 text","note":""}"#.utf8)
        try legacyBytes.write(to: legacy)
        let migrated = DraftStore(file: file)
        let oldDraft = try migrated.load(from: legacy)
        precondition(oldDraft?.text == "Legacy αβ café 🧪 text")
        try migrated.save(oldDraft!)
        let unchangedLegacy = try Data(contentsOf: legacy)
        precondition(unchangedLegacy == legacyBytes)

        let corruptBytes = Data(#"{"title":"Recovery","text":"Original nonempty text""#.utf8)
        try corruptBytes.write(to: file)
        let corrupt = DraftStore(file: file)
        do { _ = try corrupt.load(); preconditionFailure("Invalid JSON must fail") } catch {}
        try corrupt.save(Draft(title: "New draft", text: "New text"))
        let backups = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Current Draft.recovery-") }
        precondition(backups.count == 1)
        let recovery = try Data(contentsOf: backups[0])
        precondition(recovery == corruptBytes)
        let current = try DraftStore(file: file).load()
        precondition(current?.text == "New text")
        try corrupt.save(Draft(title: "Next draft", text: "Next text"))
        let filesAfterRetry = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Current Draft.recovery-") }
        precondition(filesAfterRetry.count == 1)

        // If preserving the original fails, even a normal close/autosave must not replace it.
        try corruptBytes.write(to: file)
        let blocked = DraftStore(file: file)
        do { _ = try blocked.load(); preconditionFailure("Invalid JSON must fail") } catch {}
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        do { try blocked.save(Draft(text: "Must not overwrite")); preconditionFailure("Backup must fail") } catch {}
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let protected = try Data(contentsOf: file)
        precondition(protected == corruptBytes)

        // A read-permission failure used to be especially dangerous: atomic
        // replacement can succeed without permission to read the original file.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let unreadable = DraftStore(file: file)
        do { _ = try unreadable.load(); preconditionFailure("Unreadable file must fail") } catch {}
        do { try unreadable.save(Draft(text: "Must not overwrite")); preconditionFailure("Unreadable backup must fail") } catch {}
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let unreadableOriginal = try Data(contentsOf: file)
        precondition(unreadableOriginal == corruptBytes)
        print("Draft load, legacy migration, corruption recovery and failed-backup preservation checks passed")
    }
}

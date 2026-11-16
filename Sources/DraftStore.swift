import Foundation

final class DraftStore {
    let file: URL
    private var needsBackup = false
    private var unreadableBytes: Data?

    init(file: URL) { self.file = file }

    func load(from source: URL? = nil) throws -> Draft? {
        let source = source ?? file
        var bytes: Data?
        do {
            let saved = try Data(contentsOf: source)
            bytes = saved
            return try JSONDecoder().decode(Draft.self, from: saved)
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileReadNoSuchFile.rawValue {
                return nil
            }
            // A failed legacy import never overwrites that legacy file. A failed
            // current draft must be preserved before any subsequent autosave.
            if source.standardizedFileURL == file.standardizedFileURL {
                needsBackup = true
                unreadableBytes = bytes
            }
            throw error
        }
    }

    func save(_ draft: Draft) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if needsBackup {
            // Re-read only if the initial read failed. If that is still impossible,
            // saving fails without replacing an original we cannot preserve.
            let original = try unreadableBytes ?? Data(contentsOf: file)
            let backup = directory.appendingPathComponent("Current Draft.recovery-" + UUID().uuidString + ".json")
            try original.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            needsBackup = false
            unreadableBytes = nil
        }
        try JSONEncoder().encode(draft).write(to: file, options: .atomic)
    }
}

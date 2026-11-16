import Foundation

@main struct StudioPersistenceTests {
    static func main() throws {
        guard ProcessInfo.processInfo.environment["R2M_DATA_DIR"] != nil else {
            fatalError("Set R2M_DATA_DIR to a fresh isolated test directory")
        }
        let fm = FileManager.default
        let directory = R2MPaths.dataDirectory
        let file = directory.appendingPathComponent("Current Draft.json")
        precondition(!fm.fileExists(atPath: file.path), "Use a fresh test directory")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let studio = Studio()
        studio.draft.text = "Text that must remain available after a failed save"

        // A directory at the file path produces a real, repeatable write failure.
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        precondition(!studio.saveDraft())
        precondition(studio.problem != nil && studio.problem == studio.draftSaveError)
        studio.problem = nil // The user dismisses the first autosave alert.
        precondition(!studio.saveDraft())
        precondition(studio.problem == nil, "Continuous failed autosaves must not repeatedly alert")

        // The dedicated quit confirmation acknowledges an existing matching
        // alert, including one queued shortly before the modal loop began.
        studio.problem = studio.draftSaveError
        studio.acknowledgeDraftSaveError()
        precondition(studio.problem == nil)
        precondition(!studio.saveDraft())
        precondition(studio.problem == nil, "Late autosave after Keep Open must stay quiet")

        studio.problem = "An unrelated voice preview error"
        studio.acknowledgeDraftSaveError()
        precondition(studio.problem == "An unrelated voice preview error")
        studio.problem = nil

        // A successful save ends the failure episode. New failures must be reported.
        try fm.removeItem(at: file)
        precondition(studio.saveDraft())
        precondition(studio.draftSaveError == nil)
        try fm.removeItem(at: file)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        precondition(!studio.saveDraft(reportFailure: false))
        precondition(studio.problem == nil)
        studio.acknowledgeDraftSaveError()
        precondition(!studio.saveDraft())
        precondition(studio.problem == nil)
        try fm.removeItem(at: file)
        precondition(studio.saveDraft())
        try fm.removeItem(at: file)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        precondition(!studio.saveDraft())
        precondition(studio.problem != nil, "A new failure after recovery must alert again")
        try fm.removeItem(at: file)
        precondition(studio.saveDraft())

        // Malformed startup state is reported, and normal close preserves its bytes.
        let invalid = Data(#"{"text":"Original damaged draft""#.utf8)
        try invalid.write(to: file)
        let recovered = Studio()
        precondition(recovered.problem != nil)
        recovered.shutdown()
        let backups = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Current Draft.recovery-") }
        precondition(backups.count == 1)
        let preserved = try Data(contentsOf: backups[0])
        precondition(preserved == invalid)
        print("Studio recovery and save-error notification checks passed")
    }
}

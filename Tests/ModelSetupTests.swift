import AppKit
import SwiftUI

@main struct ModelSetupTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func pump(until predicate: () -> Bool, seconds: Double = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    static func main() throws {
        let root = R2MPaths.modelsDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let models = LocalModels()
        models.selected = ["speech"]
        models.download()
        let pidFile = root.appendingPathComponent("worker.pid")
        pump(until: { FileManager.default.fileExists(atPath: pidFile.path) })
        require(models.busy, "download starts")
        let pid = Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))!
        let folder = URL(fileURLWithPath: try String(contentsOf: root.appendingPathComponent("worker.job")).trimmingCharacters(in: .whitespacesAndNewlines))
        models.cancel()
        require(kill(pid, 0) == 0, "fixture worker has not finished its delayed termination")
        require(models.busy, "retry stays blocked until cancelled worker releases its lock")
        require(FileManager.default.fileExists(atPath: folder.path), "job files stay available until the worker exits")
        models.download()
        let currentPID = try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)
        require(currentPID == String(pid), "no second worker starts during cancellation")
        pump(until: { !models.busy })
        require(!models.busy, "cancellation completes")
        require(kill(pid, 0) != 0, "cancelled worker is reaped")
        require(!FileManager.default.fileExists(atPath: folder.path), "job directory is cleaned after process termination")
        require(models.status.hasPrefix("Download paused"), "resume status is retained")
        require(models.problem == nil, "normal cancellation is not shown as a download failure")
        print("PASS: cancellation waits for worker exit, blocks retries and cleans job files safely")
    }
}

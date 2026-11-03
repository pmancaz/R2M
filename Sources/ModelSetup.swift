import AppKit
import SwiftUI

struct ModelFile: Decodable {
    let path: String
    let size: Int64
    let sha256: String
}
struct ModelAsset: Decodable, Identifiable {
    let id: String
    let name: String
    let revision: String
    let bytes: Int64
    let files: [ModelFile]
    var title: String {
        switch id { case "speech": return "Speech"; case "cleanup": return "Text cleanup"; default: return "Paper chat" }
    }
    var explanation: String {
        switch id {
        case "speech": return "Turns written text into natural speech on this Mac. Required to generate audio."
        case "cleanup": return "Helps identify publisher notices and PDF import artifacts. You can also skip citations and references, and review changes before listening."
        default: return "Lets you ask questions about the loaded paper, using its text as context. Optional."
        }
    }
    var downloadSize: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
struct ModelCatalog: Decodable {
    let version: Int
    let models: [ModelAsset]
}
enum ModelPrompt: String, Identifiable { case setup, speech, chat; var id: String { rawValue } }

final class LocalModels: ObservableObject {
    @Published private(set) var catalog: [ModelAsset] = []
    @Published private(set) var installed: Set<String> = []
    @Published var selected: Set<String> = ["speech", "cleanup"]
    @Published var prompt: ModelPrompt?
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var downloaded: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var problem: String?
    private var version = 1
    private var task: Process?
    private var timer: Timer?
    private var job: URL?
    private var checkedFirstLaunch = false
    private var activeIDs = Set<String>()
    private var terminationObserver: NSObjectProtocol?

    init() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("models.json"),
           let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(ModelCatalog.self, from: data) {
            catalog = value.models; version = value.version
        } else { problem = "The model download catalog is missing. Please download a fresh copy of R2M." }
        refresh()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() }
    }
    var chatMinimum: String { Bundle.main.object(forInfoDictionaryKey: "R2MChatMinimumSystemVersion") as? String ?? "26.2" }
    func supported(_ id: String) -> Bool {
        guard id == "chat" else { return true }
        let parts = chatMinimum.split(separator: ".").compactMap { Int($0) }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
            majorVersion: parts.first ?? 26, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0))
    }
    func has(_ id: String) -> Bool { installed.contains(id) && supported(id) }
    func refresh() {
        var ready = Set<String>()
        for asset in catalog {
            let directory = R2MPaths.modelsDirectory.appendingPathComponent(asset.id)
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent(".installed.json")),
                  let marker = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  marker["revision"] as? String == asset.revision,
                  marker["manifest_version"] as? Int == version,
                  marker["id"] as? String == asset.id,
                  let markerFiles = marker["files"] as? [[String: Any]], markerFiles.count == asset.files.count else { continue }
            if asset.files.allSatisfy({ file in
                let path = directory.appendingPathComponent(file.path).path
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let recorded = markerFiles.first { $0["path"] as? String == file.path }
                return (attributes?[.size] as? NSNumber)?.int64Value == file.size
                    && (recorded?["size"] as? NSNumber)?.int64Value == file.size
                    && recorded?["sha256"] as? String == file.sha256
            }) { ready.insert(asset.id) }
        }
        installed = ready
    }
    func firstLaunch() {
        guard !checkedFirstLaunch else { return }
        checkedFirstLaunch = true
        refresh()
        if !has("speech") { present(.setup) }
    }
    func present(_ value: ModelPrompt) {
        guard !busy else { return }
        problem = catalog.isEmpty ? "The model download catalog is missing. Please download a fresh copy of R2M." : nil
        refresh()
        status = ""; progress = 0; downloaded = 0; total = 0
        if value == .chat { selected = ["chat"] }
        else if value == .speech { selected = ["speech"] }
        else { selected = ["speech", "cleanup"] }
        prompt = value
    }
    var pending: Set<String> { selected.subtracting(installed).filter { supported($0) } }
    var pendingBytes: Int64 { catalog.filter { pending.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
    func download() {
        guard !busy, !pending.isEmpty, let resources = Bundle.main.resourceURL else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("R2M-Install-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            activeIDs = pending
            let request: [String: Any] = ["kind": "install", "models": catalog.filter { activeIDs.contains($0.id) }.map(\.id)]
            try JSONSerialization.data(withJSONObject: request).write(to: folder.appendingPathComponent("request.json"))
            let process = Process()
            process.executableURL = resources.appendingPathComponent("runtime/bin/python3.11")
            process.arguments = ["-I", "-B", resources.appendingPathComponent("asset_manager.py").path, folder.path]
            var environment = ProcessInfo.processInfo.environment
            environment["R2M_MODEL_DIR"] = R2MPaths.modelsDirectory.path
            process.environment = environment
            process.currentDirectoryURL = folder
            FileManager.default.createFile(atPath: folder.appendingPathComponent("download.log").path, contents: nil)
            let log = try FileHandle(forWritingTo: folder.appendingPathComponent("download.log"))
            process.standardOutput = log; process.standardError = log
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.task === process else { return }
                    self.poll()
                    if self.busy {
                        self.problem = "The download stopped before it finished. You can retry to resume it."
                        self.finish()
                    }
                }
            }
            problem = nil; progress = 0; downloaded = 0; total = pendingBytes
            status = "Preparing downloads…"; job = folder; task = process; busy = true
            try process.run(); try? log.close()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        } catch {
            problem = "The download could not start. " + error.localizedDescription
            finish()
        }
    }
    private func read(_ file: String) -> [String: Any]? {
        guard let job, let bytes = try? Data(contentsOf: job.appendingPathComponent(file)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
    private func poll() {
        if let value = read("progress.json") {
            status = value["message"] as? String ?? status
            if let f = value["fraction"] as? Double, f.isFinite { progress = min(1, max(progress, f)) }
            downloaded = (value["downloaded"] as? NSNumber)?.int64Value ?? downloaded
            total = (value["total"] as? NSNumber)?.int64Value ?? total
        }
        guard let result = read("result.json") else { return }
        refresh()
        if let error = result["error"] as? String { problem = error }
        else if !activeIDs.isSubset(of: installed) { problem = "Some model files could not be verified. Retry to finish installing them." }
        else { progress = 1; status = "Models installed. Ready to use." }
        finish()
    }
    private func finish() {
        timer?.invalidate(); timer = nil; task = nil; busy = false
        if let job { try? FileManager.default.removeItem(at: job) }
        job = nil
        refresh()
    }
    func cancel() {
        let process = task
        task = nil
        if process?.isRunning == true { process?.terminate() }
        status = "Download paused. Retry to resume it."
        finish()
    }
}

struct ModelSetupView: View {
    @ObservedObject var models: LocalModels
    let reason: ModelPrompt
    @Environment(\.dismiss) private var dismiss
    private var assets: [ModelAsset] { reason == .chat ? models.catalog.filter { $0.id == "chat" } : models.catalog }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(reason == .chat ? "Enable paper chat" : "Set up R2M").font(.system(size: 22, weight: .semibold))
                Text(reason == .chat ? "Download the chat model to enable this feature." : "Choose the models to install. Speech and text cleanup are recommended; paper chat is optional.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(assets) { asset in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(asset.title).font(.system(size: 14, weight: .semibold))
                            Text(asset.downloadSize).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text(asset.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !models.supported(asset.id) {
                            Text("Paper chat requires macOS \(models.chatMinimum) or later on this build.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if models.installed.contains(asset.id) {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(R2MTheme.accent).font(.system(size: 12))
                    } else {
                        Toggle("Download " + asset.title, isOn: Binding(get: { models.selected.contains(asset.id) }, set: { on in
                            if on { models.selected.insert(asset.id) } else { models.selected.remove(asset.id) }
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel("Download " + asset.title)
                            .disabled(models.busy || !models.supported(asset.id))
                    }
                }.padding(16).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            if models.busy || !models.status.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(models.status).lineLimit(2); Spacer(); Text("\(Int(models.progress * 100))%").monospacedDigit() }
                    ProgressView(value: models.progress).accessibilityLabel("Model download progress")
                    if models.total > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: models.downloaded, countStyle: .file) + " of " + ByteCountFormatter.string(fromByteCount: models.total, countStyle: .file))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            if let problem = models.problem { Text(problem).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Text("Models download from Hugging Face. Your text is processed on this Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                if models.busy {
                    Button("Cancel download") { models.cancel() }
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                if !models.pending.isEmpty {
                    Button(models.problem != nil ? "Retry download" : (models.status.hasPrefix("Download paused") ? "Resume download" : "Download selected")) { models.download() }
                        .r2mPrimaryAction().controlSize(.large).disabled(models.busy)
                } else if !models.busy {
                    Button("Done") { dismiss() }.r2mPrimaryAction().controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).r2mAppearance().frame(width: 570)
         .interactiveDismissDisabled(models.busy)
    }
}

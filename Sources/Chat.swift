import SwiftUI
import AppKit
import CryptoKit

struct PaperSource: Codable, Identifiable {
    let number: Int
    let text: String
    var id: Int { number }
}
struct ChatTurn: Codable, Identifiable {
    var id = UUID()
    let role: String
    var content: String
    var sources: [PaperSource] = []
    var notice: String = ""
}
final class PaperChat: ObservableObject {
    @Published var messages: [ChatTurn] = []
    @Published var busy = false
    @Published var status = ""
    @Published var progress: Double?
    @Published var problem: String?
    @Published var context = ""
    private var title = ""
    private var source = ""
    private var key = ""
    private var worker: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private var job: URL?
    private var unreadableHistoryURL: URL?
    private let fm = FileManager.default
    private let session = FileManager.default.temporaryDirectory.appendingPathComponent("Kokoro-Chat-" + UUID().uuidString)
    private let library = R2MPaths.dataDirectory.appendingPathComponent("Chats")

    func bind(title: String, source: String) {
        // Frame the title length: joining two arbitrary strings with a newline
        // makes distinct papers share a history when the title contains one.
        let identity = "R2M paper v2\n\(title.utf8.count):" + title + source
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest != key else { return }
        close()
        unreadableHistoryURL = nil
        self.title = title
        self.source = source
        key = digest
        messages = []
        problem = nil
        context = ""
        let savedURL = library.appendingPathComponent(key + ".json")
        let legacyDigest = SHA256.hash(data: Data((title + "\n" + source).utf8)).map { String(format: "%02x", $0) }.joined()
        // Keep earlier conversations readable without deleting or rewriting
        // their original files. Future saves use the framed identity above.
        let loadURL = fm.fileExists(atPath: savedURL.path) ? savedURL : library.appendingPathComponent(legacyDigest + ".json")
        if fm.fileExists(atPath: loadURL.path) {
            do {
                messages = try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: loadURL))
            } catch {
                unreadableHistoryURL = loadURL
                problem = "The saved conversation could not be read. Its original file has been kept unchanged; you can start a new conversation."
            }
        }
    }
    private func save() {
        guard !key.isEmpty else { return }
        let turns = messages.filter { !$0.content.isEmpty }
        // An automatic close/rebind must not turn an unreadable history into [].
        guard unreadableHistoryURL == nil || !turns.isEmpty else { return }
        do {
            try fm.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = library.appendingPathComponent(key + ".json")
            if let unreadable = unreadableHistoryURL, unreadable == destination,
               fm.fileExists(atPath: unreadable.path) {
                // Preserve the bytes before the first deliberate new conversation
                // replaces a damaged current-format file. Legacy files stay put.
                let backup = library.appendingPathComponent(key + ".unreadable-" + UUID().uuidString + ".json")
                try fm.copyItem(at: unreadable, to: backup)
            }
            try JSONEncoder().encode(turns).write(to: destination, options: .atomic)
            unreadableHistoryURL = nil
        } catch {
            problem = unreadableHistoryURL == nil
                ? "The conversation could not be saved on this Mac."
                : "The conversation could not be saved. The previous history has been kept unchanged."
        }
    }
    private func startWorker() throws {
        if worker?.isRunning == true { return }
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        try fm.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let task = Process()
        let pipe = Pipe()
        task.executableURL = resources.appendingPathComponent("runtime/bin/python3.11")
        task.arguments = ["-I", "-B", resources.appendingPathComponent("chat_worker.py").path]
        task.currentDirectoryURL = session
        var environment = ProcessInfo.processInfo.environment
        environment["R2M_MODEL_DIR"] = R2MPaths.modelsDirectory.path
        task.environment = environment
        task.standardInput = pipe
        let log = session.appendingPathComponent("chat.log")
        fm.createFile(atPath: log.path, contents: nil)
        let file = try FileHandle(forWritingTo: log)
        task.standardOutput = file
        task.standardError = file
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, self.worker === task else { return }
                self.worker = nil
                self.input = nil
                if self.busy {
                    self.problem = "The local model stopped. You can send your question again."
                    self.finishJob()
                }
            }
        }
        try task.run()
        try? file.close()
        worker = task
        input = pipe.fileHandleForWriting
    }
    func send(_ question: String, thinking: Bool) {
        guard !busy, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        problem = nil
        let history = messages.map { ["role": $0.role, "content": $0.content] }
        let folder = session.appendingPathComponent(UUID().uuidString)
        do {
            try startWorker()
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let request: [String: Any] = ["title":title, "source":source, "history":history, "question":text, "thinking":thinking]
            try JSONSerialization.data(withJSONObject: request).write(to: folder.appendingPathComponent("request.json"))
            messages.append(ChatTurn(role: "user", content: text))
            messages.append(ChatTurn(role: "assistant", content: ""))
            job = folder
            busy = true
            status = "Preparing the local model…"
            progress = nil
            var line = try JSONSerialization.data(withJSONObject: ["folder":folder.path])
            line.append(10)
            try input?.write(contentsOf: line)
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.poll(folder) }
        } catch {
            problem = "The chat could not start. " + error.localizedDescription
            finishJob()
        }
    }
    private func read(_ name: String, in folder: URL) -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
    private func poll(_ folder: URL) {
        guard folder == job else { return }
        if let update = read("stream.json", in: folder) {
            status = update["status"] as? String ?? status
            progress = update["fraction"] as? Double
            let newContext = update["context"] as? String ?? ""
            if !newContext.isEmpty { context = newContext }
            if let answer = update["answer"] as? String, !messages.isEmpty { messages[messages.count - 1].content = answer }
        }
        guard let result = read("result.json", in: folder) else { return }
        if let error = result["error"] as? String { problem = error }
        else if !messages.isEmpty, let answer = result["answer"] as? String {
            let index = messages.count - 1
            messages[index].content = answer
            messages[index].notice = result["notice"] as? String ?? ""
            if let values = result["sources"],
               let bytes = try? JSONSerialization.data(withJSONObject: values),
               let sources = try? JSONDecoder().decode([PaperSource].self, from: bytes) { messages[index].sources = sources }
        }
        finishJob()
    }
    private func finishJob() {
        timer?.invalidate()
        timer = nil
        if let job { try? fm.removeItem(at: job) }
        job = nil
        busy = false
        progress = nil
        status = ""
        messages.removeAll { $0.role == "assistant" && $0.content.isEmpty }
        save()
    }
    func stop() {
        if busy, let last = messages.indices.last, messages[last].role == "assistant", !messages[last].content.isEmpty {
            messages[last].notice = "Response stopped."
        }
        let task = worker
        worker = nil
        input = nil
        if task?.isRunning == true { task?.terminate() }
        finishJob()
    }
    func close() {
        stop()
        try? fm.removeItem(at: session)
    }
}

struct PaperChatView: View {
    @ObservedObject var chat: PaperChat
    @ObservedObject var studio: Studio
    @State private var question = ""
    @State private var selectedSource: PaperSource?
    @AppStorage("deeperReasoning") private var thinking = true

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chat.send(text, thinking: thinking)
        question = ""
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Chat with this paper", systemImage: "text.bubble").font(.system(size: 20, weight: .semibold))
                Text(studio.draft.title.isEmpty ? "Current article" : studio.draft.title)
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Text("Qwen3.5").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Deeper reasoning", isOn: $thinking)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12)).disabled(chat.busy)
                        .help("Allows more thinking time before the answer appears.")
                }
                if !chat.context.isEmpty { Text(chat.context).font(.system(size: 12)).foregroundStyle(.secondary) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
             .r2mControlSurface()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(["What is the paper's central argument?", "Explain the main ideas in plain language.", "What are the limitations of the author's argument?"], id: \.self) { text in
                                    Button(text) { question = text }.buttonStyle(.link).foregroundStyle(R2MTheme.accent)
                                }
                            }.padding(18)
                        }
                        ForEach(chat.messages) { message in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(message.role == "user" ? "You" : "R2M").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                if !message.content.isEmpty {
                                    Text(.init(message.content)).font(.system(size: 13)).lineSpacing(3)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                } else { Text(chat.status).foregroundStyle(.secondary) }
                                if !message.sources.isEmpty {
                                    ViewThatFits(in: .horizontal) {
                                        HStack {
                                            ForEach(message.sources) { source in Button("Passage \(source.number)") { selectedSource = source }.controlSize(.small) }
                                        }
                                        VStack(alignment: .leading) {
                                            ForEach(message.sources) { source in Button("Passage \(source.number)") { selectedSource = source }.controlSize(.small) }
                                        }
                                    }
                                }
                                if !message.notice.isEmpty { Text(message.notice).font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                            .padding(16).background(message.role == "user" ? R2MTheme.accent.opacity(0.08) : Color(nsColor: .textBackgroundColor),
                                                    in: RoundedRectangle(cornerRadius: 12))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20)
                }
                .onChange(of: chat.messages.last?.content) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if chat.busy {
                    HStack {
                        if let value = chat.progress { ProgressView(value: value).frame(width: 100) }
                        else { ProgressView().controlSize(.small) }
                        Text(chat.status).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { chat.stop() }
                    }
                }
                if let problem = chat.problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Ask about the paper, or paste a sentence…", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5).font(.system(size: 13))
                        .accessibilityLabel("Question about this paper")
                    Button { send() } label: { Label("Send", systemImage: "arrow.up") }
                        .r2mPrimaryAction().tint(R2MTheme.accent).controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(chat.busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || studio.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(16).r2mControlSurface()
        }
        .r2mAppearance()
        .frame(minWidth: 540, minHeight: 480)
        .onAppear { chat.bind(title: studio.draft.title, source: studio.draft.text) }
        .onChange(of: studio.draft.text) {
            selectedSource = nil
            chat.bind(title: studio.draft.title, source: studio.draft.text)
        }
        .onChange(of: studio.draft.title) {
            selectedSource = nil
            chat.bind(title: studio.draft.title, source: studio.draft.text)
        }
        .onDisappear { chat.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in chat.close() }
        .sheet(item: $selectedSource) { source in
            VStack(alignment: .leading, spacing: 14) {
                Text("Passage \(source.number)").font(.system(size: 20, weight: .semibold))
                ScrollView {
                    Text(source.text).font(.system(size: 13)).lineSpacing(3)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { selectedSource = nil }.keyboardShortcut(.defaultAction) }
            }.padding(22).r2mAppearance().frame(width: 540, height: 400)
        }
    }
}

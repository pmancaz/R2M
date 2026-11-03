import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class Studio: ObservableObject {
    @Published var draft = Draft()
    @Published var narration = ""
    @Published var changes: [ReadingChange] = []
    @Published var skipReferences = (UserDefaults.standard.object(forKey: "skipReferences") as? Bool) ?? true
    @Published var cleanup = (UserDefaults.standard.object(forKey: "paperCleanup") as? Bool) ?? true
    private var afterPrepare: (String, Double)?
    @Published var jobProgress: Double?
    @Published var busy = false
    @Published var status = ""
    @Published var problem: String?
    @Published var lastDraft: Draft?
    @Published var hasAudio = false
    @Published var playing = false
    @Published var playhead = 0.0
    @Published var duration = 0.0
    @Published var audioTitle = ""
    @Published var previewVoice: String?
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: Timer?
    private var player: AVAudioPlayer?
    private var audioURL: URL?
    private var exportDestination: URL?
    @Published var exportFolder = UserDefaults.standard.string(forKey: "exportFolder")
    @Published var exportedURL: URL?
    private var process: Process?
    private var job: URL?
    private var progressTimer: Timer?
    private var playTimer: Timer?
    private let fm = FileManager.default
    private let session = FileManager.default.temporaryDirectory.appendingPathComponent("Kokoro-" + UUID().uuidString)
    private let draftFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kokoro Reader/Current Draft.json")

    init() {
        if let saved = try? Data(contentsOf: draftFile), let value = try? JSONDecoder().decode(Draft.self, from: saved) {
            draft = value
        }
        refreshPlan()
        // The updater can hand off an already-generated recording before restarting.
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--resume-audio"), arguments.indices.contains(i + 1) {
            do {
                try fm.createDirectory(at: session, withIntermediateDirectories: true)
                let next = session.appendingPathComponent(UUID().uuidString + ".wav")
                try fm.copyItem(at: URL(fileURLWithPath: arguments[i + 1]), to: next)
                player = try AVAudioPlayer(contentsOf: next)
                audioURL = next
                duration = player?.duration ?? 0
                audioTitle = draft.title.isEmpty ? "Narration" : draft.title
                hasAudio = true
            } catch { problem = "The previous recording could not be restored. " + error.localizedDescription }
        }
    }

    func refreshPlan() {
        changes = draft.plan?.changes() ?? []
        render()
    }
    func render() {
        narration = (skipReferences || cleanup)
            ? (draft.plan?.render(skipReferences: skipReferences, cleanup: cleanup, restored: draft.restored ?? []) ?? draft.text)
            : draft.text
    }
    func setOption(references: Bool? = nil, clean: Bool? = nil) {
        if let references { skipReferences = references; UserDefaults.standard.set(references, forKey: "skipReferences") }
        if let clean { cleanup = clean; UserDefaults.standard.set(clean, forKey: "paperCleanup") }
        discardAudio()
        render()
    }
    func changeEnabled(_ id: String, _ enabled: Bool) {
        var values = draft.restored ?? []
        if enabled { values.remove(id) } else { values.insert(id) }
        draft.restored = values
        discardAudio()
        render()
        saveDraft()
    }
    func editSource(_ text: String) {
        guard text != draft.text else { return }
        draft.text = text
        draft.roles = nil
        draft.plan = nil
        draft.restored = nil
        discardAudio()
        refreshPlan()
    }
    func prepare() {
        var input: [String: Any] = ["kind":"prepare", "text":draft.text, "title":draft.title]
        if let roles = draft.roles { input["roles"] = roles }
        run(input, initial: "Preparing listening text…")
    }
    func saveDraft() {
        do {
            try fm.createDirectory(at: draftFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: draftFile, options: .atomic)
        } catch {
            NSLog("Could not save current draft: %@", error.localizedDescription)
        }
    }

    func pickPDF() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.pdf]
        picker.prompt = "Import PDF"
        if picker.runModal() == .OK, let url = picker.url { importPDF(url) }
    }
    func importPDF(_ url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return }
        run(["kind": "pdf", "source": url.path], initial: "Opening PDF…")
    }
    func importLink(_ url: String) { run(["kind": "link", "source": url], initial: "Opening website…") }
    func openSource() {
        guard let url = draft.originalURL else { return }
        if url.isFileURL && !fm.fileExists(atPath: url.path) {
            problem = "The original PDF is no longer at its saved location. Import it again to update the location."
            return
        }
        if !NSWorkspace.shared.open(url) {
            problem = "The original source could not be opened. " + (url.isFileURL ? url.path : url.absoluteString)
        }
    }
    func generate(voice: String, speed: Double) {
        if draft.isPaper && draft.plan == nil && (skipReferences || cleanup) {
            afterPrepare = (voice, speed)
            prepare()
            return
        }
        run(["kind": "speech", "text": draft.isPaper ? narration : draft.text, "voice": voice, "speed": speed], initial: "Preparing the voice…")
    }

    private func run(_ input: [String: Any], initial: String) {
        guard !busy, let resources = Bundle.main.resourceURL else { return }
        let folder = session.appendingPathComponent(UUID().uuidString)
        let task = Process()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: input).write(to: folder.appendingPathComponent("request.json"))
            task.executableURL = resources.appendingPathComponent("runtime/bin/python3.11")
            task.arguments = ["-I", "-B", resources.appendingPathComponent("reader.py").path, folder.path]
            task.currentDirectoryURL = folder
            let log = folder.appendingPathComponent("engine.log")
            fm.createFile(atPath: log.path, contents: nil)
            let file = try FileHandle(forWritingTo: log)
            task.standardOutput = file
            task.standardError = file
            task.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.finish(folder) }
            }
            try task.run()
            try? file.close()
            pause()
            stopPreview()
            process = task
            job = folder
            busy = true
            status = initial
            jobProgress = ["speech","mp3","normalize"].contains(input["kind"] as? String ?? "") ? 0 : nil
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                guard let self, let update = self.read("progress.json", in: folder) else { return }
                if let message = update["message"] as? String { self.status = message }
                if let value = update["fraction"] as? Double, value.isFinite {
                    self.jobProgress = max(self.jobProgress ?? 0, min(1, max(0,value)))
                }
            }
        } catch {
            try? fm.removeItem(at: folder)
            problem = "R2M could not start this job. " + error.localizedDescription
        }
    }

    private func read(_ name: String, in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func finish(_ folder: URL) {
        defer { try? fm.removeItem(at: folder) }
        guard folder == job else { return }
        let continuation = afterPrepare
        let exportURL = exportDestination
        resetJob()
        guard let response = read("result.json", in: folder) else {
            problem = "The reading engine stopped before finishing. Try a shorter passage or import the source again."
            return
        }
        if let message = response["error"] as? String { problem = message; return }
        if let mp3 = response["mp3"] as? String, let exportURL {
            do {
                let destination = availableName(exportURL)
                try copyExport(folder.appendingPathComponent(mp3), to: destination)
                exportedURL = destination
            }
            catch { problem = error.localizedDescription }
        } else if let text = response["text"] as? String {
            lastDraft = draft.text.isEmpty ? nil : draft
            draft = Draft(title: response["title"] as? String ?? "Imported text", text: text, note: response["note"] as? String ?? "")
            if let request = read("request.json", in: folder),
               let kind = request["kind"] as? String, let source = request["source"] as? String {
                draft.sourceURL = SourceLocation.imported(kind: kind, source: source)?.absoluteString
            }
            draft.pdf = response["pdf"] as? Bool ?? false
            draft.roles = response["roles"] as? [String]
            if let plan = response["plan"] { draft.plan = try? ReadingPlan.decode(plan) }
            discardAudio()
            refreshPlan()
            saveDraft()
            if let warning = response["warning"] as? String { problem = warning }
        } else if let value = response["plan"] {
            do {
                draft.plan = try ReadingPlan.decode(value)
                draft.restored = nil
                refreshPlan()
                saveDraft()
                if let (voice,speed) = continuation { generate(voice: voice, speed: speed) }
            } catch { problem = "The listening copy could not be prepared. The source text is available." }
        } else {
            do {
                let next = session.appendingPathComponent(UUID().uuidString + ".wav")
                try fm.moveItem(at: folder.appendingPathComponent("speech.wav"), to: next)
                let newPlayer = try AVAudioPlayer(contentsOf: next)
                _ = newPlayer.prepareToPlay()
                discardAudio()
                player = newPlayer
                audioURL = next
                duration = newPlayer.duration
                audioTitle = draft.title.isEmpty ? "Narration" : draft.title
                hasAudio = true
            } catch { problem = "Could not open the generated audio. " + error.localizedDescription }
        }
    }

    private func resetJob() {
        progressTimer?.invalidate()
        progressTimer = nil
        afterPrepare = nil
        exportDestination = nil
        busy = false
        jobProgress = nil
        status = ""
        job = nil
        process = nil
    }
    func cancel() {
        let running = process
        resetJob()
        if running?.isRunning == true { running?.terminate() }
    }
    func restore() {
        guard !busy, let previous = lastDraft else { return }
        draft = previous
        refreshPlan()
        lastDraft = nil
        discardAudio()
        saveDraft()
    }
    func pause() {
        player?.pause()
        playTimer?.invalidate()
        playing = false
    }
    func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewVoice = nil
    }
    func preview(_ voice: String) {
        if previewVoice == voice { stopPreview(); return }
        stopPreview()
        pause()
        guard let file = Bundle.main.resourceURL?.appendingPathComponent("previews/\(voice).wav") else { return }
        do {
            let sample = try AVAudioPlayer(contentsOf: file)
            previewPlayer = sample
            guard sample.play() else { throw CocoaError(.fileReadUnknown) }
            previewVoice = voice
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.previewPlayer?.isPlaying != true { self.stopPreview() }
            }
        } catch {
            stopPreview()
            problem = "This voice preview could not be played. " + error.localizedDescription
        }
    }
    func togglePlayback() {
        stopPreview()
        guard let player else { return }
        if playing { pause(); return }
        if playhead >= duration - 0.05 { player.currentTime = 0 }
        playing = player.play()
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self, let player = self.player else { t.invalidate(); return }
            if player.isPlaying { self.playhead = player.currentTime }
            else { self.playhead = self.duration; self.playing = false; t.invalidate() }
        }
    }
    func seek(_ value: Double) {
        player?.currentTime = value
        playhead = value
    }
    func discardAudio() {
        pause()
        player = nil
        hasAudio = false
        playhead = 0
        duration = 0
        if let audioURL { try? fm.removeItem(at: audioURL) }
        audioURL = nil
    }
    @discardableResult
    func chooseExportFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose the MP3 export folder"
        panel.prompt = "Use this folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if let exportFolder { panel.directoryURL = URL(fileURLWithPath: exportFolder) }
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        exportFolder = folder.path
        UserDefaults.standard.set(folder.path, forKey: "exportFolder")
        return true
    }
    func saveAudio() {
        guard let audioURL, !busy else { return }
        if exportFolder == nil && !chooseExportFolder() { return }
        guard let exportFolder else { return }
        let directory = URL(fileURLWithPath: exportFolder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            problem = "The export folder is unavailable. Choose an export folder and try again."
            return
        }
        let name = audioTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = directory.appendingPathComponent(String((name.isEmpty ? "Narration" : name).prefix(100)) + ".mp3")
        exportedURL = nil
        exportDestination = destination
        run(["kind": "mp3", "source": audioURL.path], initial: "Exporting MP3…")
    }
    private func availableName(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (\(number)).mp3")
            number += 1
        }
        return candidate
    }
    private func copyExport(_ source: URL, to destination: URL) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        // An atomic move fails safely if another app creates this filename during export.
        try fm.moveItem(at: staged, to: destination)
    }
    func shutdown() {
        stopPreview()
        saveDraft()
        cancel()
        pause()
        try? fm.removeItem(at: session)
    }
}

struct ReaderView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var studio: Studio
    @AppStorage("voice") var voice = "af_heart"
    @AppStorage("speed") var speed = 1.0
    @State private var showLink = false
    @State private var showVoices = false
    @State private var sourceView = false
    @State private var review = false
    @State private var link = ""
    @FocusState private var focusLink: Bool
    @State private var draftSave: DispatchWorkItem?
    private let accent = R2MTheme.accent
    private let voices = [("Heart", "af_heart", "US"), ("Bella", "af_bella", "US"), ("Michael", "am_michael", "US"), ("Emma", "bf_emma", "UK"), ("George", "bm_george", "UK")]
    private func time(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 600
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white).frame(width: 44, height: 44).background(R2MTheme.actionAccent, in: RoundedRectangle(cornerRadius: 12))
                    Text("R2M").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Button { openWindow(id: "paper-chat") } label: { Label("Chat", systemImage: "text.bubble") }
                        .disabled(studio.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { studio.pickPDF() } label: { Label("Import PDF", systemImage: "doc.badge.plus") }
                        .keyboardShortcut("o").disabled(studio.busy)
                    Button { link = ""; showLink = true } label: { Label("Website link", systemImage: "link") }
                        .keyboardShortcut("l").disabled(studio.busy)
                }.controlSize(compact ? .regular : .large).padding(.horizontal, 24).padding(.vertical, compact ? 10 : 16)
                 .r2mControlSurface()
                Divider()
                VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                    HStack {
                        Text(studio.draft.title.isEmpty ? "Reading text" : studio.draft.title)
                            .font(.system(size: 19, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        if studio.lastDraft != nil {
                            Button("Undo import") { studio.restore() }.controlSize(.small).disabled(studio.busy)
                        }
                    }
                    if !studio.draft.note.isEmpty || studio.draft.originalURL != nil {
                        HStack(spacing: 12) {
                            if !studio.draft.note.isEmpty {
                                Text(studio.draft.note).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            if let source = studio.draft.originalURL {
                                Button { studio.openSource() } label: {
                                    Label(source.isFileURL || source.pathExtension.lowercased() == "pdf" ? "Open PDF" : "Open website",
                                          systemImage: "arrow.up.forward.square")
                                }
                                .controlSize(.small)
                                .help(source.isFileURL ? source.path : source.absoluteString)
                            }
                        }.font(.caption)
                    }
                    if studio.draft.isPaper {
                        HStack(spacing: 14) {
                            Toggle("Skip references", isOn: Binding(get: { studio.skipReferences }, set: { studio.setOption(references: $0) }))
                                .help("Skip in-text citations and the bibliography in speech.")
                            Toggle("Clean PDF", isOn: Binding(get: { studio.cleanup }, set: { studio.setOption(clean: $0) }))
                                .help("Skip publisher notices and repair reading order and paragraph breaks.")
                            Spacer()
                            if studio.draft.plan == nil {
                                Button("Prepare listening text") { studio.prepare(); sourceView = false }
                            } else {
                                Button("Review changes…") { review = true }.disabled(studio.changes.isEmpty)
                            }
                        }.toggleStyle(.switch).controlSize(.small).font(.system(size: 12)).disabled(studio.busy)
                        Picker("Text view", selection: $sourceView) {
                            Text("Listening text").tag(false)
                            Text("Edit source").tag(true)
                        }.pickerStyle(.segmented).tint(R2MTheme.actionAccent).labelsHidden().frame(width: 230).padding(.bottom, 2)
                         .accessibilityLabel("Text view")
                    }
                    ZStack(alignment: .topLeading) {
                        if studio.draft.isPaper && !sourceView {
                            TranscriptView(value: studio.narration)
                        } else {
                        TextEditor(text: Binding(get: { studio.draft.text }, set: { studio.editSource($0) }))
                            .font(.system(size: 16)).lineSpacing(4).scrollContentBackground(.hidden)
                            .padding(12).background(Color(nsColor: .textBackgroundColor))
                            .accessibilityLabel("Reading text").disabled(studio.busy)
                        }
                        if studio.draft.text.isEmpty {
                            Text("Paste text, or import a PDF or link.")
                                .font(.system(size: 16)).foregroundStyle(.secondary).padding(.top, 13).padding(.leading, 17).allowsHitTesting(false)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                     .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
                    HStack {
                        Text(studio.draft.text.isEmpty ? "0 words" : "\((studio.draft.isPaper && !sourceView ? studio.narration : studio.draft.text).split(whereSeparator: { $0.isWhitespace }).count.formatted()) words")
                        Spacer()
                        if studio.busy {
                            if studio.jobProgress == nil { ProgressView().controlSize(.small) }
                            Text(studio.status).lineLimit(1)
                            if let value = studio.jobProgress { Text("\(Int(value * 100))%").monospacedDigit() }
                            Button("Cancel") { studio.cancel() }.controlSize(.small)
                        }
                    }.font(.system(size: 12)).foregroundStyle(.secondary).frame(minHeight: 22)
                    if studio.busy, let value = studio.jobProgress {
                        ProgressView(value: value, total: 1)
                            .tint(accent)
                            .accessibilityLabel("Audio processing progress")
                    }
                }.padding(.horizontal, 24).padding(.top, compact ? 10 : 18).padding(.bottom, compact ? 6 : 12)
                Divider()
                VStack(alignment: .leading, spacing: compact ? 8 : 14) {
                    HStack(alignment: .bottom, spacing: 18) {
                        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                            Text("Voice").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Button { showVoices.toggle() } label: {
                                HStack {
                                    Text(voices.first(where: { $0.1 == voice }).map { "\($0.0) · \($0.2)" } ?? "Choose voice")
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.caption)
                                }.frame(width: 130).frame(minHeight: 18)
                            }
                            .controlSize(compact ? .regular : .large)
                            .accessibilityLabel("Choose voice")
                            .disabled(studio.busy)
                            .popover(isPresented: $showVoices, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Choose a voice").font(.headline).padding(.bottom, 5)
                                    ForEach(voices, id: \.1) { v in
                                        HStack(spacing: 14) {
                                            Button {
                                                voice = v.1
                                                showVoices = false
                                            } label: {
                                                HStack {
                                                    Image(systemName: voice == v.1 ? "checkmark.circle.fill" : "circle")
                                                        .foregroundStyle(voice == v.1 ? accent : Color.secondary)
                                                    Text(v.0).frame(width: 64, alignment: .leading)
                                                    Text(v.2).foregroundStyle(.secondary)
                                                }.padding(.vertical, 5).contentShape(Rectangle())
                                            }.buttonStyle(.bordered).accessibilityLabel("Select " + v.0)
                                            Button { studio.preview(v.1) } label: {
                                                Image(systemName: studio.previewVoice == v.1 ? "stop.fill" : "play.fill")
                                                    .frame(width: 24, height: 20)
                                            }
                                            .accessibilityLabel((studio.previewVoice == v.1 ? "Stop " : "Preview ") + v.0)
                                            .help(studio.previewVoice == v.1 ? "Stop preview" : "Listen to " + v.0)
                                        }
                                    }
                                }.padding(16)
                                 .onDisappear { studio.stopPreview() }
                            }
                        }
                        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                            HStack {
                                Text("Speed").fontWeight(.medium)
                                Spacer()
                                Text(String(format: "%.2f×", speed)).monospacedDigit()
                            }.font(.system(size: 12)).foregroundStyle(.secondary)
                            Slider(value: $speed, in: 0.6...1.5, step: 0.05)
                                .controlSize(.regular).frame(height: compact ? 24 : 32)
                                .accessibilityLabel("Speaking speed")
                                .accessibilityValue(String(format: "%.2f times", speed))
                        }.frame(width: 144).disabled(studio.busy)
                        Spacer()
                        Button { studio.generate(voice: voice, speed: speed) } label: { Label("Generate speech", systemImage: "waveform") }
                            .r2mPrimaryAction().tint(accent).controlSize(compact ? .regular : .large)
                            .disabled(studio.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || studio.busy)
                            .keyboardShortcut(.return, modifiers: [.command])
                    }
                    if studio.hasAudio {
                        Divider()
                        Text("−19 LUFS · −1 dB true-peak ceiling").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { studio.togglePlayback() } label: { Image(systemName: studio.playing ? "pause.fill" : "play.fill") }
                                .controlSize(compact ? .regular : .large)
                                .help(studio.playing ? "Pause playback" : "Play narration")
                                .accessibilityLabel(studio.playing ? "Pause" : "Play")
                            Text(time(studio.playhead)).monospacedDigit().frame(minWidth: 42, alignment: .trailing)
                            Slider(value: Binding(get: { studio.playhead }, set: { studio.seek($0) }), in: 0...max(0.1,studio.duration)).controlSize(.regular).accessibilityLabel("Playback position")
                            Text(time(studio.duration)).monospacedDigit().frame(minWidth: 42, alignment: .leading)
                            Button { studio.saveAudio() } label: { Label("Export MP3", systemImage: "square.and.arrow.down") }
                                .controlSize(compact ? .regular : .large).fixedSize().disabled(studio.busy)
                        }.font(.subheadline)
                    }
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        if let folder = studio.exportFolder {
                            Text(folder).lineLimit(1).truncationMode(.middle).help(folder).textSelection(.enabled)
                        } else {
                            Text("Choose a folder for MP3 exports").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(studio.exportFolder == nil ? "Choose folder…" : "Change folder…") { studio.chooseExportFolder() }
                            .disabled(studio.busy)
                    }.font(.system(size: 12))
                    if let saved = studio.exportedURL {
                        HStack {
                            Label("Exported " + saved.lastPathComponent, systemImage: "checkmark.circle").lineLimit(1)
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 24).padding(.vertical, compact ? 10 : 16)
                 .r2mControlSurface()
            }
            .r2mAppearance()
        }
        .frame(minWidth: 660, minHeight: 490)
        .onAppear {
            if studio.draft.isPaper && studio.draft.plan == nil && !studio.draft.text.isEmpty { studio.prepare() }
        }
        .sheet(isPresented: $review) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Listening changes").font(.system(size: 20, weight: .semibold))
                Text("Checked changes apply to speech. Uncheck a change to hear the original.").foregroundStyle(.secondary)
                List(studio.changes) { entry in
                    Toggle(isOn: Binding(get: { !(studio.draft.restored ?? []).contains(entry.id) }, set: { studio.changeEnabled(entry.id, $0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.reason).font(.subheadline.bold())
                            Text(entry.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        }
                    }.toggleStyle(.checkbox)
                     .disabled(entry.group == "references" ? !studio.skipReferences : !studio.cleanup)
                }
                HStack { Spacer(); Button("Done") { review = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).r2mAppearance().frame(minWidth: 560, idealWidth: 650, minHeight: 420, idealHeight: 520)
        }
        .sheet(isPresented: $showLink) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import a website").font(.system(size: 20, weight: .semibold))
                TextField("https://example.com/article", text: $link).textFieldStyle(.roundedBorder).focused($focusLink)
                HStack {
                    Spacer()
                    Button("Cancel") { showLink = false }.keyboardShortcut(.cancelAction)
                    Button("Import") { showLink = false; studio.importLink(link) }
                        .r2mPrimaryAction().keyboardShortcut(.defaultAction).disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).r2mAppearance().frame(width: 445).onAppear { focusLink = true }
        }
        .alert("R2M", isPresented: Binding(get: { studio.problem != nil }, set: { if !$0 { studio.problem = nil } })) {
            Button("OK") { studio.problem = nil }
        } message: { Text(studio.problem ?? "") }
        .onChange(of: studio.draft.text) {
            draftSave?.cancel()
            let action = DispatchWorkItem { studio.saveDraft() }
            draftSave = action
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: action)
        }
        .onOpenURL { url in studio.importPDF(url) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in studio.shutdown() }
    }
}
struct TranscriptView: NSViewRepresentable {
    let value: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroller = NSTextView.scrollableTextView()
        let text = scroller.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 16)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.setAccessibilityLabel("Listening text")
        return scroller
    }
    func updateNSView(_ scroller: NSScrollView, context: Context) {
        if let text = scroller.documentView as? NSTextView, text.string != value { text.string = value }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct R2MDesktop: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var studio = Studio()
    @StateObject private var chat = PaperChat()
    var body: some Scene {
        Window("R2M", id: "studio") { ReaderView(studio: studio) }
            .defaultSize(width: 850, height: 660)
            .windowResizability(.contentMinSize)
        Window("Chat with this paper", id: "paper-chat") { PaperChatView(chat: chat, studio: studio) }
            .defaultSize(width: 680, height: 740)
            .windowResizability(.contentMinSize)
    }
}

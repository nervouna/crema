import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    let store: MeetingStore
    let audio = AudioController()
    let transcription = TranscriptionService()
    let intelligence = LocalIntelligence()
    var selection: UUID?
    var activeMeetingID: UUID?
    var recordingID: UUID?
    var activity = ""
    var progress: Double?
    var error: String?
    var speechStatus = "正在检查本地语音模型"
    var modelStatus = "模型按需载入"
    var task: Task<Void, Never>?
    var modelPath: String {
        didSet { UserDefaults.standard.set(modelPath, forKey: "modelPath") }
    }
    var speechModelPath: String {
        didSet { UserDefaults.standard.set(speechModelPath, forKey: "speechModelPath") }
    }
    var vocabulary: String {
        didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    }

    init() {
        let testRoot = ProcessInfo.processInfo.environment["CREMA_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        store = MeetingStore(root: testRoot)
        modelPath = UserDefaults.standard.string(forKey: "modelPath")
            ?? Bundle.main.object(forInfoDictionaryKey: "CremaDefaultModelPath") as? String ?? ""
        speechModelPath = UserDefaults.standard.string(forKey: "speechModelPath")
            ?? Bundle.main.object(forInfoDictionaryKey: "CremaDefaultSpeechModelPath") as? String ?? ""
        vocabulary = UserDefaults.standard.string(forKey: "vocabulary") ?? "Crema, SwiftUI, AppKit, API, macOS, iOS, GitHub, MLX, Qwen"
        selection = store.meetings.first?.id
    }

    var isBusy: Bool { task != nil }
    var selected: Meeting? { store.meeting(selection) }
    var terms: [String] { vocabulary.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    func startRecording() {
        guard !isBusy, !audio.isRecording else { return }
        audio.stopPlayback()
        var meeting = Meeting(title: "会议 \(Date().formatted(.dateTime.month().day().hour().minute()))", audioFilename: "recording.m4a")
        meeting.createdAt = Date()
        task = Task {
            defer { task = nil }
            do {
                try store.save(meeting)
                selection = meeting.id
                try await audio.startRecording(at: store.audioURL(for: meeting))
                recordingID = meeting.id
            } catch { self.error = error.localizedDescription }
        }
    }

    func stopRecording() {
        guard let id = recordingID else { return }
        let duration = audio.stopRecording()
        store.update(id) { $0.duration = duration }
        recordingID = nil
        process(id)
    }

    func importAudio() {
        guard !isBusy, !audio.isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "导入会议录音"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        task = Task {
            do {
                let asset = AVURLAsset(url: source)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw CremaError("无法读取音频时长：\(source.path)") }
                var meeting = Meeting(title: source.deletingPathExtension().lastPathComponent,
                                      audioFilename: "audio.\(source.pathExtension)")
                meeting.duration = duration
                let directory = store.folder(for: meeting.id)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: store.audioURL(for: meeting))
                try store.save(meeting)
                selection = meeting.id
                task = nil
                process(meeting.id)
            } catch {
                task = nil
                self.error = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    func process(_ id: UUID, onlyMinutes: Bool = false) {
        guard !isBusy, !audio.isRecording, let meeting = store.meeting(id) else { return }
        activeMeetingID = id
        task = Task {
            defer { task = nil; activity = ""; progress = nil; activeMeetingID = nil }
            do {
                var current = meeting
                if !onlyMinutes && current.transcript.isEmpty {
                    activity = "正在本机转写，首次载入可能稍慢"
                    progress = 0
                    await intelligence.unload()
                    modelStatus = "模型按需载入"
                    let segments = try await transcription.transcribe(url: store.audioURL(for: current), modelPath: speechModelPath, vocabulary: terms) { value in
                        await MainActor.run { self.progress = value; self.activity = "正在本机转写" }
                    }
                    current.transcript = segments
                    current.transcriptionModel = "Qwen3-ASR 1.7B"
                    try store.save(current)
                }
                try Task.checkCancellation()
                progress = nil
                activity = "正在载入本地语言模型"
                try await intelligence.load(path: modelPath)
                modelStatus = "Qwen3.5 4B 已载入"
                if current.transcriptionModel == nil && current.transcript.allSatisfy({ $0.originalText == nil }) {
                    current.transcript = try await intelligence.restorePunctuation(current.transcript) { status in
                        await MainActor.run { self.activity = status }
                    }
                    try store.save(current)
                }
                let minutes = try await intelligence.summarize(current.transcript) { status in
                    await MainActor.run { self.activity = status }
                }
                try Task.checkCancellation()
                current.minutes = minutes
                current.minutesNeedUpdate = false
                try store.save(current)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    func retranscribe(_ meeting: Meeting) {
        guard !isBusy, !audio.isRecording else { return }
        do {
            audio.stopPlayback()
            let copy = try store.copyForRetranscription(meeting)
            selection = copy.id
            process(copy.id)
        } catch { self.error = "无法重新转写：\(error.localizedDescription)" }
    }

    func ask(_ question: String, meeting: Meeting) {
        guard !isBusy, !audio.isRecording else { return }
        activeMeetingID = meeting.id
        task = Task {
            defer { task = nil; activity = ""; activeMeetingID = nil }
            do {
                activity = "正在载入本地语言模型"
                try await intelligence.load(path: modelPath)
                let result = try await intelligence.answer(question, meeting: meeting) { status in
                    await MainActor.run { self.activity = status }
                }
                try Task.checkCancellation()
                var current = store.meeting(meeting.id) ?? meeting
                current.questions.append(result)
                try store.save(current)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    func play(_ meeting: Meeting, at time: TimeInterval? = nil) {
        do { try audio.togglePlayback(url: store.audioURL(for: meeting), at: time) }
        catch { self.error = "无法回放 \(meeting.audioFilename)：\(error.localizedDescription)" }
    }

    func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Qwen 本地模型目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelPath = url.path
        modelStatus = "模型按需载入"
    }

    func chooseSpeechModel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Qwen3-ASR 本地语音模型目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        speechModelPath = url.path
        Task { speechStatus = await transcription.readiness(path: speechModelPath) }
    }

    func export(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "# \(meeting.title)\n\n\(meeting.minutes)\n\n---\n\n## 转写原文\n\n\(meeting.transcriptText)\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "无法导出到 \(url.path)：\(error.localizedDescription)" }
    }
}

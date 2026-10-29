import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var search = ""

    private var visibleMeetings: [Meeting] {
        model.store.meetings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.minutes.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("会议") {
                    ForEach(visibleMeetings) { meeting in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(meeting.title).font(.headline).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
                                Spacer()
                                if model.recordingID == meeting.id { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
                                else { Text(clockText(meeting.duration)).monospacedDigit() }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if meeting.transcript.isEmpty && model.recordingID != meeting.id {
                                Text("待转写").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(meeting.id)
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索会议")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Label("全部保存在本机", systemImage: "internaldrive")
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("设置")
                }
                .font(.caption).foregroundStyle(.secondary).padding(14)
            }
            .frame(minWidth: 240)
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if model.audio.isRecording { recordingBar }
                if model.isBusy && !model.activity.isEmpty { activityBar }
                if let meeting = model.selected {
                    MeetingDetail(model: model, meeting: meeting).id(meeting.id)
                } else {
                    ContentUnavailableView {
                        Label("让每次讨论留下清晰记录", systemImage: "waveform")
                    } description: {
                        Text("录制一场会议，结束后在本机生成转写和纪要。")
                    } actions: {
                        Button("开始录音", systemImage: "mic", action: model.startRecording)
                            .buttonStyle(.borderedProminent)
                        Button("导入录音…", action: model.importAudio)
                    }
                    .disabled(model.isBusy || model.audio.isRecording)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("导入录音", systemImage: "square.and.arrow.down", action: model.importAudio)
                    .disabled(model.isBusy || model.audio.isRecording)
                Button("新建录音", systemImage: "mic.badge.plus", action: model.startRecording)
                    .disabled(model.isBusy || model.audio.isRecording)
            }
        }
        .onChange(of: model.selection) { model.audio.stopPlayback() }
        .onAppear { if let error = model.store.error { model.error = error; model.store.error = nil } }
        .onChange(of: model.store.error) { _, error in if let error { model.error = error; model.store.error = nil } }
        .onChange(of: model.audio.error) { _, error in
            if let error {
                if let id = model.recordingID, !model.audio.isRecording {
                    model.store.update(id) { $0.duration = model.audio.elapsed }
                    model.recordingID = nil
                }
                model.error = error
                model.audio.error = nil
            }
        }
        .alert("需要处理", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var recordingBar: some View {
        HStack(spacing: 16) {
            Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.audio.isPaused ? "录音已暂停" : "正在录音").font(.headline)
                Text(clockText(model.audio.elapsed)).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: Double(model.audio.level)).frame(maxWidth: 140).accessibilityLabel("麦克风音量")
            Spacer()
            Button(model.audio.isPaused ? "继续" : "暂停", systemImage: model.audio.isPaused ? "play.fill" : "pause.fill", action: model.audio.togglePause)
            Button("结束并整理", systemImage: "stop.fill", action: model.stopRecording).buttonStyle(.borderedProminent)
        }
        .padding().background(.bar)
    }

    private var activityBar: some View {
        HStack(spacing: 12) {
            if let progress = model.progress { ProgressView(value: progress).frame(width: 100) }
            else { ProgressView().controlSize(.small) }
            Text(model.activity).font(.callout)
            if let id = model.activeMeetingID, id != model.selection {
                Button("查看会议") { model.selection = id }
            }
            Spacer()
            Button("取消") { model.task?.cancel() }
        }
        .padding(12).background(.bar)
    }
}

private enum MeetingTab: String, CaseIterable {
    case minutes = "会议纪要"
    case transcript = "转写原文"
    case questions = "问答"
}

private struct MeetingDetail: View {
    @Bindable var model: AppModel
    let meeting: Meeting
    @State private var tab: MeetingTab = .minutes
    @State private var title = ""
    @State private var question = ""
    @State private var editText = ""
    @State private var editingSegmentID: UUID?
    @State private var showingEditor = false
    @State private var highlightedSegment: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("会议名称", text: $title)
                    .font(.title2.bold()).textFieldStyle(.plain)
                    .onChange(of: title) { _, value in
                        if value != meeting.title, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                            model.store.update(meeting.id) { $0.title = value }
                        }
                    }
                    .disabled(model.isBusy)
                HStack(spacing: 12) {
                    Text(meeting.createdAt, format: .dateTime.year().month().day().hour().minute())
                    Text(clockText(meeting.duration)).monospacedDigit()
                    Spacer()
                    if !meeting.transcript.isEmpty {
                        Button("重新转写", systemImage: "arrow.clockwise") { model.retranscribe(meeting) }
                            .buttonStyle(.borderless).disabled(model.isBusy || model.audio.isRecording)
                            .help("保留当前会议，创建一份新的转写和纪要")
                        Button("导出", systemImage: "square.and.arrow.up") { model.export(meeting) }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                if model.recordingID != meeting.id { player }
                Picker("会议内容", selection: $tab) {
                    ForEach(MeetingTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 400)
            }.padding(24)
            Divider()
            switch tab {
            case .minutes: minutesView
            case .transcript: transcriptView
            case .questions: questionsView
            }
        }
        .onAppear { title = meeting.title }
        .sheet(isPresented: $showingEditor) { editor }
    }

    private var player: some View {
        HStack(spacing: 12) {
            Button(model.audio.isPlaying ? "暂停回放" : "播放录音", systemImage: model.audio.isPlaying ? "pause.fill" : "play.fill") { model.play(meeting) }
                .labelStyle(.iconOnly).controlSize(.large).disabled(model.audio.isRecording || meeting.duration == 0)
            Slider(value: Binding(get: { model.audio.playbackTime }, set: { model.audio.seek($0) }),
                   in: 0...max(1, model.audio.playbackDuration))
                .disabled(model.audio.playbackDuration == 0).accessibilityLabel("播放进度")
            Text(clockText(model.audio.playbackTime)).monospacedDigit().font(.caption)
        }
    }

    @ViewBuilder private var minutesView: some View {
        if meeting.minutes.isEmpty {
            ContentUnavailableView {
                Label(model.recordingID == meeting.id ? "录音结束后开始整理" : "还没有会议纪要", systemImage: "doc.text")
            } description: {
                Text(meeting.transcript.isEmpty ? "音频会先转成文字，再由本地模型整理纪要。" : "转写已保存，可以生成会议纪要。")
            } actions: {
                Button(meeting.transcript.isEmpty ? "转写并生成纪要" : "生成纪要") { model.process(meeting.id) }
                    .disabled(model.isBusy || model.audio.isRecording || meeting.duration == 0)
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    if meeting.minutesNeedUpdate { Label("原文已修改，建议重新整理", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("重新生成") { model.process(meeting.id, onlyMinutes: true) }
                    Button("编辑") { editText = meeting.minutes; editingSegmentID = nil; showingEditor = true }
                }.disabled(model.isBusy || model.audio.isRecording).padding(.horizontal, 24).padding(.top, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(meeting.minutes.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            if line.hasPrefix("#") {
                                Text(line.drop(while: { $0 == "#" || $0 == " " })).font(.headline).padding(.top, 10)
                            } else if !line.isEmpty {
                                Text(.init(line)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            }
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            List {
                if let transcriptionModel = meeting.transcriptionModel {
                    Text("\(transcriptionModel)，时间定位到音频片段起点")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if meeting.transcript.isEmpty { Text("录音转写完成后，原文会显示在这里。").foregroundStyle(.secondary) }
                ForEach(Array(meeting.transcript.enumerated()), id: \.element.id) { index, segment in
                    HStack(alignment: .top, spacing: 14) {
                        Button(clockText(segment.start)) { model.play(meeting, at: segment.start) }
                            .buttonStyle(.borderless).monospacedDigit().font(.caption)
                            .disabled(model.audio.isRecording).help("回放这一段")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(segment.text).textSelection(.enabled).lineSpacing(4)
                            Text("原文 [\(index + 1)]").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Button("修改文字", systemImage: "pencil") { editText = segment.text; editingSegmentID = segment.id; showingEditor = true }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.isBusy)
                    }
                    .padding(.vertical, 10)
                    .listRowBackground(highlightedSegment == segment.id ? Color.accentColor.opacity(0.1) : Color.clear)
                    .id(segment.id)
                }
            }
            .listStyle(.inset)
            .onAppear { if let highlightedSegment { proxy.scrollTo(highlightedSegment, anchor: .center) } }
        }
    }

    private var questionsView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if meeting.questions.isEmpty {
                            ContentUnavailableView("问问这场会议", systemImage: "text.bubble", description: Text("例如：最后决定采用什么方案？有哪些待办？\n回答会附上可回听的原文依据。"))
                        }
                        ForEach(meeting.questions) { item in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.question).font(.headline)
                                Text(.init(item.answer)).textSelection(.enabled).lineSpacing(5)
                                if !item.sourceIDs.isEmpty {
                                    ScrollView(.horizontal) {
                                        HStack {
                                            ForEach(item.sourceIDs, id: \.self) { id in
                                                if let index = meeting.transcript.firstIndex(where: { $0.id == id }) {
                                                    Button("原文 [\(index + 1)]  \(clockText(meeting.transcript[index].start))") {
                                                        highlightedSegment = id
                                                        tab = .transcript
                                                        model.play(meeting, at: meeting.transcript[index].start)
                                                    }.controlSize(.small)
                                                }
                                            }
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).id(item.id)
                            Divider()
                        }
                    }.padding(24)
                }
                .onChange(of: meeting.questions.count) { if let last = meeting.questions.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("围绕本次会议提问", text: $question, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.roundedBorder).onSubmit(submitQuestion)
                Button("提问", systemImage: "arrow.up", action: submitQuestion)
                    .buttonStyle(.borderedProminent)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(model.isBusy || model.audio.isRecording || meeting.transcript.isEmpty).padding(20)
        }
    }

    private func submitQuestion() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isBusy else { return }
        model.ask(question, meeting: meeting)
        question = ""
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingSegmentID == nil ? "编辑会议纪要" : "纠正转写文字").font(.headline)
            TextEditor(text: $editText).font(.body).border(.separator)
            HStack {
                Spacer()
                Button("取消") { showingEditor = false }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    model.store.update(meeting.id) { current in
                        if let id = editingSegmentID, let index = current.transcript.firstIndex(where: { $0.id == id }) {
                            current.transcript[index].text = editText
                            current.minutesNeedUpdate = !current.minutes.isEmpty
                        } else { current.minutes = editText }
                    }
                    showingEditor = false
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640, height: 460)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("离线语音") {
                LabeledContent("语音模型", value: "Qwen3-ASR 1.7B，8-bit")
                Text(model.speechModelPath).font(.caption).textSelection(.enabled)
                HStack {
                    Text(model.speechStatus).foregroundStyle(.secondary)
                    Spacer()
                    Button("选择模型目录…", action: model.chooseSpeechModel)
                        .disabled(model.isBusy || model.audio.isRecording)
                }
                Text("转写直接使用本地语音模型，会议录音不会上传。").font(.caption).foregroundStyle(.secondary)
            }
            Section("纪要与问答") {
                LabeledContent("语言模型", value: "Qwen3.5 4B，4-bit")
                Text(model.modelPath).font(.caption).textSelection(.enabled)
                HStack {
                    Text(model.modelStatus).foregroundStyle(.secondary)
                    Spacer()
                    Button("选择模型目录…", action: model.chooseModel).disabled(model.isBusy)
                }
            }
            Section("常用术语") {
                TextField("用逗号分隔产品名、项目名和英文缩写", text: $model.vocabulary, axis: .vertical).lineLimit(3...5)
                Text("为中文转写提供术语提示，仍可在原文中手动纠正。").font(.caption).foregroundStyle(.secondary)
            }
            Section("本地文件") {
                Text(model.store.root.path).font(.caption).textSelection(.enabled)
                Button("在 Finder 中打开") { NSWorkspace.shared.open(model.store.root) }
            }
        }
        .formStyle(.grouped).frame(width: 570, height: 600)
        .task { model.speechStatus = await model.transcription.readiness(path: model.speechModelPath) }
    }
}

import AppKit
import AVFoundation
import Foundation

@MainActor
enum SmokeTests {
    private static var hasRun = false

    static func run(model: AppModel) async {
        guard !hasRun else { return }
        hasRun = true
        setbuf(stdout, nil)
        do {
            try checkCore()
            try checkStereoAudio()
            print("PASS: local persistence, long transcript chunking, citation bounds")
            var meeting = Meeting(title: "Offline smoke test", audioFilename: "test.aiff")
            if let position = CommandLine.arguments.firstIndex(of: "--audio"), CommandLine.arguments.indices.contains(position + 1) {
                let source = URL(fileURLWithPath: CommandLine.arguments[position + 1])
                let asset = AVURLAsset(url: source)
                meeting.duration = try await asset.load(.duration).seconds
                let transcriptionStart = ContinuousClock.now
                var chunkSeconds: Float = 60
                if let index = CommandLine.arguments.firstIndex(of: "--asr-chunk-seconds"), CommandLine.arguments.indices.contains(index + 1) {
                    chunkSeconds = Float(CommandLine.arguments[index + 1]) ?? 60
                }
                meeting.transcript = try await model.transcription.transcribe(url: source, modelPath: model.speechModelPath,
                    vocabulary: model.terms, chunkSeconds: chunkSeconds) { print("ASR_PROGRESS: \($0)") }
                meeting.transcriptionModel = "Qwen3-ASR 1.7B"
                print("TRANSCRIPTION_DURATION: \(transcriptionStart.duration(to: .now))")
                print("TRANSCRIPT:\n\(meeting.transcriptText)")
                guard meeting.transcriptText.contains("会议") else { throw CremaError("Chinese transcription smoke test did not recognize 会议.") }
                try FileManager.default.createDirectory(at: model.store.folder(for: meeting.id), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: model.store.audioURL(for: meeting))
                try model.store.save(meeting)
                print("PASS: Chinese audio transcription and import")
            } else {
                meeting.transcript = [
                    TranscriptSegment(start: 0, end: 8, text: "今天讨论 Crema 的第一个版本。界面使用 SwiftUI，录音结束后再转写。"),
                    TranscriptSegment(start: 8, end: 16, text: "所有会议内容只在本机处理，不接入云服务。决定先支持中文会议和英文技术名词。"),
                    TranscriptSegment(start: 16, end: 24, text: "小王负责录音功能，本周五之前完成。预算暂时没有确定，下一次会议再讨论。")
                ]
            }
            if CommandLine.arguments.contains("--test-ai") {
                let clock = ContinuousClock()
                let start = clock.now
                try await model.intelligence.load(path: model.modelPath)
                print("MODEL_LOAD: \(start.duration(to: clock.now))")
                if meeting.transcriptionModel == nil {
                    meeting.transcript = try await model.intelligence.restorePunctuation(meeting.transcript) { print($0) }
                }
                print("PUNCTUATED:\n\(meeting.transcriptText)")
                let summaryStart = clock.now
                meeting.minutes = try await model.intelligence.summarize(meeting.transcript) { print($0) }
                print("MINUTES:\n\(meeting.minutes)")
                print("SUMMARY_DURATION: \(summaryStart.duration(to: clock.now))")
                let actionSection = meeting.minutes.components(separatedBy: "待办事项").last?.components(separatedBy: "#").first ?? ""
                guard actionSection.contains("录音"), actionSection.contains("王"), actionSection.contains("周五"),
                      !actionSection.contains("预算") else {
                    throw CremaError("Minutes did not keep the recording task, its owner and deadline together.")
                }
                let answer = try await model.intelligence.answer("谁负责录音功能，什么时候完成？", meeting: meeting) { print($0) }
                print("ANSWER:\n\(answer.answer)")
                guard !answer.sourceIDs.isEmpty, answer.answer.contains("王"), answer.answer.contains("周五"),
                      !answer.answer.contains("预算"), !answer.answer.contains("未明确"), !answer.answer.contains("未在") else {
                    throw CremaError("Action-item answer did not preserve the owner, deadline and source reference.")
                }
                meeting.questions.append(answer)
                let unknown = try await model.intelligence.answer("这次会议决定了多少元的预算？", meeting: meeting) { print($0) }
                print("UNKNOWN_ANSWER:\n\(unknown.answer)")
                guard !unknown.answer.contains("1000"), !unknown.answer.contains("5000"),
                      unknown.answer.contains("未") || unknown.answer.contains("没有") else {
                    throw CremaError("The unknown-budget answer was not evidence bounded.")
                }
                meeting.questions.append(unknown)
                try model.store.save(meeting)
                print("PASS: offline minutes, cited action-item answer, unknown-budget answer")
                var unclear = Meeting(title: "Unclear speech regression", audioFilename: "unused.caf")
                unclear.transcript = [TranscriptSegment(start: 0, end: 8, text: "界面尽量使用原生控件，尽量使用单侧也能。")]
                let unclearMinutes = try await model.intelligence.summarize(unclear.transcript) { _ in }
                print("UNCLEAR_SPEECH_MINUTES:\n\(unclearMinutes)")
                guard unclearMinutes.contains("原生控件"), unclearMinutes.contains("单侧也能"),
                      unclearMinutes.contains("待核对"), !unclearMinutes.contains("[ASR_UNCLEAR]"),
                      !unclearMinutes.contains("单手"), !unclearMinutes.contains("单侧显示"), !unclearMinutes.contains("单侧模式") else {
                    throw CremaError("Minutes invented a feature from unintelligible speech.")
                }
                let unclearAnswer = try await model.intelligence.answer("会议是否决定支持单手操作？", meeting: unclear) { _ in }
                print("UNCLEAR_SPEECH_ANSWER:\n\(unclearAnswer.answer)")
                guard unclearAnswer.answer.contains("未") || unclearAnswer.answer.contains("没有") || unclearAnswer.answer.contains("无法") else {
                    throw CremaError("The answer treated unclear speech as a confirmed requirement.")
                }
                print("PASS: unclear speech is not turned into an invented feature")
            }
            print("ALL CHECKS PASSED")
            fflush(stdout)
            exit(0)
        } catch {
            print("FAILED: \(error)")
            fflush(stdout)
            exit(1)
        }
    }

    static func checkCore() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CremaChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var meeting = Meeting(title: "中文 persistence", audioFilename: "recording.m4a")
        meeting.transcript = (0..<70).map {
            TranscriptSegment(start: Double($0 * 5), end: Double($0 * 5 + 5), text: "原文\($0) " + String(repeating: "SwiftUI技术讨论", count: 100))
        }
        try store.save(meeting)
        let reopened = MeetingStore(root: root)
        guard reopened.meetings.count == 1, reopened.meetings[0].transcript == meeting.transcript else {
            throw CremaError("Meeting persistence round trip failed at \(root.path)")
        }
        let recording = Data("Recording fixture".utf8)
        try recording.write(to: store.audioURL(for: meeting))
        let originalJSON = try Data(contentsOf: store.folder(for: meeting.id).appending(path: "meeting.json"))
        let copy = try store.copyForRetranscription(meeting)
        let preservedJSON = try Data(contentsOf: store.folder(for: meeting.id).appending(path: "meeting.json"))
        guard copy.id != meeting.id, copy.transcript.isEmpty, copy.minutes.isEmpty, copy.questions.isEmpty,
              try Data(contentsOf: store.audioURL(for: copy)) == recording, originalJSON == preservedJSON else {
            throw CremaError("Retranscription copy changed the original meeting or carried stale generated content.")
        }
        let chunks = transcriptChunks(meeting.transcript, limit: 250)
        // Split points may bisect a term, so compare content after removing generated labels.
        let cleaned = chunks.joined().replacingOccurrences(of: #"\[\d+\] \[[\d:]+\] |\n"#, with: "", options: .regularExpression)
        guard chunks.allSatisfy({ $0.count <= 250 }), cleaned == meeting.transcript.map(\.text).joined() else {
            throw CremaError("Transcript chunking lost meeting content or exceeded its size limit.")
        }
        try checkCitations(meeting)
        let punctuationInput = [TranscriptSegment(start: 0, end: 2, text: "小王周五完成"), TranscriptSegment(start: 2, end: 4, text: "预算未定")]
        guard let punctuated = applyingPunctuation("小王周五完成。预算未定。", to: punctuationInput),
              punctuated[0].text == "小王周五完成。", punctuated[1].text == "预算未定。",
              applyingPunctuation("小李周五完成。预算未定。", to: punctuationInput) == nil else {
            throw CremaError("Punctuation restoration changed a word or assigned it to the wrong segment.")
        }
    }

    private static func checkCitations(_ meeting: Meeting) throws {
        guard resolvedSourceIDs([1, 70, 1], from: meeting.transcript) == [meeting.transcript[0].id, meeting.transcript[69].id],
              resolvedSourceIDs([999], from: meeting.transcript) == nil,
              resolvedSourceIDs([0], from: meeting.transcript) == nil,
              resolvedSourceIDs([Int.min], from: meeting.transcript) == nil else {
            throw CremaError("Citation bounds check failed.")
        }
    }

    private static func checkStereoAudio() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "CremaStereo-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 {
            buffer.floatChannelData![0][index] = 0
            buffer.floatChannelData![1][index] = 0.5 * sin(2 * .pi * 440 * Float(index) / 48_000)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let samples = try speechSamples(from: url)
        let peak = samples.map { abs($0) }.max() ?? 0
        guard abs(samples.count - 16_000) <= 1, peak > 0.1 else {
            throw CremaError("Stereo conversion failed: \(samples.count) samples (expected 16000), right-channel peak \(peak) (expected > 0.1).")
        }
        print("PASS: stereo downmix and 48 kHz to 16 kHz conversion")
    }
}

import Foundation
import AVFoundation
import MLX
import MLXAudioCore
import MLXAudioSTT

actor TranscriptionService {
    private static let requiredFiles = ["config.json", "model.safetensors", "vocab.json", "merges.txt", "tokenizer_config.json"]

    func readiness(path: String) -> String {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        return Self.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
            ? "本地语音模型已就绪" : "请选择完整的语音模型目录"
    }

    func transcribe(url: URL, modelPath: String, vocabulary: [String], chunkSeconds: Float = 60,
                    onProgress: @escaping @Sendable (Double) async -> Void) async throws -> [TranscriptSegment] {
        let directory = URL(fileURLWithPath: modelPath, isDirectory: true)
        for name in Self.requiredFiles {
            let file = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw CremaError("找不到本地语音模型文件：\(file.path)")
            }
        }
        guard chunkSeconds.isFinite, chunkSeconds >= 5 else { throw CremaError("无效的转写分段时长：\(chunkSeconds)") }
        try Task.checkCancellation()
        let sampleRate = 16_000
        let samples = try speechSamples(from: url)
        guard samples.contains(where: { abs($0) > 0.0001 }) else {
            throw CremaError("录音中没有可识别的声音，请检查麦克风：\(url.lastPathComponent)")
        }
        let audio = MLXArray(samples)
        // Load only local files. Never invoke the library's Hub download helper.
        let model = try await Qwen3ASRModel.fromModelDirectory(directory)
        let duration = Double(audio.size) / Double(sampleRate)
        let chunks = splitAudioIntoChunks(audio, sampleRate: sampleRate, chunkDuration: chunkSeconds)
        var segments: [TranscriptSegment] = []
        for (chunk, offset) in chunks {
            try Task.checkCancellation()
            let end = min(duration, Double(offset) + Double(chunk.size) / Double(sampleRate))
            if MLX.abs(chunk).max().item(Float.self) <= 0.0001 {
                await onProgress(min(1, end / duration))
                continue
            }
            let result = model.generate(audio: chunk, maxTokens: 1536, temperature: 0,
                                        context: vocabulary.joined(separator: ", "), language: "Chinese")
            try Task.checkCancellation()
            guard result.generationTokens < 1536 else {
                throw CremaError("\(clockText(Double(offset))) 附近的转写超过输出上限，未保存不完整结果。请截取该段音频后重试。")
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(start: Double(offset), end: end, text: text))
            }
            await onProgress(min(1, end / duration))
        }
        guard !segments.isEmpty else { throw CremaError("这段录音没有识别出语音，请回放检查：\(url.lastPathComponent)") }
        return segments
    }
}

/// Downmix all channels and resample incrementally, keeping only 16 kHz mono samples in memory.
func speechSamples(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: file.processingFormat, to: format),
          let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536),
          let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else {
        throw CremaError("无法转换为 16 kHz 单声道音频：\(url.path)")
    }
    converter.downmix = true
    var samples: [Float] = []
    while true {
        try Task.checkCancellation()
        var conversionError: NSError?
        var readError: Error?
        let status = converter.convert(to: output, error: &conversionError) { requested, state in
            guard file.framePosition < file.length else { state.pointee = .endOfStream; return nil }
            do {
                try file.read(into: input, frameCount: min(requested, input.frameCapacity))
                state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                return input.frameLength > 0 ? input : nil
            } catch {
                readError = error
                state.pointee = .endOfStream
                return nil
            }
        }
        if let error = readError ?? conversionError { throw CremaError("无法读取录音 \(url.path)：\(error.localizedDescription)") }
        guard status != .error else { throw CremaError("音频采样率转换失败：\(url.path)") }
        if let data = output.floatChannelData?[0], output.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        }
        if status == .endOfStream { break }
    }
    return samples
}

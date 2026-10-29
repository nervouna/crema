import AVFoundation
import Observation

@MainActor @Observable
final class AudioController: NSObject, AVAudioRecorderDelegate {
    var isRecording = false
    var isPaused = false
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var isPlaying = false
    var playbackTime: TimeInterval = 0
    var playbackDuration: TimeInterval = 0
    var error: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var playerURL: URL?

    override init() {
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func startRecording(at url: URL) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let authorized: Bool
        if status == .notDetermined { authorized = await requestMicrophone() }
        else { authorized = status == .authorized }
        guard authorized else { throw CremaError("麦克风未获授权。请在系统设置的「隐私与安全性 → 麦克风」中允许 Crema。") }
        stopPlayback()
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw CremaError("无法开始录音：\(url.path)") }
        self.recorder = recorder
        elapsed = 0
        isPaused = false
        isRecording = true
    }

    private func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func togglePause() {
        guard let recorder else { return }
        if isPaused {
            guard recorder.record() else { error = "无法继续录音。请结束并保留当前录音。"; return }
        } else { recorder.pause() }
        isPaused.toggle()
    }

    @discardableResult func stopRecording() -> TimeInterval {
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        isRecording = false
        isPaused = false
        level = 0
        elapsed = duration
        return duration
    }

    func togglePlayback(url: URL, at time: TimeInterval? = nil) throws {
        guard !isRecording else { return }
        if playerURL != url {
            player = try AVAudioPlayer(contentsOf: url)
            playerURL = url
            playbackDuration = player?.duration ?? 0
        }
        if let time {
            player?.currentTime = min(max(0, time), playbackDuration)
            player?.play()
        } else if player?.isPlaying == true { player?.pause() }
        else { player?.play() }
        tick()
    }

    func seek(_ time: TimeInterval) { player?.currentTime = time; playbackTime = time }
    func stopPlayback() { player?.stop(); player = nil; playerURL = nil; isPlaying = false; playbackTime = 0; playbackDuration = 0 }

    private func tick() {
        if let recorder, !isPaused {
            elapsed = recorder.currentTime
            recorder.updateMeters()
            level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 60) / 60))
        }
        isPlaying = player?.isPlaying ?? false
        playbackTime = player?.currentTime ?? 0
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let message = error?.localizedDescription ?? "音频编码失败"
        Task { @MainActor in self.error = message; _ = self.stopRecording() }
    }
}

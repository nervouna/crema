import AppKit
import SwiftUI

@main
enum CremaLauncher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Task { await SmokeTests.run(model: AppModel()) }
            RunLoop.main.run()
        } else {
            CremaApp.main()
        }
    }
}

struct CremaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Crema") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 600)
                .onAppear { delegate.model = model }
                .task {
                    model.speechStatus = await model.transcription.readiness(path: model.speechModelPath)
                }
        }
        .defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建录音", action: model.startRecording)
                    .keyboardShortcut("n").disabled(model.isBusy || model.audio.isRecording)
                Button("导入录音…", action: model.importAudio)
                    .keyboardShortcut("o").disabled(model.isBusy || model.audio.isRecording)
            }
        }
        Settings { SettingsView(model: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.audio.isRecording {
            let alert = NSAlert()
            alert.messageText = "结束录音并退出？"
            alert.informativeText = "当前录音将保存在本机，下次打开后可以继续转写。"
            alert.addButton(withTitle: "保存并退出")
            alert.addButton(withTitle: "继续录音")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            if let id = model.recordingID {
                let duration = model.audio.stopRecording()
                model.store.update(id) { $0.duration = duration }
            }
        }
        model.task?.cancel()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

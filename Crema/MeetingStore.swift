import Foundation
import Observation

@MainActor @Observable
final class MeetingStore {
    var meetings: [Meeting] = []
    var error: String?
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Crema/Meetings", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)
            for folder in folders {
                let file = folder.appending(path: "meeting.json")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                do {
                    let meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
                    meetings.append(meeting)
                } catch {
                    self.error = "无法读取 \(file.path)：\(error.localizedDescription)"
                }
            }
            meetings.sort { $0.createdAt > $1.createdAt }
        } catch {
            self.error = "无法打开会议目录 \(self.root.path)：\(error.localizedDescription)"
        }
    }

    func folder(for id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func audioURL(for meeting: Meeting) -> URL { folder(for: meeting.id).appending(path: meeting.audioFilename) }
    func meeting(_ id: UUID?) -> Meeting? { meetings.first { $0.id == id } }

    /// Preserve the original recording, transcript, minutes and answers for comparison.
    func copyForRetranscription(_ meeting: Meeting) throws -> Meeting {
        var copy = Meeting(title: meeting.title + "（重新转写）", audioFilename: meeting.audioFilename)
        copy.duration = meeting.duration
        try FileManager.default.createDirectory(at: folder(for: copy.id), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audioURL(for: meeting), to: audioURL(for: copy))
        try save(copy)
        return copy
    }

    func save(_ meeting: Meeting) throws {
        let directory = folder(for: meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meeting).write(to: directory.appending(path: "meeting.json"), options: .atomic)
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }

    func update(_ id: UUID, _ edit: (inout Meeting) -> Void) {
        guard var meeting = meeting(id) else { return }
        edit(&meeting)
        do { try save(meeting) }
        catch { self.error = "无法保存 \(folder(for: id).path)：\(error.localizedDescription)" }
    }
}

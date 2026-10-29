import Foundation

struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var originalText: String? = nil
}

struct MeetingQuestion: Codable, Identifiable, Sendable {
    var id = UUID()
    var question: String
    var answer: String
    var sourceIDs: [UUID]
}

struct Meeting: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var audioFilename: String
    var duration: TimeInterval = 0
    var transcript: [TranscriptSegment] = []
    var transcriptionModel: String? = nil
    var minutes = ""
    var questions: [MeetingQuestion] = []
    var minutesNeedUpdate = false

    var transcriptText: String {
        transcript.map { "[\(clockText($0.start))] \($0.text)" }.joined(separator: "\n")
    }
}

struct CremaError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func clockText(_ seconds: TimeInterval) -> String {
    let seconds = seconds.isFinite ? max(0, Int(seconds)) : 0
    if seconds >= 3600 {
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

/// Keep every segment and its stable source index when splitting long meetings.
func transcriptChunks(_ segments: [TranscriptSegment], limit: Int = 6000) -> [String] {
    var chunks: [String] = []
    var current = ""
    for (index, segment) in segments.enumerated() {
        let prefix = "[\(index + 1)] [\(clockText(segment.start))] "
        var remaining = segment.text[...]
        repeat {
            let portion = remaining.prefix(max(1, limit - prefix.count - 1))
            let line = prefix + portion + "\n"
            if !current.isEmpty && current.count + line.count > limit {
                chunks.append(current)
                current = ""
            }
            current += line
            remaining = remaining.dropFirst(portion.count)
        } while !remaining.isEmpty
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

func resolvedSourceIDs(_ numbers: [Int], from segments: [TranscriptSegment]) -> [UUID]? {
    guard numbers.allSatisfy({ $0 > 0 && $0 <= segments.count }) else { return nil }
    var ids: [UUID] = []
    for number in numbers {
        let id = segments[number - 1].id
        if !ids.contains(id) { ids.append(id) }
    }
    return ids
}

/// Accept punctuation-only edits. Any change to a name, number or word rejects the entire edit.
func applyingPunctuation(_ text: String, to segments: [TranscriptSegment]) -> [TranscriptSegment]? {
    let separators = Set("，。！？；：、,.!?;: \n\r\t")
    func letters(_ text: String) -> [Character] { text.filter { !separators.contains($0) }.map { $0 } }
    let counts = segments.map { letters($0.text).count }
    guard !segments.isEmpty, counts.allSatisfy({ $0 > 0 }),
          letters(text) == letters(segments.map(\.text).joined()) else { return nil }
    var output = segments
    var pieces = Array(repeating: "", count: segments.count)
    var index = 0
    var consumed = 0
    for character in text {
        if !separators.contains(character) {
            if consumed == counts[index], index + 1 < counts.count { index += 1; consumed = 0 }
            consumed += 1
        }
        pieces[index].append(character)
    }
    for index in output.indices {
        output[index].originalText = output[index].originalText ?? output[index].text
        output[index].text = pieces[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return output
}

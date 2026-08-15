import Foundation

/// Accumulates segments from both tracks and writes them out as Markdown plus JSON.
///
/// The two tracks arrive interleaved and slightly out of order (each recogniser settles a
/// ~45s chunk at a time), so segments are sorted by timestamp on every write rather than
/// appended blindly.
final class TranscriptWriter {
    let directory: URL
    let markdownURL: URL
    let jsonURL: URL
    let vttURL: URL

    private let meeting: DetectedMeeting
    private let calendar: CalendarMatch?
    private let startedAt: Date
    private var segments: [TranscriptSegment] = []
    private let lock = NSLock()

    init(meeting: DetectedMeeting, calendar: CalendarMatch?, startedAt: Date, root: URL) throws {
        self.meeting = meeting
        self.calendar = calendar
        self.startedAt = startedAt

        let stamp = DateFormatter.folderStamp.string(from: startedAt)
        let slug = TranscriptWriter.slug(calendar?.title ?? meeting.title)
        self.directory = root.appendingPathComponent("\(stamp)-\(slug)", isDirectory: true)
        self.markdownURL = directory.appendingPathComponent("transcript.md")
        self.jsonURL = directory.appendingPathComponent("transcript.json")
        self.vttURL = directory.appendingPathComponent("transcript.vtt")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The calendar event's name when we found one, otherwise whatever the window was called.
    var displayTitle: String { calendar?.title ?? meeting.title }

    func add(_ segment: TranscriptSegment) {
        lock.lock()
        segments.append(segment)
        lock.unlock()
    }

    var segmentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return segments.count
    }

    /// `inProgress` marks the periodic snapshot written during recording, so a transcript
    /// recovered from a crashed session is not mistaken for a complete one.
    func save(endedAt: Date, keptAudio: Bool, audioExtension: String = "wav", inProgress: Bool = false) throws {
        lock.lock()
        let ordered = segments.sorted { $0.start < $1.start }
        lock.unlock()

        try markdown(ordered, endedAt: endedAt, keptAudio: keptAudio,
                     audioExtension: audioExtension, inProgress: inProgress)
            .write(to: markdownURL, atomically: true, encoding: .utf8)

        let payload = TranscriptPayload(
            title: displayTitle,
            platform: meeting.platform,
            windowTitle: meeting.title,
            attendees: calendar?.attendees ?? [],
            organizer: calendar?.organizer,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: endedAt.timeIntervalSince(startedAt),
            inProgress: inProgress,
            segments: ordered.map {
                TranscriptPayload.Segment(
                    start: $0.start, speaker: $0.source.speakerLabel,
                    source: $0.source.rawValue, text: $0.text
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: jsonURL, options: .atomic)

        try Self.webVTT(ordered).write(to: vttURL, atomically: true, encoding: .utf8)
    }

    /// WebVTT so the transcript can be played back against the archived audio.
    ///
    /// The recogniser gives a start time per line but no end time, so each cue runs until
    /// the next one starts; the last is given a length estimated from its word count.
    static func webVTT(_ ordered: [TranscriptSegment]) -> String {
        var out = "WEBVTT\n\n"
        for (index, segment) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1].start : nil
            let estimated = max(2.0, Double(segment.text.split(separator: " ").count) * 0.4)
            let end = max(segment.start + 0.5, next ?? segment.start + estimated)

            out += "\(vttTimestamp(segment.start)) --> \(vttTimestamp(end))\n"
            out += "<v \(segment.source.speakerLabel)>\(segment.text)\n\n"
        }
        return out
    }

    static func vttTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let secs = Int(clamped) % 60
        let millis = Int((clamped - floor(clamped)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    private func markdown(
        _ ordered: [TranscriptSegment], endedAt: Date, keptAudio: Bool,
        audioExtension: String, inProgress: Bool
    ) -> String {
        var out = "# \(displayTitle)\n\n"
        if inProgress {
            out += "> **Recording in progress.** This file is rewritten every 30 seconds.\n\n"
        }
        out += "- **Platform:** \(meeting.platform)\n"
        out += "- **Started:** \(DateFormatter.readable.string(from: startedAt))\n"
        out += "- **Duration:** \(Self.duration(endedAt.timeIntervalSince(startedAt)))\n"
        if let organizer = calendar?.organizer, !organizer.isEmpty {
            out += "- **Organizer:** \(organizer)\n"
        }
        if let attendees = calendar?.attendees, !attendees.isEmpty {
            out += "- **Invited:** \(attendees.joined(separator: ", "))\n"
        }
        if keptAudio {
            out += "- **Audio:** `microphone.\(audioExtension)`, `system.\(audioExtension)`\n"
        }

        let followUps = ActionItems.extract(from: ordered)
        if !followUps.isEmpty {
            out += "\n## Possible follow-ups\n\n"
            out += "_Keyword matches, not a summary — check the timestamp for real context._\n\n"
            for item in followUps {
                out += "- `\(Self.timestamp(item.start))` **\(item.source.speakerLabel):** \(item.text)\n"
            }
        }

        out += "\n## Transcript\n"

        if ordered.isEmpty {
            out += "\n_No speech was recognised in this recording._\n"
            return out
        }

        // Collapse consecutive lines from the same speaker into one paragraph.
        var lastSpeaker: String?
        for segment in ordered {
            let speaker = segment.source.speakerLabel
            if speaker != lastSpeaker {
                out += "\n**\(Self.timestamp(segment.start)) — \(speaker)**\n\n"
                lastSpeaker = speaker
            }
            out += "\(segment.text)\n"
        }
        return out
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m \(total % 60)s"
    }

    static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let collapsed = title
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        let slug = String(collapsed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        let trimmed = String(slug.prefix(60))
        return trimmed.isEmpty ? "meeting" : trimmed
    }
}

private struct TranscriptPayload: Encodable {
    struct Segment: Encodable {
        let start: TimeInterval
        let speaker: String
        let source: String
        let text: String
    }
    let title: String
    let platform: String
    let windowTitle: String
    let attendees: [String]
    let organizer: String?
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: TimeInterval
    let inProgress: Bool
    let segments: [Segment]
}

extension DateFormatter {
    static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    static let readable: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

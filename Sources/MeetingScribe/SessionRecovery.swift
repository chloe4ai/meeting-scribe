import Foundation

/// Cleans up after a session that never got to finish.
///
/// A crash or force-quit leaves the periodic snapshot on disk plus WAVs whose headers were
/// never finalised. This runs at launch, repairs those headers, and notes on the transcript
/// that it was interrupted — so an incomplete transcript is never mistaken for a full one.
enum SessionRecovery {
    struct Result {
        var transcriptsRecovered = 0
        var audioFilesRepaired = 0
    }

    private static let banner = "> **Recording in progress.**"
    private static let recoveredNote = "> **Interrupted.** MeetingScribe stopped unexpectedly during this "
        + "meeting, so the transcript ends where the last autosave landed. The audio files are complete.\n"

    @discardableResult
    static func run(root: URL) -> Result {
        var result = Result()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []

        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
                  let document = try? decoder.decode(TranscriptDocument.self, from: data),
                  document.inProgress == true
            else { continue }

            for name in ["microphone.wav", "system.wav"] {
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if (try? AudioArchive.repairWAVHeaderIfNeeded(at: url)) == true {
                    result.audioFilesRepaired += 1
                }
            }

            if markInterrupted(folder.appendingPathComponent("transcript.md")) {
                result.transcriptsRecovered += 1
            }
        }

        return result
    }

    /// Swaps the "in progress" banner for one saying the session was interrupted. Only the
    /// banner is touched; the transcript body is left exactly as the last autosave wrote it.
    static func markInterrupted(_ markdownURL: URL) -> Bool {
        guard var text = try? String(contentsOf: markdownURL, encoding: .utf8) else { return false }
        guard let range = text.range(of: banner) else { return false }

        // Replace the whole banner line.
        let lineEnd = text.range(of: "\n", range: range.upperBound..<text.endIndex)?.upperBound
            ?? text.endIndex
        text.replaceSubrange(range.lowerBound..<lineEnd, with: recoveredNote)

        try? text.write(to: markdownURL, atomically: true, encoding: .utf8)
        return true
    }
}

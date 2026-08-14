import XCTest
@testable import MeetingScribe

final class TranscriptTests: XCTestCase {

    func testTimestampFormatting() {
        XCTAssertEqual(TranscriptWriter.timestamp(0), "00:00:00")
        XCTAssertEqual(TranscriptWriter.timestamp(71), "00:01:11")
        XCTAssertEqual(TranscriptWriter.timestamp(3725), "01:02:05")
    }

    func testDurationFormatting() {
        XCTAssertEqual(TranscriptWriter.duration(45), "0m 45s")
        XCTAssertEqual(TranscriptWriter.duration(3725), "1h 2m")
    }

    func testSlugIsFilesystemSafe() {
        XCTAssertEqual(TranscriptWriter.slug("Meet - abc-defg-hij"), "meet-abc-defg-hij")
        XCTAssertEqual(TranscriptWriter.slug("Q3 Planning / Roadmap: Draft"), "q3-planning-roadmap-draft")
        XCTAssertEqual(TranscriptWriter.slug(""), "meeting")
        XCTAssertEqual(TranscriptWriter.slug("///"), "meeting")
        XCTAssertLessThanOrEqual(TranscriptWriter.slug(String(repeating: "a", count: 200)).count, 60)
    }

    func testTranscriptWriterProducesMarkdownAndJSON() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let started = Date()
        let writer = try TranscriptWriter(
            meeting: DetectedMeeting(platform: "Google Meet", title: "Weekly Sync"),
            startedAt: started,
            root: root
        )
        // Deliberately out of order: the two tracks settle independently.
        writer.add(TranscriptSegment(source: .system, start: 12.0, text: "Sounds good to me."))
        writer.add(TranscriptSegment(source: .microphone, start: 3.5, text: "Let's start with the roadmap."))

        try writer.save(endedAt: started.addingTimeInterval(600), keptAudio: true)

        let markdown = try String(contentsOf: writer.markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Weekly Sync"))
        XCTAssertTrue(markdown.contains("**Platform:** Google Meet"))

        // Earlier segment must appear first regardless of insertion order.
        let youIndex = try XCTUnwrap(markdown.range(of: "You"))
        let participantsIndex = try XCTUnwrap(markdown.range(of: "Participants"))
        XCTAssertLessThan(youIndex.lowerBound, participantsIndex.lowerBound)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: writer.jsonURL)) as? [String: Any]
        let segments = try XCTUnwrap(json?["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?["speaker"] as? String, "You")
    }

    func testEmptyTranscriptStillWrites() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try TranscriptWriter(
            meeting: DetectedMeeting(platform: "Zoom", title: "Silent"),
            startedAt: Date(), root: root
        )
        try writer.save(endedAt: Date(), keptAudio: false)
        let markdown = try String(contentsOf: writer.markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("No speech was recognised"))
    }

    func testSpeakerLabels() {
        XCTAssertEqual(AudioSource.microphone.speakerLabel, "You")
        XCTAssertEqual(AudioSource.system.speakerLabel, "Participants")
    }
}

import AVFoundation
import XCTest
@testable import MeetingScribe

final class AudioArchiveTests: XCTestCase {

    private func makeWAV(seconds: Double = 1.0) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-wav-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.25
        }
        try file.write(from: buffer)
        return url
    }

    /// Simulates the crash case: the file holds all its samples but the header still
    /// claims the placeholder length AVAudioFile wrote when it opened the file.
    private func zeroOutSizes(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: UInt32(0).littleEndianData)
        // The data chunk header sits at offset 36 in a canonical 44-byte PCM WAV.
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: UInt32(0).littleEndianData)
    }

    func testRepairsTruncatedHeader() throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let expectedFrames = try AVAudioFile(forReading: url).length
        XCTAssertGreaterThan(expectedFrames, 0)

        try zeroOutSizes(url)
        // A zeroed header makes the file unreadable — CoreAudio rejects it outright rather
        // than reporting zero frames.
        XCTAssertNil(try? AVAudioFile(forReading: url))

        XCTAssertTrue(try AudioArchive.repairWAVHeaderIfNeeded(at: url))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, expectedFrames)
    }

    func testHealthyFileIsLeftAlone() throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try AudioArchive.repairWAVHeaderIfNeeded(at: url))
    }

    func testNonWAVIsIgnored() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-\(UUID().uuidString).bin")
        try Data(repeating: 0xAB, count: 512).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try AudioArchive.repairWAVHeaderIfNeeded(at: url))
    }
}

final class SearchTests: XCTestCase {

    func testTokenisationKeepsQuotedPhrases() {
        XCTAssertEqual(TranscriptIndex.tokens(from: "pricing model"), ["pricing", "model"])
        XCTAssertEqual(TranscriptIndex.tokens(from: "\"pricing model\""), ["pricing model"])
        XCTAssertEqual(TranscriptIndex.tokens(from: "  spaced   out "), ["spaced", "out"])
        XCTAssertTrue(TranscriptIndex.tokens(from: "   ").isEmpty)
    }

    func testAllTermsMustMatch() {
        let line = "We should revisit the pricing model next quarter."
        XCTAssertTrue(TranscriptIndex.matches(line, tokens: ["pricing", "model"]))
        XCTAssertTrue(TranscriptIndex.matches(line, tokens: ["PRICING"]))
        XCTAssertFalse(TranscriptIndex.matches(line, tokens: ["pricing", "roadmap"]))
        XCTAssertFalse(TranscriptIndex.matches(line, tokens: []))
    }

    func testPhraseDoesNotMatchScatteredWords() {
        let line = "The model we use for pricing is old."
        XCTAssertTrue(TranscriptIndex.matches(line, tokens: ["pricing", "model"]))
        XCTAssertFalse(TranscriptIndex.matches(line, tokens: ["pricing model"]))
    }

    func testSearchAcrossSavedTranscripts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let older = try TranscriptWriter(
            meeting: DetectedMeeting(platform: "Zoom", title: "Old Sync"),
            calendar: nil, startedAt: Date().addingTimeInterval(-86_400), root: root
        )
        older.add(TranscriptSegment(source: .microphone, start: 5, text: "The pricing model needs work."))
        try older.save(endedAt: Date().addingTimeInterval(-86_000), keptAudio: false)

        let newer = try TranscriptWriter(
            meeting: DetectedMeeting(platform: "Google Meet", title: "New Sync"),
            calendar: nil, startedAt: Date(), root: root
        )
        newer.add(TranscriptSegment(source: .system, start: 9, text: "Let's ship the roadmap."))
        try newer.save(endedAt: Date(), keptAudio: false)

        let pricing = TranscriptIndex.search("pricing", in: root)
        XCTAssertEqual(pricing.count, 1)
        XCTAssertEqual(pricing.first?.meetingTitle, "Old Sync")
        XCTAssertEqual(pricing.first?.start, 5)
        XCTAssertEqual(pricing.first?.speaker, "You")

        XCTAssertTrue(TranscriptIndex.search("nonexistentterm", in: root).isEmpty)

        // Newest meeting first when both match.
        let sync = TranscriptIndex.search("sync", in: root)
        XCTAssertEqual(sync.first?.meetingTitle, "New Sync")
    }
}

final class RecoveryTests: XCTestCase {

    func testInterruptedBannerReplacesInProgressBanner() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try TranscriptWriter(
            meeting: DetectedMeeting(platform: "Zoom", title: "Crashed"),
            calendar: nil, startedAt: Date(), root: root
        )
        writer.add(TranscriptSegment(source: .microphone, start: 1, text: "This is the only surviving line."))
        try writer.save(endedAt: Date(), keptAudio: true, inProgress: true)

        let result = SessionRecovery.run(root: root)
        XCTAssertEqual(result.transcriptsRecovered, 1)

        let markdown = try String(contentsOf: writer.markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Interrupted."))
        XCTAssertFalse(markdown.contains("Recording in progress"))
        // The transcript body must survive untouched.
        XCTAssertTrue(markdown.contains("This is the only surviving line."))
    }

    func testCompletedTranscriptsAreNotTouched() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try TranscriptWriter(
            meeting: DetectedMeeting(platform: "Zoom", title: "Clean"),
            calendar: nil, startedAt: Date(), root: root
        )
        try writer.save(endedAt: Date(), keptAudio: false)

        XCTAssertEqual(SessionRecovery.run(root: root).transcriptsRecovered, 0)
        let markdown = try String(contentsOf: writer.markdownURL, encoding: .utf8)
        XCTAssertFalse(markdown.contains("Interrupted."))
    }
}

final class WebVTTTests: XCTestCase {

    func testTimestampFormat() {
        XCTAssertEqual(TranscriptWriter.vttTimestamp(0), "00:00:00.000")
        XCTAssertEqual(TranscriptWriter.vttTimestamp(3725.5), "01:02:05.500")
    }

    func testCuesRunUntilTheNextOne() {
        let vtt = TranscriptWriter.webVTT([
            TranscriptSegment(source: .microphone, start: 0, text: "First line."),
            TranscriptSegment(source: .system, start: 4, text: "Second line."),
        ])
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:04.000"))
        XCTAssertTrue(vtt.contains("<v You>First line."))
        XCTAssertTrue(vtt.contains("<v Participants>Second line."))
    }

    func testLastCueGetsAnEstimatedLength() {
        let vtt = TranscriptWriter.webVTT([
            TranscriptSegment(source: .microphone, start: 10, text: "One two three four five")
        ])
        // Five words at 0.4s each = 2s.
        XCTAssertTrue(vtt.contains("00:00:10.000 --> 00:00:12.000"))
    }
}

final class LocalizedDetectionTests: XCTestCase {

    func testChineseMeetingWindowsAreDetected() {
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "Zoom 会议"))
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "会议"))
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "com.microsoft.teams2", title: "每周同步 | 会议"))
    }

    func testOtherLanguages() {
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "Zoom ミーティング"))
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "Reunión de Zoom"))
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "Zoom-Besprechung"))
    }

    func testIdleWindowsStillRejectedAcrossLanguages() {
        XCTAssertFalse(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "Zoom"))
        XCTAssertFalse(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "设置"))
        XCTAssertFalse(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "com.microsoft.teams2", title: "聊天 | Microsoft Teams"))
    }

    func testLocalizedZoomWebTab() {
        XCTAssertEqual(MeetingDetector.browserPlatform(for: "Zoom 会议 - Google Chrome"), "Zoom")
        XCTAssertNil(MeetingDetector.browserPlatform(for: "Zoom Pricing Plans - Google Chrome"))
    }
}

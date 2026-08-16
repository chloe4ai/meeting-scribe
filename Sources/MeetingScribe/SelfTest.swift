import AVFoundation
import Foundation
import ScreenCaptureKit
import Speech

/// End-to-end check of the transcription path, runnable from the terminal:
///
///     /Applications/MeetingScribe.app/Contents/MacOS/MeetingScribe --self-test
///
/// Synthesises a known phrase, pushes it through the same resampler and recogniser the
/// live pipeline uses, and reports what came back. This is the answer to "it recorded but
/// the transcript is empty" — the usual causes (permission not granted, no on-device model
/// for the selected language) are exactly what it reports.
///
/// It runs inside the app bundle deliberately: TCC grants are keyed to the bundle's code
/// signature, so a loose binary would see a different, unauthorised identity.
/// Lets `main.swift` poll for completion from the run loop without blocking it.
final class SelfTestRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var code: Int32 = 1

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    var exitCode: Int32 {
        lock.lock(); defer { lock.unlock() }
        return code
    }

    func finish(_ value: Int32) {
        lock.lock()
        code = value
        done = true
        lock.unlock()
    }
}

enum SelfTest {

    /// Report lines are also written here, because the useful way to invoke this is through
    /// LaunchServices (`open -a MeetingScribe --args --self-test`), which discards stdout.
    /// Running the binary straight from a shell makes TCC attribute the privacy request to
    /// the parent terminal, which has no speech-recognition usage description and gets the
    /// process killed before it can report anything.
    static let reportURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/MeetingScribe-selftest.txt")

    private static var lines: [String] = []

    private static func emit(_ text: String = "") {
        print(text)
        lines.append(text)
    }

    private static func flushReport() {
        try? FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? lines.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }

    static func run() async -> Int32 {
        let code = await runReport()
        emit("\n  Report written to \(reportURL.path)")
        flushReport()
        return code
    }

    private static func runReport() async -> Int32 {
        var blockers: [String] = []
        emit("MeetingScribe self-test\n")

        // --- Permissions -------------------------------------------------------
        let speechStatus = await authorizationStatus()
        emit("  Speech recognition : \(describe(speechStatus))")
        if speechStatus != .authorized {
            blockers.append("Speech Recognition permission — nothing can be transcribed without it.")
        }

        let screenOK = await hasScreenRecordingAccess()
        emit("  Screen recording   : \(screenOK ? "granted" : "NOT GRANTED")")
        if !screenOK {
            blockers.append(
                "Screen Recording permission — this is how meeting audio is captured, so "
                + "without it every recording will be silent. Grant it under System Settings "
                + "› Privacy & Security › Screen & System Audio Recording, then relaunch."
            )
        }

        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        emit("  Microphone         : \(micOK ? "granted" : "NOT GRANTED")")
        if !micOK {
            blockers.append(
                "Microphone permission — your own speech will be missing from every "
                + "transcript. Grant it under System Settings › Privacy & Security › Microphone."
            )
        }

        // --- Language ----------------------------------------------------------
        let locale = SpeechLocales.resolve(Settings.shared.speechLocaleIdentifier)
        let onDevice = SpeechLocales.supportsOnDevice(locale)
        emit("  Language           : \(SpeechLocales.displayName(for: locale)) "
              + "(\(onDevice ? "on-device model installed" : "NO on-device model"))")
        if !onDevice {
            blockers.append(
                "No on-device model for \(SpeechLocales.displayName(for: locale)). Add the "
                + "language under System Settings › General › Language & Region."
            )
        }

        // The transcription check only needs speech recognition, so run it even when the
        // capture permissions are missing — a diagnostic that stops at the first problem
        // makes you fix things one relaunch at a time.
        guard speechStatus == .authorized, onDevice else {
            report(blockers)
            return 1
        }

        // --- Transcription round trip -----------------------------------------
        let phrase = "The quarterly roadmap review is scheduled for next Tuesday"
        emit("\n  Synthesising a test phrase…")
        guard let audioURL = synthesise(phrase, voiceLocale: locale) else {
            emit("  FAILED: could not synthesise test audio with /usr/bin/say.")
            return 1
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        emit("  Transcribing through the live pipeline…")
        let transcript: String
        do {
            transcript = try await transcribe(audioURL, locale: locale)
        } catch {
            emit("  FAILED: \(error.localizedDescription)")
            return 1
        }

        emit("\n  Expected : \(phrase)")
        emit("  Got      : \(transcript.isEmpty ? "(nothing)" : transcript)")

        let (matched, total) = wordOverlap(expected: phrase, actual: transcript)
        emit("  Words    : \(matched)/\(total) matched")

        // A recogniser that lands most of a clean synthetic phrase is working; demanding a
        // perfect match would fail on trivia like "Tuesday" versus "Tuesday."
        guard total > 0, Double(matched) / Double(total) >= 0.6 else {
            emit("\n  Transcription FAILED — audio went in, no usable text came back.")
            report(blockers)
            return 1
        }

        emit("\n  Transcription: OK")
        report(blockers)
        return blockers.isEmpty ? 0 : 1
    }

    private static func report(_ blockers: [String]) {
        guard !blockers.isEmpty else {
            emit("\n  PASS — permissions and transcription are both working.")
            return
        }
        emit("\n  \(blockers.count) problem\(blockers.count == 1 ? "" : "s") to fix:\n")
        for (index, blocker) in blockers.enumerated() {
            emit("  \(index + 1). \(blocker)")
        }
    }

    // MARK: - Steps

    private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied: return "DENIED — enable under Privacy & Security › Speech Recognition"
        case .restricted: return "restricted by policy"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private static func hasScreenRecordingAccess() async -> Bool {
        ((try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil)
    }

    /// Uses `say` so the check needs no bundled audio fixture.
    private static func synthesise(_ text: String, voiceLocale: Locale) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meetingscribe-selftest-\(UUID().uuidString).aiff")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Feeds the file through `AudioResampler` and `AppleSpeechTranscriber` in the same
    /// shape the capture callback does — small buffers, arriving in order.
    private static func transcribe(_ url: URL, locale: Locale) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        let resampler = AudioResampler()
        let transcriber = try AppleSpeechTranscriber(
            source: .system, locale: locale, allowServerFallback: Settings.shared.allowServerFallback
        )

        let collected = Collector()
        transcriber.onSegment = { segment in collected.append(segment.text) }

        let chunkFrames: AVAudioFrameCount = 4_800   // 100 ms at 48 kHz, as ScreenCaptureKit delivers
        var offset: TimeInterval = 0

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
            else { break }
            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0 else { break }

            if let converted = resampler.convert(buffer) {
                transcriber.append(converted, at: offset)
                offset += Double(converted.frameLength) / AudioResampler.targetFormat.sampleRate
            }
        }

        await transcriber.finish()
        return collected.text()
    }

    /// The recogniser reports on the main queue; this is the handoff back.
    private final class Collector: @unchecked Sendable {
        private var parts: [String] = []
        private let lock = NSLock()

        func append(_ text: String) {
            lock.lock(); parts.append(text); lock.unlock()
        }

        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return parts.joined(separator: " ")
        }
    }

    static func wordOverlap(expected: String, actual: String) -> (matched: Int, total: Int) {
        let normalise: (String) -> [String] = { text in
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let expectedWords = normalise(expected)
        var actualWords = normalise(actual)

        var matched = 0
        for word in expectedWords {
            if let index = actualWords.firstIndex(of: word) {
                actualWords.remove(at: index)
                matched += 1
            }
        }
        return (matched, expectedWords.count)
    }
}

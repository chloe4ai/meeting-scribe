import AVFoundation
import Foundation

/// One meeting, from first buffer to written transcript.
final class RecordingSession: NSObject, AudioCaptureDelegate {
    let meeting: DetectedMeeting
    let startedAt: Date
    /// Started from the menu rather than by the detector, so the detector must not stop it.
    let isManual: Bool

    /// Reported on the main queue when the capture stream dies unexpectedly.
    var onFailure: ((Error) -> Void)?

    private let capture = AudioCapture()
    private let writer: TranscriptWriter
    private var tracks: [AudioSource: AudioTrack] = [:]
    private let settings: Settings

    private(set) var isPaused = false

    init(meeting: DetectedMeeting, isManual: Bool, settings: Settings = .shared) throws {
        self.meeting = meeting
        self.isManual = isManual
        self.startedAt = Date()
        self.settings = settings

        let calendarMatch = settings.useCalendarTitles ? CalendarLookup.match() : nil
        self.writer = try TranscriptWriter(
            meeting: meeting, calendar: calendarMatch, startedAt: startedAt, root: settings.transcriptRoot
        )
        super.init()

        let locale = SpeechLocales.resolve(settings.speechLocaleIdentifier)
        for source in [AudioSource.microphone, .system] {
            let transcriber = try AppleSpeechTranscriber(
                source: source, locale: locale, allowServerFallback: settings.allowServerFallback
            )
            transcriber.onSegment = { [weak self] segment in self?.writer.add(segment) }
            tracks[source] = try AudioTrack(source: source, directory: writer.directory, transcriber: transcriber)
        }

        capture.delegate = self
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    var segmentCount: Int { writer.segmentCount }
    var transcriptDirectory: URL { writer.directory }
    var title: String { writer.displayTitle }

    func start() async throws {
        try await capture.start()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        for track in tracks.values { track.setPaused(paused) }
    }

    /// Periodic snapshot so a crash or forced quit mid-meeting still leaves a transcript.
    /// Driven by the app delegate's timer, which owns all the main-thread scheduling.
    func writeSnapshot() {
        do {
            try writer.save(endedAt: Date(), keptAudio: settings.keepAudio, inProgress: true)
        } catch {
            NSLog("MeetingScribe: snapshot failed — \(error.localizedDescription)")
        }
    }

    /// Stops capture, drains both recognisers, and writes the transcript to disk.
    @discardableResult
    func stop() async -> URL {
        await capture.stop()

        for track in tracks.values {
            await track.finish()
        }

        var audioExtension = "wav"
        if settings.keepAudio {
            if settings.compressAudio {
                // Recording ran to WAV so a crash would leave repairable audio; now that the
                // meeting ended cleanly, trade that for roughly a tenth of the disk space.
                var allCompressed = true
                for track in tracks.values {
                    if await AudioArchive.compressToM4A(track.audioURL) == nil { allCompressed = false }
                }
                if allCompressed { audioExtension = "m4a" }
            }
        } else {
            for track in tracks.values { track.discardAudio() }
        }

        do {
            try writer.save(endedAt: Date(), keptAudio: settings.keepAudio, audioExtension: audioExtension)
        } catch {
            NSLog("MeetingScribe: failed to write transcript — \(error.localizedDescription)")
        }
        return writer.directory
    }

    // MARK: - AudioCaptureDelegate

    func audioCapture(_ capture: AudioCapture, didProduce buffer: AVAudioPCMBuffer, from source: AudioSource) {
        tracks[source]?.accept(buffer)
    }

    func audioCapture(_ capture: AudioCapture, didFailWith error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
}

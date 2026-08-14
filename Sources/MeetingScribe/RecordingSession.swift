import AVFoundation
import Foundation

/// One meeting, from first buffer to written transcript.
final class RecordingSession: NSObject, AudioCaptureDelegate {
    let meeting: DetectedMeeting
    let startedAt: Date

    /// Reported on the main queue when the capture stream dies unexpectedly.
    var onFailure: ((Error) -> Void)?

    private let capture = AudioCapture()
    private let writer: TranscriptWriter
    private var tracks: [AudioSource: AudioTrack] = [:]

    init(meeting: DetectedMeeting, settings: Settings = .shared) throws {
        self.meeting = meeting
        self.startedAt = Date()
        self.writer = try TranscriptWriter(meeting: meeting, startedAt: startedAt, root: settings.transcriptRoot)
        super.init()

        for source in [AudioSource.microphone, .system] {
            let transcriber = try AppleSpeechTranscriber(
                source: source, allowServerFallback: settings.allowServerFallback
            )
            transcriber.onSegment = { [weak self] segment in self?.writer.add(segment) }
            tracks[source] = try AudioTrack(source: source, directory: writer.directory, transcriber: transcriber)
        }

        capture.delegate = self
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    var segmentCount: Int { writer.segmentCount }
    var transcriptDirectory: URL { writer.directory }

    func start() async throws {
        try await capture.start()
    }

    /// Stops capture, drains both recognisers, and writes the transcript to disk.
    @discardableResult
    func stop(settings: Settings = .shared) async -> URL {
        await capture.stop()

        for track in tracks.values {
            await track.finish()
        }

        if !settings.keepAudio {
            for track in tracks.values { track.discardAudio() }
        }

        do {
            try writer.save(endedAt: Date(), keptAudio: settings.keepAudio)
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

import AVFoundation

/// Resamples whatever the capture hands us down to 16 kHz mono.
///
/// That is the format the speech recogniser wants, and it cuts the archived audio from
/// ~1.4 GB/hour to ~115 MB/hour per track. Extracted from `AudioTrack` so the self-test
/// can push audio through the exact same conversion the live pipeline uses.
final class AudioResampler {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Self.targetFormat

        if converter == nil || inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            converter?.downmix = true   // sum both channels instead of keeping only the left
            inputFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// One recorded track (mic or system): resamples incoming buffers, archives them to disk,
/// and feeds the transcriber.
final class AudioTrack {
    let source: AudioSource
    let audioURL: URL

    private let targetFormat = AudioResampler.targetFormat
    private let transcriber: TranscriptionBackend
    private let resampler = AudioResampler()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var paused = false
    private let lock = NSLock()

    init(source: AudioSource, directory: URL, transcriber: TranscriptionBackend) throws {
        self.source = source
        self.transcriber = transcriber
        self.audioURL = directory.appendingPathComponent("\(source.rawValue).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // 16-bit on disk, float32 in memory — AVAudioFile handles the narrowing on write.
        self.file = try AVAudioFile(
            forWriting: audioURL, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
    }

    /// Position in the recording, derived from frames actually written rather than wall
    /// clock, so transcript timestamps line up with the archived audio.
    var elapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(framesWritten) / targetFormat.sampleRate
    }

    /// While paused, buffers are dropped rather than written. Because the transcript clock
    /// is derived from frames written, the paused stretch is simply absent from the
    /// timeline instead of appearing as a long silence.
    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let isPaused = paused
        lock.unlock()
        guard !isPaused else { return }

        guard let converted = resampler.convert(buffer) else { return }

        lock.lock()
        let offset = Double(framesWritten) / targetFormat.sampleRate
        framesWritten += AVAudioFramePosition(converted.frameLength)
        let file = self.file
        lock.unlock()

        try? file?.write(from: converted)
        transcriber.append(converted, at: offset)
    }

    func finish() async {
        await transcriber.finish()
        closeFile()
    }

    /// Kept non-async so the lock is never taken across a suspension point.
    private func closeFile() {
        lock.lock()
        file = nil  // closes and finalises the WAV header
        lock.unlock()
    }

    func discardAudio() {
        try? FileManager.default.removeItem(at: audioURL)
    }

}

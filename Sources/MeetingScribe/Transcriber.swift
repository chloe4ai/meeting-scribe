import AVFoundation
import Speech

struct TranscriptSegment {
    let source: AudioSource
    let start: TimeInterval
    let text: String
}

protocol TranscriptionBackend: AnyObject {
    var onSegment: ((TranscriptSegment) -> Void)? { get set }
    func append(_ buffer: AVAudioPCMBuffer, at offset: TimeInterval)
    func finish() async
}

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable(locale: String)
    case onDeviceUnavailable(locale: String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech Recognition permission was denied. Grant it in System Settings › Privacy & Security › Speech Recognition."
        case .recognizerUnavailable(let locale):
            return "No speech recognizer is available for \(locale)."
        case .onDeviceUnavailable(let locale):
            return "On-device speech recognition is not installed for \(locale). Add the language under System Settings › General › Language & Region, or enable server fallback in the menu."
        }
    }
}

/// Transcribes one audio track with Apple's on-device speech recogniser.
///
/// `SFSpeechRecognizer` will not run a single buffer request for the length of a meeting —
/// it stops after roughly a minute. So this rotates through short-lived recognition tasks:
/// audio always goes to a fresh request well before the ceiling, and the outgoing task is
/// left alive just long enough to deliver its final result. Nothing is dropped at the seam
/// because the new request exists before the old one is closed.
final class AppleSpeechTranscriber: TranscriptionBackend {
    var onSegment: ((TranscriptSegment) -> Void)?

    private let source: AudioSource
    private let recognizer: SFSpeechRecognizer
    private let requiresOnDevice: Bool
    private let queue = DispatchQueue(label: "com.chloetan.meetingscribe.speech")

    /// Comfortably under the recogniser's ~60s ceiling.
    private let maxUnitDuration: TimeInterval = 45

    private final class Unit {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        let startOffset: TimeInterval
        var settled = false
        init(startOffset: TimeInterval) { self.startOffset = startOffset }
    }

    private var currentUnit: Unit?
    private var pendingUnits: [Unit] = []
    private var finished = false

    init(source: AudioSource, locale: Locale = Locale.current, allowServerFallback: Bool) throws {
        self.source = source

        let candidate = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer = candidate, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable(locale: locale.identifier)
        }
        if !recognizer.supportsOnDeviceRecognition && !allowServerFallback {
            throw TranscriptionError.onDeviceUnavailable(locale: locale.identifier)
        }
        self.recognizer = recognizer
        self.requiresOnDevice = recognizer.supportsOnDeviceRecognition
    }

    static func requestAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.notAuthorized }
    }

    func append(_ buffer: AVAudioPCMBuffer, at offset: TimeInterval) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }

            if let unit = self.currentUnit, offset - unit.startOffset >= self.maxUnitDuration {
                self.rotate(at: offset)
            } else if self.currentUnit == nil {
                self.openUnit(at: offset)
            }

            self.currentUnit?.request.append(buffer)
        }
    }

    func finish() async {
        queue.sync {
            finished = true
            if let unit = currentUnit {
                unit.request.endAudio()
                pendingUnits.append(unit)
                currentUnit = nil
            }
        }

        // Give the outstanding tasks a bounded window to deliver their final results.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let outstanding = queue.sync { pendingUnits.contains { !$0.settled } }
            if !outstanding { break }
            try? await Task.sleep(for: .milliseconds(150))
        }

        queue.sync {
            for unit in pendingUnits where !unit.settled {
                unit.task?.cancel()
                unit.settled = true
            }
            pendingUnits.removeAll()
        }
    }

    // MARK: - Recognition units

    private func openUnit(at offset: TimeInterval) {
        let unit = Unit(startOffset: offset)
        unit.request.shouldReportPartialResults = false
        unit.request.requiresOnDeviceRecognition = requiresOnDevice
        unit.request.taskHint = .dictation
        unit.request.addsPunctuation = true

        unit.task = recognizer.recognitionTask(with: unit.request) { [weak self, weak unit] result, error in
            guard let self, let unit else { return }
            self.queue.async {
                guard !unit.settled else { return }
                if let result, result.isFinal {
                    unit.settled = true
                    self.emit(result, from: unit)
                    self.pendingUnits.removeAll { $0 === unit }
                } else if error != nil {
                    unit.settled = true
                    self.pendingUnits.removeAll { $0 === unit }
                }
            }
        }

        currentUnit = unit
    }

    /// Opens the replacement before closing the outgoing unit so no audio falls between them.
    private func rotate(at offset: TimeInterval) {
        let outgoing = currentUnit
        openUnit(at: offset)
        if let outgoing {
            outgoing.request.endAudio()
            pendingUnits.append(outgoing)
        }
    }

    /// Delivered on the recogniser's own queue, not the main queue: the only consumer is
    /// the transcript writer, which is already lock-protected, and hopping to main would
    /// mean segments are silently dropped anywhere the main run loop isn't spinning.
    private func emit(_ result: SFSpeechRecognitionResult, from unit: Unit) {
        let lines = Self.sentences(from: result, offsetBy: unit.startOffset, source: source)
        guard !lines.isEmpty else { return }
        for line in lines { onSegment?(line) }
    }

    /// Splits a result into sentence-sized lines carrying their own timestamps. Without this
    /// every rotation would land in the transcript as one undifferentiated 45-second paragraph.
    static func sentences(
        from result: SFSpeechRecognitionResult,
        offsetBy startOffset: TimeInterval,
        source: AudioSource
    ) -> [TranscriptSegment] {
        let speechSegments = result.bestTranscription.segments
        guard !speechSegments.isEmpty else {
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [TranscriptSegment(source: source, start: startOffset, text: text)]
        }

        var lines: [TranscriptSegment] = []
        var words: [String] = []
        var lineStart: TimeInterval?

        for speechSegment in speechSegments {
            let word = speechSegment.substring.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            if lineStart == nil { lineStart = startOffset + speechSegment.timestamp }
            words.append(word)

            if let last = word.unicodeScalars.last, ".?!".unicodeScalars.contains(last) {
                lines.append(TranscriptSegment(source: source, start: lineStart ?? startOffset,
                                               text: words.joined(separator: " ")))
                words.removeAll()
                lineStart = nil
            }
        }

        if !words.isEmpty {
            lines.append(TranscriptSegment(source: source, start: lineStart ?? startOffset,
                                           text: words.joined(separator: " ")))
        }
        return lines
    }
}

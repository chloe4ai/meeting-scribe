import AVFoundation
import ScreenCaptureKit

enum AudioSource: String {
    case microphone
    case system

    /// Label used for this source in the written transcript.
    var speakerLabel: String {
        switch self {
        case .microphone: return "You"
        case .system: return "Participants"
        }
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available to attach the audio stream to."
        case .permissionDenied:
            return "Screen Recording permission is required to capture meeting audio."
        }
    }
}

protocol AudioCaptureDelegate: AnyObject {
    func audioCapture(_ capture: AudioCapture, didProduce buffer: AVAudioPCMBuffer, from source: AudioSource)
    func audioCapture(_ capture: AudioCapture, didFailWith error: Error)
}

/// Captures system output and microphone input as two independent tracks via ScreenCaptureKit.
///
/// ScreenCaptureKit taps the system mix directly, so there is no virtual audio driver
/// (BlackHole, Loopback) to install. Keeping the two tracks separate is what lets the
/// transcript attribute lines to "You" versus "Participants".
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var delegate: AudioCaptureDelegate?

    private var stream: SCStream?
    private let systemQueue = DispatchQueue(label: "com.chloetan.meetingscribe.audio.system")
    private let microphoneQueue = DispatchQueue(label: "com.chloetan.meetingscribe.audio.microphone")

    var isRunning: Bool { stream != nil }

    func start() async throws {
        guard stream == nil else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        // A display filter is mandatory even for an audio-only capture, so we ask for the
        // smallest, slowest video stream the API will accept and simply never read it.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 5
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        let source: AudioSource
        switch type {
        case .audio: source = .system
        case .microphone: source = .microphone
        default: return  // .screen frames are the unavoidable cost of the audio tap; drop them.
        }

        guard let buffer = sampleBuffer.asPCMBuffer else { return }
        delegate?.audioCapture(self, didProduce: buffer, from: source)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        delegate?.audioCapture(self, didFailWith: error)
    }
}

extension CMSampleBuffer {
    /// Copies an LPCM sample buffer into an `AVAudioPCMBuffer` without taking ownership of
    /// the underlying block buffer, which ScreenCaptureKit recycles as soon as we return.
    var asPCMBuffer: AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}

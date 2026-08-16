import AVFoundation
import XCTest
@testable import MeetingScribe

/// Exercises the audio path that does not need TCC permission: the resampler every
/// captured buffer passes through before it reaches the recogniser.
final class AudioResamplerTests: XCTestCase {

    private func buffer(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double,
                        fill: (Int, Int) -> Float = { _, _ in 0 }) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = fill(channel, frame)
            }
        }
        return buffer
    }

    func testDownsamplesToSixteenKilohertzMono() {
        let resampler = AudioResampler()
        // What ScreenCaptureKit actually delivers: 48 kHz stereo.
        let input = buffer(sampleRate: 48_000, channels: 2, seconds: 0.5) { _, frame in
            sin(Float(frame) * 0.01) * 0.5
        }

        guard let converted = resampler.convert(input) else {
            return XCTFail("conversion returned nil")
        }
        XCTAssertEqual(converted.format.sampleRate, 16_000)
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(converted.frameLength, 0)
    }

    /// The number that actually matters: across a stream of small buffers — how capture
    /// really delivers audio — almost nothing may be dropped, or the transcript degrades.
    ///
    /// A single isolated buffer legitimately returns fewer frames than its duration implies,
    /// because `AVAudioConverter` keeps roughly 26 ms internally and releases it on the next
    /// call. Asserting against one buffer would be asserting against that latency.
    func testStreamingLosesAlmostNoAudio() {
        let resampler = AudioResampler()
        var totalFrames: AVAudioFrameCount = 0

        // 5 seconds delivered as 100 ms chunks, as ScreenCaptureKit does.
        for _ in 0..<50 {
            let chunk = buffer(sampleRate: 48_000, channels: 2, seconds: 0.1) { _, frame in
                sin(2 * .pi * 200 * Float(frame) / 48_000) * 0.8
            }
            if let converted = resampler.convert(chunk) {
                totalFrames += converted.frameLength
            }
        }

        let ideal = 5.0 * 16_000
        let retention = Double(totalFrames) / ideal
        XCTAssertGreaterThan(retention, 0.99, "resampler dropped \((1 - retention) * 100)% of the audio")
        XCTAssertLessThanOrEqual(retention, 1.0)
    }

    func testAudioSurvivesConversion() {
        let resampler = AudioResampler()
        // A 200 Hz tone is well under the 8 kHz Nyquist limit of the 16 kHz target, so it
        // must come through with its amplitude broadly intact rather than as silence.
        let input = buffer(sampleRate: 48_000, channels: 1, seconds: 0.5) { _, frame in
            sin(2 * .pi * 200 * Float(frame) / 48_000) * 0.8
        }

        guard let output = resampler.convert(input) else {
            return XCTFail("conversion returned nil")
        }
        var peak: Float = 0
        for frame in 0..<Int(output.frameLength) {
            peak = max(peak, abs(output.floatChannelData![0][frame]))
        }
        XCTAssertGreaterThan(peak, 0.5, "tone was lost or heavily attenuated")
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    func testHandlesAFormatChangeMidStream() {
        // The mic and system streams can differ, and a device change swaps the format
        // underneath us; the converter must be rebuilt rather than reused.
        let resampler = AudioResampler()
        XCTAssertNotNil(resampler.convert(buffer(sampleRate: 48_000, channels: 2, seconds: 0.1)))
        XCTAssertNotNil(resampler.convert(buffer(sampleRate: 44_100, channels: 1, seconds: 0.1)))
        XCTAssertNotNil(resampler.convert(buffer(sampleRate: 16_000, channels: 1, seconds: 0.1)))
    }
}

final class SelfTestScoringTests: XCTestCase {

    func testPerfectMatch() {
        let (matched, total) = SelfTest.wordOverlap(
            expected: "the roadmap review is Tuesday",
            actual: "The roadmap review is Tuesday."
        )
        XCTAssertEqual(matched, 5)
        XCTAssertEqual(total, 5)
    }

    func testPunctuationAndCaseAreIgnored() {
        let (matched, total) = SelfTest.wordOverlap(expected: "next Tuesday", actual: "next tuesday!!")
        XCTAssertEqual(matched, total)
    }

    func testPartialMatchIsCounted() {
        let (matched, total) = SelfTest.wordOverlap(
            expected: "the quarterly roadmap review",
            actual: "the quarterly rhubarb review"
        )
        XCTAssertEqual(matched, 3)
        XCTAssertEqual(total, 4)
    }

    func testRepeatedWordsAreNotDoubleCounted() {
        // "the" appears twice in the expectation but only once in the result.
        let (matched, total) = SelfTest.wordOverlap(expected: "the cat and the dog", actual: "the cat dog")
        XCTAssertEqual(matched, 3)
        XCTAssertEqual(total, 5)
    }

    func testEmptyTranscriptScoresZero() {
        let (matched, total) = SelfTest.wordOverlap(expected: "anything at all", actual: "")
        XCTAssertEqual(matched, 0)
        XCTAssertEqual(total, 3)
    }
}

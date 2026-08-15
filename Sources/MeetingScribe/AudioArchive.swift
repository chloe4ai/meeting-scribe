import AVFoundation
import Foundation

/// Post-processing for the archived audio: repairing files a crash left behind, and
/// shrinking finished recordings.
enum AudioArchive {

    // MARK: - Crash repair

    /// `AVAudioFile` only stamps the real RIFF and data chunk lengths when it closes, so a
    /// process that dies mid-meeting leaves a WAV whose header claims far fewer bytes than
    /// the file actually holds. The samples are all there — raw PCM survives truncation —
    /// but most players trust the header and play silence.
    ///
    /// Returns true when the file was inconsistent and has been rewritten.
    @discardableResult
    static func repairWAVHeaderIfNeeded(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        // 12-byte RIFF header + at least one 8-byte chunk header.
        guard fileSize > 44 else { return false }

        try handle.seek(toOffset: 0)
        guard let riff = try handle.read(upToCount: 12), riff.count == 12,
              riff.prefix(4) == Data("RIFF".utf8),
              riff.suffix(4) == Data("WAVE".utf8)
        else { return false }

        // Walk the chunk list to find `data`, which must be the last chunk we wrote.
        var offset: UInt64 = 12
        var dataChunkSizeOffset: UInt64?
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            let chunkID = header.prefix(4)
            let declaredSize = UInt64(header.suffix(4).littleEndianUInt32)

            if chunkID == Data("data".utf8) {
                dataChunkSizeOffset = offset + 4
                break
            }
            // Chunks are word-aligned.
            offset += 8 + declaredSize + (declaredSize % 2)
        }

        guard let dataChunkSizeOffset else { return false }

        let dataStart = dataChunkSizeOffset + 4
        guard fileSize > dataStart else { return false }
        let actualDataSize = UInt32(fileSize - dataStart)
        let actualRIFFSize = UInt32(fileSize - 8)

        try handle.seek(toOffset: dataChunkSizeOffset)
        let declaredData = try handle.read(upToCount: 4)?.littleEndianUInt32 ?? 0
        try handle.seek(toOffset: 4)
        let declaredRIFF = try handle.read(upToCount: 4)?.littleEndianUInt32 ?? 0

        guard declaredData != actualDataSize || declaredRIFF != actualRIFFSize else { return false }

        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: actualRIFFSize.littleEndianData)
        try handle.seek(toOffset: dataChunkSizeOffset)
        try handle.write(contentsOf: actualDataSize.littleEndianData)
        return true
    }

    // MARK: - Compression

    /// Transcodes a WAV to M4A and removes the original. Recording stays on WAV so a crash
    /// leaves something repairable; this runs only once the meeting has ended cleanly.
    /// Returns the new URL, or nil when the transcode failed and the WAV was left in place.
    static func compressToM4A(_ url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        let output = url.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: output)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }

        do {
            try await export.export(to: output, as: .m4a)
        } catch {
            NSLog("MeetingScribe: audio compression failed — \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: output)
            return nil
        }

        guard FileManager.default.fileExists(atPath: output.path) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return output
    }
}

extension Data {
    /// Reads the first four bytes as a little-endian UInt32.
    var littleEndianUInt32: UInt32 {
        guard count >= 4 else { return 0 }
        let bytes = [UInt8](prefix(4))
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }
}

extension UInt32 {
    var littleEndianData: Data {
        Data([
            UInt8(self & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 24) & 0xFF),
        ])
    }
}

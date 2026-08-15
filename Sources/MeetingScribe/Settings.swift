import Foundation

/// User-facing preferences, persisted in UserDefaults and toggled from the menu bar.
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let autoRecord = "autoRecord"
        static let notifyOnStart = "notifyOnStart"
        static let keepAudio = "keepAudio"
        static let allowServerFallback = "allowServerFallback"
        static let useCalendarTitles = "useCalendarTitles"
        static let compressAudio = "compressAudio"
        static let speechLocale = "speechLocale"
        static let transcriptFolder = "transcriptFolder"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.autoRecord: true,
            Key.notifyOnStart: true,
            Key.keepAudio: true,
            Key.allowServerFallback: false,
            Key.useCalendarTitles: true,
            Key.compressAudio: true,
        ])
    }

    /// Convert the archived WAVs to M4A once the meeting ends, cutting roughly 230 MB/hour
    /// down to ~15 MB/hour. Recording still happens to WAV so a crash leaves recoverable
    /// audio; the compression is the last step.
    var compressAudio: Bool {
        get { defaults.bool(forKey: Key.compressAudio) }
        set { defaults.set(newValue, forKey: Key.compressAudio) }
    }

    /// Empty means "follow the system locale".
    var speechLocaleIdentifier: String? {
        get { defaults.string(forKey: Key.speechLocale) }
        set { defaults.set(newValue, forKey: Key.speechLocale) }
    }

    /// Title transcripts from the matching calendar event instead of the window title,
    /// and record who was invited. Falls back silently when access is not granted.
    var useCalendarTitles: Bool {
        get { defaults.bool(forKey: Key.useCalendarTitles) }
        set { defaults.set(newValue, forKey: Key.useCalendarTitles) }
    }

    /// Watch for Zoom/Meet/Teams windows and start recording without being asked.
    var autoRecord: Bool {
        get { defaults.bool(forKey: Key.autoRecord) }
        set { defaults.set(newValue, forKey: Key.autoRecord) }
    }

    /// Post a notification whenever a recording starts. Leave this on unless you
    /// have a specific reason not to — see the consent note in the README.
    var notifyOnStart: Bool {
        get { defaults.bool(forKey: Key.notifyOnStart) }
        set { defaults.set(newValue, forKey: Key.notifyOnStart) }
    }

    /// Keep the 16 kHz WAV files next to the transcript (~7 MB per hour per track).
    var keepAudio: Bool {
        get { defaults.bool(forKey: Key.keepAudio) }
        set { defaults.set(newValue, forKey: Key.keepAudio) }
    }

    /// If on-device speech models are unavailable, allow Apple's servers to do the
    /// recognition instead. Off by default: that would send meeting audio off the machine.
    var allowServerFallback: Bool {
        get { defaults.bool(forKey: Key.allowServerFallback) }
        set { defaults.set(newValue, forKey: Key.allowServerFallback) }
    }

    var transcriptRoot: URL {
        get {
            if let path = defaults.string(forKey: Key.transcriptFolder), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documents.appendingPathComponent("MeetingScribe", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.transcriptFolder) }
    }
}

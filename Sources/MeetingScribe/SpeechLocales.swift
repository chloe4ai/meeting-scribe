import Foundation
import Speech

/// The set of languages transcription can run in.
///
/// `Locale.current` is the wrong default for anyone who works in more than one language:
/// a Mac set to English will transcribe a Mandarin call into confident nonsense. This
/// exposes an explicit choice, restricted to locales that actually have an on-device model
/// installed, because the server fallback is off by default.
enum SpeechLocales {
    struct Option {
        let identifier: String
        let displayName: String
    }

    /// Building an `SFSpeechRecognizer` per locale is slow, so the probe result is cached.
    private static var cachedOnDevice: [Option]?

    /// Locales with an on-device model available right now, sorted by display name.
    static func onDeviceOptions() -> [Option] {
        if let cachedOnDevice { return cachedOnDevice }

        let options = SFSpeechRecognizer.supportedLocales()
            .compactMap { locale -> Option? in
                guard let recognizer = SFSpeechRecognizer(locale: locale),
                      recognizer.supportsOnDeviceRecognition else { return nil }
                return Option(identifier: locale.identifier, displayName: displayName(for: locale))
            }
            .sorted { $0.displayName < $1.displayName }

        cachedOnDevice = options
        return options
    }

    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Resolves the configured identifier to a locale, falling back to the system locale
    /// and then to en-US so transcription never fails outright over a stale setting.
    static func resolve(_ identifier: String?) -> Locale {
        if let identifier, !identifier.isEmpty {
            return Locale(identifier: identifier)
        }
        return Locale.current
    }

    static func supportsOnDevice(_ locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }
}

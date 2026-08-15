import Foundation
import ServiceManagement

/// Registers the app as a login item.
///
/// An app that only captures meetings while it happens to be running is not much use, so
/// this is the difference between "captures all my meetings" being true and being
/// aspirational. `SMAppService` needs the bundle to be code-signed and living somewhere
/// stable; an ad-hoc build run from a Downloads folder can legitimately fail, so callers
/// must surface the error rather than assume success.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Non-nil when macOS will refuse to register, with the reason.
    static var unavailableReason: String? {
        guard Bundle.main.bundleIdentifier != nil else {
            return "MeetingScribe must be run as an app bundle to launch at login."
        }
        if !Bundle.main.bundleURL.path.hasPrefix("/Applications") {
            return "Move MeetingScribe.app to /Applications, then try again — macOS only "
                + "registers login items from a stable location."
        }
        return nil
    }
}

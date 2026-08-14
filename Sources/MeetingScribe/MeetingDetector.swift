import Foundation
import CoreAudio
import ScreenCaptureKit

struct DetectedMeeting {
    let platform: String
    let title: String
}

/// Polls for an in-progress meeting by looking at on-screen windows (native clients and
/// browser tabs) and whether the default input device is actually hot.
///
/// Window enumeration goes through ScreenCaptureKit rather than `CGWindowListCopyWindowInfo`,
/// so there is exactly one permission to grant (Screen Recording) and no deprecated API.
final class MeetingDetector {
    var onStart: ((DetectedMeeting) -> Void)?
    var onEnd: (() -> Void)?
    /// Set when scanning fails because Screen Recording permission has not been granted.
    private(set) var permissionDenied = false

    private var pollTask: Task<Void, Never>?
    private var positiveTicks = 0
    private var negativeTicks = 0
    private var isActive = false

    private let pollInterval: Duration = .seconds(5)
    /// Two consecutive hits (~10s) before we start, so a tab that flashes past is ignored.
    private let startThreshold = 2
    /// Six consecutive misses (~30s) before we stop, so a reload or window swap doesn't cut a meeting in half.
    private let stopThreshold = 6

    private static let nativeApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
    ]

    private static let browsers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",   // Arc
        "company.thebrowser.dia",       // Dia
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        positiveTicks = 0
        negativeTicks = 0
        isActive = false
    }

    /// Called when a recording ends by other means (manual stop) so the detector does not
    /// immediately re-trigger on the still-open meeting window.
    func acknowledgeExternalStop() {
        isActive = true
    }

    private func tick() async {
        let meeting = await scan()

        if isActive {
            // Only the window signal decides when to stop. The mic is deliberately ignored
            // here: our own capture keeps it hot, which would otherwise never let us stop.
            if meeting == nil {
                negativeTicks += 1
                if negativeTicks >= stopThreshold {
                    isActive = false
                    negativeTicks = 0
                    positiveTicks = 0
                    await MainActor.run { self.onEnd?() }
                }
            } else {
                negativeTicks = 0
            }
            return
        }

        guard let meeting, microphoneIsInUse() else {
            positiveTicks = 0
            return
        }

        positiveTicks += 1
        guard positiveTicks >= startThreshold else { return }

        isActive = true
        positiveTicks = 0
        negativeTicks = 0
        await MainActor.run { self.onStart?(meeting) }
    }

    private func scan() async -> DetectedMeeting? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            permissionDenied = false
        } catch {
            permissionDenied = true
            return nil
        }

        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            let bundleID = app.bundleIdentifier
            let title = window.title ?? ""

            if let platform = Self.nativeApps[bundleID] {
                guard Self.nativeWindowLooksLikeMeeting(bundleID: bundleID, title: title) else { continue }
                return DetectedMeeting(platform: platform, title: title.isEmpty ? "\(platform) call" : title)
            }

            if Self.browsers.contains(bundleID), let platform = Self.browserPlatform(for: title) {
                return DetectedMeeting(platform: platform, title: Self.cleanBrowserTitle(title))
            }
        }
        return nil
    }

    /// Zoom and Teams keep background windows open all day, so their mere presence means nothing.
    static func nativeWindowLooksLikeMeeting(bundleID: String, title: String) -> Bool {
        if bundleID.hasPrefix("us.zoom") {
            return title.localizedCaseInsensitiveContains("zoom meeting")
                || title.localizedCaseInsensitiveContains("zoom webinar")
        }
        if bundleID.hasPrefix("com.microsoft.teams") {
            return title.localizedCaseInsensitiveContains("meeting")
                || title.localizedCaseInsensitiveContains("call")
        }
        if bundleID == "com.tinyspeck.slackmacgap" {
            return title.localizedCaseInsensitiveContains("huddle")
        }
        if bundleID == "com.hnc.Discord" {
            return title.localizedCaseInsensitiveContains("voice")
        }
        return true
    }

    /// Browser windows are titled "<tab title> - <browser>", so we match on the tab portion.
    static func browserPlatform(for title: String) -> String? {
        let lower = title.lowercased()
        if lower.contains("google meet") || lower.hasPrefix("meet - ") || lower.hasPrefix("meet – ")
            || lower.contains("meet.google.com") {
            return "Google Meet"
        }
        if lower.contains("zoom meeting") || lower.hasPrefix("launch meeting - zoom") {
            return "Zoom"
        }
        if lower.contains("microsoft teams") { return "Microsoft Teams" }
        if lower.contains("webex") { return "Webex" }
        if lower.contains("whereby") { return "Whereby" }
        return nil
    }

    static func cleanBrowserTitle(_ title: String) -> String {
        // Strip the trailing " - Google Chrome" / " — Safari" style browser suffix.
        for separator in [" - ", " — ", " – "] {
            if let range = title.range(of: separator, options: .backwards) {
                let head = String(title[..<range.lowerBound])
                if !head.isEmpty { return head }
            }
        }
        return title
    }

    /// True when something already has the default input device running — a strong signal
    /// that a call is live rather than a meeting tab merely sitting open.
    private func microphoneIsInUse() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &runningAddress, 0, nil, &runningSize, &running
        ) == noErr else { return false }

        return running != 0
    }
}

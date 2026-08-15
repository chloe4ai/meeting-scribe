import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let detector = MeetingDetector()
    private let settings = Settings.shared

    private var session: RecordingSession?
    private var isBusy = false
    private var tickTimer: Timer?
    private var snapshotTimer: Timer?

    private let statusMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let toggleMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
    private let pauseMenuItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "p")
    private let recentMenuItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
    private let autoRecordItem = NSMenuItem(title: "Auto-record meetings", action: #selector(toggleAutoRecord), keyEquivalent: "")
    private let notifyItem = NSMenuItem(title: "Notify when recording starts", action: #selector(toggleNotify), keyEquivalent: "")
    private let keepAudioItem = NSMenuItem(title: "Keep audio files", action: #selector(toggleKeepAudio), keyEquivalent: "")
    private let calendarItem = NSMenuItem(title: "Use calendar event titles", action: #selector(toggleCalendar), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        detector.onStart = { [weak self] meeting in
            guard let self, self.session == nil, self.settings.autoRecord else { return }
            Task { await self.beginRecording(meeting, isManual: false) }
        }
        detector.onEnd = { [weak self] in
            guard let self, let session = self.session, !session.isManual else { return }
            Task { await self.endRecording(reason: "Meeting ended") }
        }

        Task {
            await Notifier.requestAuthorization()
            if settings.useCalendarTitles {
                _ = await CalendarLookup.requestAccess()
            }
            do {
                try await AppleSpeechTranscriber.requestAuthorization()
            } catch {
                presentError(error)
            }
            detector.start()
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard session != nil else { return }
        // Finish the transcript rather than losing the meeting on quit.
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await endRecording(reason: "Quit")
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
    }

    // MARK: - Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false)

        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        for item in [toggleMenuItem, pauseMenuItem] {
            item.target = self
            menu.addItem(item)
        }

        let openItem = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openTranscripts), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        recentMenuItem.submenu = NSMenu()
        menu.addItem(recentMenuItem)
        menu.addItem(.separator())

        for item in [autoRecordItem, notifyItem, keepAudioItem, calendarItem, launchAtLoginItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let privacyItem = NSMenuItem(title: "Privacy Settings…", action: #selector(openPrivacySettings), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)

        let quitItem = NSMenuItem(title: "Quit MeetingScribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshUI()
    }

    /// Rebuild the dynamic parts only when the menu is actually opened.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildRecentTranscripts()
        refreshUI()
    }

    private func rebuildRecentTranscripts() {
        let submenu = NSMenu()
        let root = settings.transcriptRoot
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let folders = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .prefix(8)

        if folders.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for folder in folders {
                let item = NSMenuItem(title: folder.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = folder
                submenu.addItem(item)
            }
        }

        recentMenuItem.submenu = submenu
    }

    private func setIcon(recording: Bool) {
        let symbol = recording ? "record.circle.fill" : "waveform"
        let description = recording ? "MeetingScribe — recording" : "MeetingScribe — idle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func refreshUI() {
        autoRecordItem.state = settings.autoRecord ? .on : .off
        notifyItem.state = settings.notifyOnStart ? .on : .off
        keepAudioItem.state = settings.keepAudio ? .on : .off
        calendarItem.state = settings.useCalendarTitles ? .on : .off
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off

        if let session {
            let state = session.isPaused ? "Paused" : "Recording"
            statusMenuItem.title = "\(state): \(session.title) — \(TranscriptWriter.duration(session.elapsed))"
            toggleMenuItem.title = "Stop Recording"
            pauseMenuItem.title = session.isPaused ? "Resume Recording" : "Pause Recording"
            pauseMenuItem.isHidden = false
            // A visible, always-on indicator, independent of notification permission.
            statusItem.button?.title = session.isPaused ? " ‖" : " REC"
        } else if detector.permissionDenied {
            statusMenuItem.title = "Screen Recording permission needed"
            toggleMenuItem.title = "Start Recording"
            pauseMenuItem.isHidden = true
            statusItem.button?.title = ""
        } else {
            statusMenuItem.title = settings.autoRecord ? "Watching for meetings" : "Idle (auto-record off)"
            toggleMenuItem.title = "Start Recording"
            pauseMenuItem.isHidden = true
            statusItem.button?.title = ""
        }
        toggleMenuItem.isEnabled = !isBusy
    }

    // MARK: - Recording

    private func beginRecording(_ meeting: DetectedMeeting, isManual: Bool) async {
        guard session == nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false; refreshUI() }

        do {
            let session = try RecordingSession(meeting: meeting, isManual: isManual)
            session.onFailure = { [weak self] error in
                guard let self else { return }
                Task {
                    await self.endRecording(reason: "Capture stopped")
                    self.presentError(error)
                }
            }
            try await session.start()
            self.session = session
            setIcon(recording: true)

            startSnapshotTimer()

            if settings.notifyOnStart {
                Notifier.post(
                    title: "Recording this meeting",
                    body: "\(meeting.platform) — \(session.title)"
                )
            }
        } catch {
            presentError(error)
        }
    }

    private func endRecording(reason: String) async {
        guard let session, !isBusy else { return }
        isBusy = true
        self.session = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        defer { isBusy = false; refreshUI() }

        let directory = await session.stop()
        setIcon(recording: false)

        let count = session.segmentCount
        Notifier.post(
            title: "Transcript saved",
            body: count > 0
                ? "\(session.title) — \(count) lines · \(reason)"
                : "\(session.title) — no speech recognised · \(reason)"
        )
        NSLog("MeetingScribe: transcript written to \(directory.path)")
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        Task {
            if session != nil {
                detector.acknowledgeExternalStop()
                await endRecording(reason: "Stopped manually")
            } else {
                await beginRecording(
                    DetectedMeeting(platform: "Manual", title: "Manual recording"), isManual: true
                )
            }
        }
    }

    /// Flushes the transcript periodically so a crash mid-meeting doesn't lose it.
    /// Kept synchronous: scheduling a timer from an async context trips Sendable checking.
    private func startSnapshotTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.session?.writeSnapshot()
        }
    }

    @objc private func togglePause() {
        guard let session else { return }
        session.setPaused(!session.isPaused)
        refreshUI()
    }

    @objc private func openTranscripts() {
        let root = settings.transcriptRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        let transcript = folder.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: transcript.path) {
            NSWorkspace.shared.open(transcript)
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    @objc private func openPrivacySettings() {
        // Deep-links straight to the pane the app most often needs.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleAutoRecord() {
        settings.autoRecord.toggle()
        refreshUI()
    }

    @objc private func toggleNotify() {
        settings.notifyOnStart.toggle()
        refreshUI()
    }

    @objc private func toggleKeepAudio() {
        settings.keepAudio.toggle()
        refreshUI()
    }

    @objc private func toggleCalendar() {
        settings.useCalendarTitles.toggle()
        if settings.useCalendarTitles && !CalendarLookup.accessGranted {
            Task {
                let granted = await CalendarLookup.requestAccess()
                if !granted {
                    await MainActor.run {
                        self.settings.useCalendarTitles = false
                        self.refreshUI()
                        self.presentMessage(
                            "Calendar access was denied, so transcripts will keep using window "
                            + "titles. You can grant it under Privacy & Security › Calendars."
                        )
                    }
                }
            }
        }
        refreshUI()
    }

    @objc private func toggleLaunchAtLogin() {
        let target = !LaunchAtLogin.isEnabled
        if target, let reason = LaunchAtLogin.unavailableReason {
            presentMessage(reason)
            return
        }
        do {
            try LaunchAtLogin.setEnabled(target)
        } catch {
            presentMessage("Could not \(target ? "enable" : "disable") launch at login: \(error.localizedDescription)")
        }
        refreshUI()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentError(_ error: Error) {
        NSLog("MeetingScribe: \(error.localizedDescription)")
        presentMessage(error.localizedDescription)
    }

    private func presentMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "MeetingScribe"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

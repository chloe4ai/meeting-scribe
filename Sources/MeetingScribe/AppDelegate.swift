import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let detector = MeetingDetector()
    private let settings = Settings.shared

    private var session: RecordingSession?
    private var isBusy = false
    private var tickTimer: Timer?

    private let statusMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let toggleMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
    private let autoRecordItem = NSMenuItem(title: "Auto-record meetings", action: #selector(toggleAutoRecord), keyEquivalent: "")
    private let notifyItem = NSMenuItem(title: "Notify when recording starts", action: #selector(toggleNotify), keyEquivalent: "")
    private let keepAudioItem = NSMenuItem(title: "Keep audio files", action: #selector(toggleKeepAudio), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        detector.onStart = { [weak self] meeting in
            guard let self, self.session == nil, self.settings.autoRecord else { return }
            Task { await self.beginRecording(meeting) }
        }
        detector.onEnd = { [weak self] in
            guard let self, self.session != nil else { return }
            Task { await self.endRecording(reason: "Meeting ended") }
        }

        Task {
            await Notifier.requestAuthorization()
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
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        let openItem = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openTranscripts), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        for item in [autoRecordItem, notifyItem, keepAudioItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MeetingScribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshUI()
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

        if let session {
            statusMenuItem.title = "Recording \(session.meeting.platform) — \(TranscriptWriter.duration(session.elapsed))"
            toggleMenuItem.title = "Stop Recording"
            // A visible, always-on indicator, independent of notification permission.
            statusItem.button?.title = " REC"
        } else if detector.permissionDenied {
            statusMenuItem.title = "Screen Recording permission needed"
            toggleMenuItem.title = "Start Recording"
            statusItem.button?.title = ""
        } else {
            statusMenuItem.title = settings.autoRecord ? "Watching for meetings" : "Idle (auto-record off)"
            toggleMenuItem.title = "Start Recording"
            statusItem.button?.title = ""
        }
        toggleMenuItem.isEnabled = !isBusy
    }

    // MARK: - Recording

    private func beginRecording(_ meeting: DetectedMeeting) async {
        guard session == nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false; refreshUI() }

        do {
            let session = try RecordingSession(meeting: meeting)
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

            if settings.notifyOnStart {
                Notifier.post(
                    title: "Recording this meeting",
                    body: "\(meeting.platform) — \(meeting.title)"
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
        defer { isBusy = false; refreshUI() }

        let directory = await session.stop()
        setIcon(recording: false)

        let count = session.segmentCount
        Notifier.post(
            title: "Transcript saved",
            body: count > 0
                ? "\(session.meeting.title) — \(count) lines · \(reason)"
                : "\(session.meeting.title) — no speech recognised · \(reason)"
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
                await beginRecording(DetectedMeeting(platform: "Manual", title: "Manual recording"))
            }
        }
    }

    @objc private func openTranscripts() {
        let root = settings.transcriptRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentError(_ error: Error) {
        NSLog("MeetingScribe: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "MeetingScribe"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

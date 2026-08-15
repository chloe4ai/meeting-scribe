import AppKit

/// A plain search window over the saved transcripts.
///
/// Once there are a few dozen meetings on disk, "open the folder" stops being an answer.
/// Results are meeting title, timestamp, speaker and the matching line; opening a row
/// reveals the transcript.
final class SearchWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView!
    private var searchField: NSSearchField!
    private var statusLabel: NSTextField!
    private var hits: [SearchHit] = []

    private let root: () -> URL

    init(root: @escaping () -> URL) {
        self.root = root
    }

    func show() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Search Transcripts"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = NSView()
        window.contentView = content

        searchField = NSSearchField()
        searchField.placeholderString = "Search every transcript — use \"quotes\" for a phrase"
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.sendsSearchStringImmediately = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        statusLabel = NSTextField(labelWithString: "Type a query and press Return.")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        for (identifier, title, width) in [
            ("meeting", "Meeting", CGFloat(200)),
            ("time", "Time", CGFloat(70)),
            ("speaker", "Speaker", CGFloat(90)),
            ("line", "Line", CGFloat(340)),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        self.window = window
    }

    @objc private func runSearch() {
        let query = searchField.stringValue
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            hits = []
            statusLabel.stringValue = "Type a query and press Return."
            tableView.reloadData()
            return
        }

        hits = TranscriptIndex.search(query, in: root())
        tableView.reloadData()

        let meetings = Set(hits.map(\.folder)).count
        statusLabel.stringValue = hits.isEmpty
            ? "No matches."
            : "\(hits.count) line\(hits.count == 1 ? "" : "s") across \(meetings) meeting\(meetings == 1 ? "" : "s"). Double-click to open."
    }

    @objc private func openSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < hits.count else { return }
        let transcript = hits[row].folder.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: transcript.path) {
            NSWorkspace.shared.open(transcript)
        } else {
            NSWorkspace.shared.open(hits[row].folder)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < hits.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let hit = hits[row]

        let text: String
        switch identifier {
        case "meeting": text = hit.meetingTitle
        case "time": text = TranscriptWriter.timestamp(hit.start)
        case "speaker": text = hit.speaker
        default: text = hit.text
        }

        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

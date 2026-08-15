import Foundation

/// The on-disk JSON, read back for search and crash recovery.
struct TranscriptDocument: Decodable {
    struct Segment: Decodable {
        let start: TimeInterval
        let speaker: String
        let text: String
    }
    let title: String
    let platform: String
    let startedAt: Date
    let durationSeconds: TimeInterval
    let inProgress: Bool?
    let segments: [Segment]
}

struct SearchHit {
    let folder: URL
    let meetingTitle: String
    let meetingDate: Date
    let start: TimeInterval
    let speaker: String
    let text: String
}

/// Full-text search across saved transcripts.
///
/// Transcripts are small — a long meeting is a few hundred KB of JSON — so this reads them
/// on demand rather than maintaining an index that could drift out of sync with the folder.
enum TranscriptIndex {

    static func load(from root: URL) -> [(folder: URL, document: TranscriptDocument)] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return contents.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
                  let document = try? decoder.decode(TranscriptDocument.self, from: data)
            else { return nil }
            return (folder, document)
        }
    }

    static func search(_ query: String, in root: URL, limit: Int = 200) -> [SearchHit] {
        let tokens = self.tokens(from: query)
        guard !tokens.isEmpty else { return [] }

        let documents = load(from: root)
            .sorted { $0.document.startedAt > $1.document.startedAt }

        var hits: [SearchHit] = []
        for (folder, document) in documents {
            // A title match should surface the meeting even when no single line matches.
            let titleMatches = matches(document.title, tokens: tokens)

            for segment in document.segments where matches(segment.text, tokens: tokens) {
                hits.append(SearchHit(
                    folder: folder, meetingTitle: document.title, meetingDate: document.startedAt,
                    start: segment.start, speaker: segment.speaker, text: segment.text
                ))
                if hits.count >= limit { return hits }
            }

            if titleMatches && !hits.contains(where: { $0.folder == folder }) {
                hits.append(SearchHit(
                    folder: folder, meetingTitle: document.title, meetingDate: document.startedAt,
                    start: 0, speaker: "—", text: "(title match)"
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Whitespace-separated terms, quoted phrases kept intact.
    static func tokens(from query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in query {
            if character == "\"" {
                inQuotes.toggle()
                if !inQuotes, !current.isEmpty { tokens.append(current); current = "" }
            } else if character == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        return tokens.map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    /// All terms must be present — narrowing beats recall when you are looking for one line
    /// you half-remember.
    static func matches(_ text: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let haystack = text.lowercased()
        // Lowercase here too rather than trusting the caller: `tokens(from:)` already does
        // it, but a raw token passed in would otherwise silently never match.
        return tokens.allSatisfy { haystack.contains($0.lowercased()) }
    }
}

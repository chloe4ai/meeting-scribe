import Foundation

/// Pulls out lines that sound like commitments, as an index into the transcript.
///
/// This is deliberately a keyword heuristic, not a summary — there is no language model in
/// this app, and pretending otherwise would produce confident nonsense. The output is
/// labelled as "possible" in the transcript and every line keeps its timestamp so you can
/// jump to the real context.
enum ActionItems {
    private static let cues = [
        "i'll ", "i will ", "we'll ", "we will ", "i'm going to ", "we're going to ",
        "we need to ", "we should ", "you should ", "let's ",
        "action item", "follow up", "follow-up", "circle back", "take a look",
        "can you ", "could you ", "would you mind", "make sure",
        "send you", "send over", "i'll get", "by tomorrow", "by monday", "by tuesday",
        "by wednesday", "by thursday", "by friday", "next week", "end of week",
    ]

    static func extract(from segments: [TranscriptSegment], limit: Int = 12) -> [TranscriptSegment] {
        var found: [TranscriptSegment] = []

        for segment in segments {
            let lowered = segment.text.lowercased()
            let wordCount = segment.text.split(whereSeparator: { $0 == " " }).count

            // Very short lines are usually fragments ("we'll see"); very long ones are
            // usually the recogniser failing to find a sentence boundary.
            guard wordCount >= 5, wordCount <= 60 else { continue }
            guard cues.contains(where: { lowered.contains($0) }) else { continue }

            found.append(segment)
            if found.count >= limit { break }
        }

        return found
    }
}

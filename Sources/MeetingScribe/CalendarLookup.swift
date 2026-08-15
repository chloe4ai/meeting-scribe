import EventKit
import Foundation

struct CalendarMatch {
    let title: String
    let attendees: [String]
    let organizer: String?
}

/// Finds the calendar event a recording most likely belongs to.
///
/// Window titles are often useless — Google Meet gives you "Meet - abc-defg-hij" — so when
/// the user grants calendar access the transcript is titled from the event instead, and
/// gains an attendee list. Access is optional: everything degrades to the window title.
enum CalendarLookup {
    private static let store = EKEventStore()
    private(set) static var accessGranted = false

    static func requestAccess() async -> Bool {
        do {
            accessGranted = try await store.requestFullAccessToEvents()
        } catch {
            accessGranted = false
        }
        return accessGranted
    }

    static func match(at date: Date = Date()) -> CalendarMatch? {
        guard accessGranted else { return nil }

        // Meetings rarely start exactly on time, so consider anything overlapping ±15 minutes.
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-15 * 60),
            end: date.addingTimeInterval(15 * 60),
            calendars: nil
        )

        let candidates = store.events(matching: predicate).filter { event in
            !event.isAllDay
                && !(event.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                && event.status != .canceled
        }

        guard let best = candidates.max(by: { score(for: $0, at: date) < score(for: $1, at: date) }),
              score(for: best, at: date) > 0
        else { return nil }

        let attendees = (best.attendees ?? []).compactMap { participant -> String? in
            let name = participant.name?.trimmingCharacters(in: .whitespaces)
            return (name?.isEmpty == false) ? name : nil
        }

        return CalendarMatch(
            title: best.title.trimmingCharacters(in: .whitespaces),
            attendees: Array(Set(attendees)).sorted(),
            organizer: best.organizer?.name
        )
    }

    /// Ranks candidate events. Kept separate and pure so the heuristic is testable
    /// without a populated calendar.
    static func score(startDate: Date?, endDate: Date?, attendeeCount: Int, hasConferenceHint: Bool, at now: Date) -> Int {
        guard let startDate else { return 0 }
        var score = 0

        if let endDate, startDate <= now, now <= endDate {
            score += 100  // in progress right now — by far the strongest signal
        }

        // Prefer the event whose start is closest to now, falling off a point per minute.
        let minutesAway = abs(startDate.timeIntervalSince(now)) / 60
        score += max(0, 30 - Int(minutesAway))

        if attendeeCount > 0 { score += 15 }        // a solo block is probably not the call
        if hasConferenceHint { score += 20 }        // has a Zoom/Meet link attached

        return score
    }

    private static func score(for event: EKEvent, at now: Date) -> Int {
        score(
            startDate: event.startDate,
            endDate: event.endDate,
            attendeeCount: event.attendees?.count ?? 0,
            hasConferenceHint: hasConferenceHint(event),
            at: now
        )
    }

    private static func hasConferenceHint(_ event: EKEvent) -> Bool {
        let haystack = [event.location, event.notes, event.url?.absoluteString]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return ["zoom.us", "meet.google.com", "teams.microsoft", "webex.com", "whereby.com"]
            .contains { haystack.contains($0) }
    }
}

import XCTest
@testable import MeetingScribe

final class ActionItemTests: XCTestCase {

    private func segment(_ text: String, at start: TimeInterval = 0) -> TranscriptSegment {
        TranscriptSegment(source: .microphone, start: start, text: text)
    }

    func testCommitmentsAreFound() {
        let items = ActionItems.extract(from: [
            segment("I'll send over the revised deck tomorrow morning."),
            segment("We should probably revisit the pricing model first."),
            segment("Can you take a look at the migration plan this week?"),
        ])
        XCTAssertEqual(items.count, 3)
    }

    func testChitchatIsIgnored() {
        let items = ActionItems.extract(from: [
            segment("Yeah exactly."),
            segment("Good morning everyone how is it going today"),
            segment("The weather has been surprisingly nice this whole week honestly."),
        ])
        XCTAssertTrue(items.isEmpty)
    }

    func testFragmentsAndRamblesAreSkipped() {
        // Too short to be a real commitment.
        XCTAssertTrue(ActionItems.extract(from: [segment("I'll try.")]).isEmpty)
        // Too long: the recogniser failed to find a sentence boundary, so the line is not
        // a usable action item even though it contains a cue.
        let rambling = segment("i'll " + String(repeating: "word ", count: 80))
        XCTAssertTrue(ActionItems.extract(from: [rambling]).isEmpty)
    }

    func testResultsAreCappedAndKeepTimestamps() {
        let many = (0..<30).map { segment("I'll follow up on item number \($0) later today.", at: Double($0)) }
        let items = ActionItems.extract(from: many, limit: 12)
        XCTAssertEqual(items.count, 12)
        XCTAssertEqual(items.first?.start, 0)
        XCTAssertEqual(items.last?.start, 11)
    }
}

final class CalendarScoringTests: XCTestCase {

    func testInProgressEventBeatsUpcomingOne() {
        let now = Date()
        let inProgress = CalendarLookup.score(
            startDate: now.addingTimeInterval(-10 * 60), endDate: now.addingTimeInterval(20 * 60),
            attendeeCount: 3, hasConferenceHint: true, at: now
        )
        let upcoming = CalendarLookup.score(
            startDate: now.addingTimeInterval(12 * 60), endDate: now.addingTimeInterval(42 * 60),
            attendeeCount: 3, hasConferenceHint: true, at: now
        )
        XCTAssertGreaterThan(inProgress, upcoming)
    }

    func testMeetingWithLinkAndAttendeesBeatsSoloBlock() {
        let now = Date()
        let realMeeting = CalendarLookup.score(
            startDate: now, endDate: now.addingTimeInterval(30 * 60),
            attendeeCount: 4, hasConferenceHint: true, at: now
        )
        let focusBlock = CalendarLookup.score(
            startDate: now, endDate: now.addingTimeInterval(30 * 60),
            attendeeCount: 0, hasConferenceHint: false, at: now
        )
        XCTAssertGreaterThan(realMeeting, focusBlock)
    }

    func testEventWithoutStartScoresZero() {
        XCTAssertEqual(
            CalendarLookup.score(startDate: nil, endDate: nil, attendeeCount: 5,
                                 hasConferenceHint: true, at: Date()),
            0
        )
    }
}

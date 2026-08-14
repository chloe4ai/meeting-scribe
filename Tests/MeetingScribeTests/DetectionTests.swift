import XCTest
@testable import MeetingScribe

final class DetectionTests: XCTestCase {

    func testGoogleMeetTabIsDetected() {
        XCTAssertEqual(MeetingDetector.browserPlatform(for: "Meet - abc-defg-hij - Google Chrome"), "Google Meet")
        XCTAssertEqual(MeetingDetector.browserPlatform(for: "Meet – Weekly Sync"), "Google Meet")
        XCTAssertEqual(MeetingDetector.browserPlatform(for: "Google Meet — Safari"), "Google Meet")
    }

    func testUnrelatedTabsAreIgnored() {
        XCTAssertNil(MeetingDetector.browserPlatform(for: "Inbox (12) - Gmail - Google Chrome"))
        XCTAssertNil(MeetingDetector.browserPlatform(for: "GitHub - chloe4ai/meeting-scribe"))
        // "Meet" appearing mid-title must not trigger a recording.
        XCTAssertNil(MeetingDetector.browserPlatform(for: "Meet the team - Acme Careers - Google Chrome"))
    }

    func testOtherPlatformTabs() {
        XCTAssertEqual(MeetingDetector.browserPlatform(for: "Zoom Meeting - Google Chrome"), "Zoom")
        XCTAssertEqual(MeetingDetector.browserPlatform(for: "Microsoft Teams - Edge"), "Microsoft Teams")
        XCTAssertEqual(MeetingDetector.browserPlatform(for: "Webex | Standup"), "Webex")
    }

    func testIdleZoomWindowDoesNotCountAsMeeting() {
        // Zoom's launcher window sits open all day; only a live meeting window counts.
        XCTAssertFalse(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "Zoom"))
        XCTAssertFalse(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "Settings"))
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "us.zoom.xos", title: "Zoom Meeting"))
    }

    func testTeamsAndSlackWindows() {
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "com.microsoft.teams2", title: "Weekly Sync | Meeting"))
        XCTAssertFalse(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "com.microsoft.teams2", title: "Chat | Microsoft Teams"))
        XCTAssertTrue(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "com.tinyspeck.slackmacgap", title: "Huddle in #eng"))
        XCTAssertFalse(MeetingDetector.nativeWindowLooksLikeMeeting(bundleID: "com.tinyspeck.slackmacgap", title: "Slack | #general"))
    }

    func testBrowserSuffixIsStripped() {
        XCTAssertEqual(MeetingDetector.cleanBrowserTitle("Meet - abc-defg-hij - Google Chrome"), "Meet - abc-defg-hij")
        XCTAssertEqual(MeetingDetector.cleanBrowserTitle("Standup"), "Standup")
    }
}

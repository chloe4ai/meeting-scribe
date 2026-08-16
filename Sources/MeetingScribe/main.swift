import AppKit

// Diagnostic mode: run the transcription pipeline against a synthesised phrase and exit,
// without ever showing a menu bar item. Must be launched from inside the app bundle so the
// TCC grants apply:
//     /Applications/MeetingScribe.app/Contents/MacOS/MeetingScribe --self-test
if CommandLine.arguments.contains("--self-test") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    Task {
        exitCode = await SelfTest.run()
        semaphore.signal()
    }
    semaphore.wait()
    exit(exitCode)
}

let application = NSApplication.shared
// Top-level code runs on the main thread; assert that so the main-actor-isolated
// delegate can be constructed here.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = appDelegate
application.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
application.run()

import AppKit

// Diagnostic mode: run the transcription pipeline against a synthesised phrase and exit,
// without ever showing a menu bar item. Must be launched from inside the app bundle so the
// TCC grants apply:
//     /Applications/MeetingScribe.app/Contents/MacOS/MeetingScribe --self-test
if CommandLine.arguments.contains("--self-test") {
    let state = SelfTestRunState()
    Task {
        let code = await SelfTest.run()
        state.finish(code)
    }
    // Spin the run loop rather than blocking on a semaphore: SFSpeechRecognizer delivers
    // its results through the main queue, so a blocked main thread means the recognition
    // handler never fires and the test sees an empty transcript.
    while !state.isDone {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(state.exitCode)
}

let application = NSApplication.shared
// Top-level code runs on the main thread; assert that so the main-actor-isolated
// delegate can be constructed here.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = appDelegate
application.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
application.run()

import AppKit

// Single-instance check (avoid stacking duplicate modal Touch Bars)
let myPID = ProcessInfo.processInfo.processIdentifier
if let bundleID = Bundle.main.bundleIdentifier {
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != myPID }
    if !existing.isEmpty {
        fputs("TouchBarCockpit is already running (PID \(existing[0].processIdentifier)).\n", stderr)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

// Clean Ctrl+C / SIGTERM exit so Touch Bar cleanly dismisses back to macOS
signal(SIGINT) { _ in
    DispatchQueue.main.async { NSApp.terminate(nil) }
}
signal(SIGTERM) { _ in
    DispatchQueue.main.async { NSApp.terminate(nil) }
}

app.run()

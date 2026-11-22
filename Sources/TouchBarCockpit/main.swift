import AppKit

// Fast-path CLI trigger: `TouchBarCockpit --flash [agentName]`
// Posts a zero-polling DistributedNotification to the running daemon and exits in ~4ms.
if let flashIdx = CommandLine.arguments.firstIndex(of: "--flash") {
    let agent = (flashIdx + 1 < CommandLine.arguments.count) ? CommandLine.arguments[flashIdx + 1] : "Agent"
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.mebin.touchbarcockpit.agentReady"),
        object: agent,
        userInfo: nil,
        deliverImmediately: true
    )
    exit(0)
}

// Utility CLI to render crisp 2x Retina preview screenshots for documentation
if let shotIdx = CommandLine.arguments.firstIndex(of: "--render-screenshots") {
    let dir = (shotIdx + 1 < CommandLine.arguments.count) ? CommandLine.arguments[shotIdx + 1] : "docs/screenshots"
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    CockpitView.renderPreviewScreenshots(to: dir)
    exit(0)
}

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

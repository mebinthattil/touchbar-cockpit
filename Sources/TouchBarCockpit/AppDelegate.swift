import AppKit
import CoreGraphics
import CPrivateAPIs

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let touchBarController = TouchBarController()
    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let thermalSampler = ThermalSampler()
    private let powerSampler = PowerSampler()
    private let networkSampler = NetworkSampler()
    private let audioSpectrumTap = AudioSpectrumTap()

    private var metrics = SystemMetrics()
    private var telemetryTimer: Timer?
    private var fnFallbackPollTimer: Timer?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var fnCurrentlyDown: Bool = false
    private var fnDownTimestamp: TimeInterval = 0
    private var fnComboUsed: Bool = false
    private var tickCount: Int = 0
    private var isPaused: Bool = false
    private var isScreenAsleep: Bool = false

    // Status Bar Menu
    private var statusItem: NSStatusItem!
    private var summaryMenuItem: NSMenuItem!
    private var accessibilityMenuItem: NSMenuItem!
    private var keepAwakeMenuItem: NSMenuItem!
    private var pauseMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        metrics.eCoreCount = cpuSampler.eCoreCount
        setupStatusBar()
        setupCallbacks()
        setupSystemObservers()
        setupFnKeyMonitor()
        setupAgentNotificationObserver()

        audioSpectrumTap.onUpdate = { [weak self] bands, isActive in
            self?.touchBarController.updateWaveform(bands: bands, isActive: isActive)
        }

        // Initial sample + present Touch Bar
        sampleMetrics(includeSlowSensors: true)
        touchBarController.present()

        startTelemetryTimer()
    }

    private func startTelemetryTimer() {
        telemetryTimer?.invalidate()
        // 1 Hz coalesced telemetry loop (tolerance lets macOS align wakeups with system ticks)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused, !self.isScreenAsleep else { return }
            self.tickCount += 1
            self.sampleMetrics(includeSlowSensors: self.tickCount % 2 == 0)
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        telemetryTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        telemetryTimer?.invalidate()
        fnFallbackPollTimer?.invalidate()
        audioSpectrumTap.stop()
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        DistributedNotificationCenter.default().removeObserver(self)
        KeepAwakeManager.shared.disable()
        touchBarController.dismiss()
    }

    // MARK: - Telemetry Sampling
    private func sampleMetrics(includeSlowSensors: Bool) {
        let cpu = cpuSampler.sample()
        let mem = memorySampler.sample()
        let pwr = powerSampler.sample()
        let net = networkSampler.sample()

        metrics.cpuTotal = cpu.total
        metrics.cpuUser = cpu.user
        metrics.cpuSystem = cpu.system
        metrics.coreLoads = cpu.perCore
        metrics.cpuHistory.append(cpu.total)
        if metrics.cpuHistory.count > 48 {
            metrics.cpuHistory.removeFirst(metrics.cpuHistory.count - 48)
        }

        metrics.memUsedGB = mem.usedGB
        metrics.memTotalGB = mem.totalGB
        metrics.memActiveFrac = mem.activeFrac
        metrics.memWiredFrac = mem.wiredFrac
        metrics.memCompressedFrac = mem.compressedFrac
        metrics.swapUsedGB = mem.swapUsedGB

        metrics.powerWatts = pwr.systemDrawWatts
        metrics.chargerInWatts = pwr.chargerInWatts
        metrics.batteryNetWatts = pwr.batteryNetWatts
        metrics.adapterMaxWatts = pwr.adapterMaxWatts
        metrics.batteryPercent = pwr.batteryPercent
        metrics.isPluggedIn = pwr.isPluggedIn
        metrics.isCharging = pwr.isCharging
        metrics.minutesRemaining = pwr.minutesRemaining

        metrics.netDownBps = net.downBps
        metrics.netUpBps = net.upBps
        metrics.netDownHistory.append(net.downBps)
        metrics.netUpHistory.append(net.upBps)
        if metrics.netDownHistory.count > 36 {
            metrics.netDownHistory.removeFirst(metrics.netDownHistory.count - 36)
        }
        if metrics.netUpHistory.count > 36 {
            metrics.netUpHistory.removeFirst(metrics.netUpHistory.count - 36)
        }
        metrics.tailscaleActive = net.tailscaleActive
        metrics.vpnActive = net.vpnActive
        metrics.proxyActive = net.proxyActive

        if includeSlowSensors {
            let th = thermalSampler.sample()
            metrics.socTempC = th.socTempC
            metrics.socPeakTempC = th.socPeakTempC
            metrics.fanAvailable = th.fanAvailable
            metrics.fanRPM = th.fanRPM
            metrics.fanMaxRPM = th.fanMaxRPM
        }

        metrics.keepAwakeActive = KeepAwakeManager.shared.isActive
        metrics.timestamp = Date()

        touchBarController.update(metrics: metrics)
        if !isPaused && !isScreenAsleep && (tickCount % 2 == 0 || audioSpectrumTap.isAudioActive) {
            audioSpectrumTap.checkOutputActivity()
        }
    }

    // MARK: - Single-Tap Fn Toggle Monitor (100% Event-Driven: 0 Wakeups/sec when Accessibility is active!)
    private func setupFnKeyMonitor() {
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let fnDown = event.modifierFlags.contains(.function)
            let otherMods = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            self?.processFnState(fnDown: fnDown, otherModsDown: otherMods)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let fnDown = event.modifierFlags.contains(.function)
            let otherMods = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            self?.processFnState(fnDown: fnDown, otherModsDown: otherMods)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            if self?.fnCurrentlyDown == true {
                self?.fnComboUsed = true
            }
        }

        // Only enable fallback polling if Accessibility isn't granted yet;
        // once granted, NSEvent global flagsChanged is 100% event-driven (0 idle wakeups!).
        updateFnFallbackPolling()
    }

    private func updateFnFallbackPolling() {
        if TBIsAccessibilityTrusted(false) {
            fnFallbackPollTimer?.invalidate()
            fnFallbackPollTimer = nil
        } else if fnFallbackPollTimer == nil {
            let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                guard let self = self, !self.isScreenAsleep else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                let fnDown = flags.contains(.maskSecondaryFn)
                let otherMods = !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
                self.processFnState(fnDown: fnDown, otherModsDown: otherMods)
            }
            timer.tolerance = 0.015
            RunLoop.main.add(timer, forMode: .common)
            fnFallbackPollTimer = timer
        }
    }

    private func processFnState(fnDown: Bool, otherModsDown: Bool) {
        let apply = { [weak self] in
            guard let self = self else { return }
            let now = ProcessInfo.processInfo.systemUptime

            if fnDown {
                if !self.fnCurrentlyDown {
                    self.fnCurrentlyDown = true
                    self.fnDownTimestamp = now
                    self.fnComboUsed = otherModsDown
                } else if otherModsDown {
                    self.fnComboUsed = true
                }
            } else if self.fnCurrentlyDown {
                // Clean solo Fn tap (< 0.45s, no combo) -> Pause (restore native macOS bar) / Resume Cockpit
                self.fnCurrentlyDown = false
                let heldDuration = now - self.fnDownTimestamp
                if !self.fnComboUsed && heldDuration < 0.45 {
                    self.togglePause()
                }
                self.fnComboUsed = false
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    // MARK: - Coding Agent Turn-Complete Notification (Zero-Polling DistributedNotificationCenter)
    private func setupAgentNotificationObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAgentReadyNotification(_:)),
            name: Notification.Name("com.mebin.touchbarcockpit.agentReady"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleAgentReadyNotification(_ notification: Notification) {
        guard !isPaused, !isScreenAsleep else { return }
        let agent = (notification.object as? String) ?? "Agent"
        DispatchQueue.main.async { [weak self] in
            self?.touchBarController.triggerAgentFlash(agent: agent)
        }
    }

    // MARK: - Callbacks & Sleep/Wake Resilience
    private func setupCallbacks() {
        touchBarController.cockpitView.onToggleKeepAwake = { [weak self] in
            self?.toggleKeepAwake()
        }
    }

    private func setupSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let reattachSelector = #selector(handleSystemWake)

        ws.addObserver(self, selector: #selector(handleSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: reattachSelector, name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: reattachSelector, name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: reattachSelector, name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: reattachSelector, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func handleSystemSleep() {
        isScreenAsleep = true
        telemetryTimer?.invalidate()
        telemetryTimer = nil
        audioSpectrumTap.stop()
    }

    @objc private func handleSystemWake() {
        isScreenAsleep = false
        if !isPaused && telemetryTimer == nil {
            startTelemetryTimer()
        }
        guard !isPaused else { return }
        // Re-present slightly after wake so TouchBarServer is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.touchBarController.reattach()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.touchBarController.reattach()
        }
    }

    // MARK: - Minimal Menu Bar Control
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "TouchBarCockpit")
            img?.isTemplate = true
            btn.image = img
        }

        let menu = NSMenu()
        menu.delegate = self

        summaryMenuItem = NSMenuItem(title: "TouchBarCockpit", action: nil, keyEquivalent: "")
        summaryMenuItem.isEnabled = false
        menu.addItem(summaryMenuItem)
        menu.addItem(.separator())

        let hintItem = NSMenuItem(title: "2F: Vol · 3F: Bright · Long-Press: Media · Tap Fn: Pause/Resume", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())

        accessibilityMenuItem = NSMenuItem(title: "Enable macOS HUD Popup (Accessibility)...", action: #selector(requestAccessibility), keyEquivalent: "")
        accessibilityMenuItem.target = self
        menu.addItem(accessibilityMenuItem)
        updateAccessibilityMenuItem()

        keepAwakeMenuItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwakeMenuItem.target = self
        menu.addItem(keepAwakeMenuItem)

        pauseMenuItem = NSMenuItem(title: "Pause (Restore Native Bar)", action: #selector(togglePause), keyEquivalent: "")
        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)

        let reattachItem = NSMenuItem(title: "Re-attach Touch Bar", action: #selector(reattachNow), keyEquivalent: "r")
        reattachItem.target = self
        menu.addItem(reattachItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TouchBarCockpit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate (Update menu items only when actually opened — zero idle churn)
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuSummary()
        updateFnFallbackPolling()
    }

    private func updateMenuSummary() {
        let tempStr = metrics.socTempC > 0 ? String(format: "%.0f°C", metrics.socTempC) : "--°C"
        let pwrStr = metrics.isPluggedIn
            ? String(format: "Draw %.1fW / In %.1fW", metrics.powerWatts, metrics.chargerInWatts)
            : String(format: "Draw %.1fW", metrics.powerWatts)
        summaryMenuItem.title = String(
            format: "CPU %.0f%% · RAM %.1fG · %@ · %@",
            metrics.cpuTotal, metrics.memUsedGB, tempStr, pwrStr
        )
        keepAwakeMenuItem.state = KeepAwakeManager.shared.isActive ? .on : .off
        updateAccessibilityMenuItem()
    }

    private func updateAccessibilityMenuItem() {
        let trusted = TBIsAccessibilityTrusted(false)
        if trusted {
            accessibilityMenuItem.title = "macOS Main-Display HUD: Active ✓"
            accessibilityMenuItem.isEnabled = false
        } else {
            accessibilityMenuItem.title = "Enable macOS HUD Popup (Grant Accessibility)..."
            accessibilityMenuItem.isEnabled = true
        }
    }

    @objc private func requestAccessibility() {
        _ = TBIsAccessibilityTrusted(true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleKeepAwake() {
        let active = KeepAwakeManager.shared.toggle()
        metrics.keepAwakeActive = active
        keepAwakeMenuItem.state = active ? .on : .off
        touchBarController.update(metrics: metrics)
        touchBarController.cockpitView.showTransientToast(
            title: "KEEP AWAKE",
            detail: active ? "Display sleep prevented (☕ Active)" : "Normal sleep restored",
            accent: active ? NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.22, alpha: 1.0) : NSColor.systemGray,
            duration: 1.8
        )
    }

    @objc private func togglePause() {
        isPaused.toggle()
        if isPaused {
            telemetryTimer?.invalidate()
            telemetryTimer = nil
            audioSpectrumTap.stop()
            touchBarController.dismiss()
            pauseMenuItem.title = "Resume Cockpit"
        } else {
            touchBarController.present()
            sampleMetrics(includeSlowSensors: true)
            startTelemetryTimer()
            audioSpectrumTap.checkOutputActivity()
            pauseMenuItem.title = "Pause (Restore Native Bar)"
        }
    }

    @objc private func reattachNow() {
        isPaused = false
        pauseMenuItem.title = "Pause (Restore Native Bar)"
        touchBarController.present()
        if telemetryTimer == nil {
            startTelemetryTimer()
        }
        audioSpectrumTap.checkOutputActivity()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

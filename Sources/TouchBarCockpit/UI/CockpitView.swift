import AppKit
import CPrivateAPIs

final class CockpitView: NSView {
    // MARK: - State
    private var metrics = SystemMetrics()

    private enum InspectorKind {
        case cpu
        case ram
        case thermal
        case power
        case network
    }

    private enum ActiveHUD {
        case none
        case volume(value: Float, muted: Bool)
        case brightness(value: Float)
        case infoToast(title: String, detail: String, accent: NSColor)
        case inspector(InspectorKind)
        case media
        case agentFlash(agent: String, startTime: CFAbsoluteTime)
    }

    private var activeHUD: ActiveHUD = .none
    private var hudDismissTimer: Timer?
    private var flashAnimTimer: Timer?

    // MARK: - Expanded Inspector State
    private var topCPUProcesses: [(name: String, pct: Double)] = []
    private var topRAMProcesses: [(name: String, mb: Double)] = []
    private var isFetchingTopProcesses: Bool = false
    private var inspectorTickCount: Int = 0

    // MARK: - Media Overlay State
    private var mediaState = NowPlayingState()
    private var mediaTickTimer: Timer?
    private var mediaOverlayStartTime: CFAbsoluteTime = 0
    private var mediaMarqueeTickCount: Int = 0
    private var isMediaOverlayPinned: Bool = false
    private var mediaPressedButton: MediaButton? = nil
    private var isScrubbingMedia: Bool = false
    private var scrubPreviewFraction: CGFloat = 0
    private var jogNormalizedOffset: CGFloat = 0 // -1.0 ... +1.0 for universal jog scrubber
    private var jogAccumulatedSec: Int = 0

    private enum MediaButton {
        case prev, playPause, next, skipBack, skipFwd, close
    }

    // MARK: - Multi-Touch Gesture State
    private struct SliderTrackState {
        var touchXByID: [AnyHashable: CGFloat]
        var visualValue: Float            // Continuous 0.0...1.0 for pixel-smooth 60 FPS Touch Bar fill
        var stepCreditPx: CGFloat = 0     // Sub-step credit with reversal hysteresis
        var lastStepDir: Int = 0          // -1, 0, +1 for reversal deadband
        var settleUntil: TimeInterval = 0 // Brief settle window after finger-count change
        var isAccessibilityTrusted: Bool
    }

    private enum GestureMode {
        case idle
        case pendingTap(startPoint: NSPoint, startTime: TimeInterval)
        case longPressConsumed
        case mediaButtonTap(button: MediaButton)
        case mediaScrubbing
        case mediaJogScrubbing(startX: CGFloat, lastStep: Int)
        case twoFingerPending(startX: CGFloat, startTime: TimeInterval, startVolume: Float)
        case volumeSlide(SliderTrackState)
        case brightnessSlide(SliderTrackState)
    }

    private var gestureMode: GestureMode = .idle
    private var peakTouchCount: Int = 0
    private var longPressWorkItem: DispatchWorkItem?
    private var sliderSyncWorkItem: DispatchWorkItem?
    private var sliderEaseTimer: Timer?

    // Live Audio Waveform State (Dynamic Island style in Clock slot)
    private var waveformBands: [Float] = Array(repeating: 0, count: AudioSpectrumTap.bandCount)
    private var isAudioPlaying: Bool = false

    // Persistent Coding Agent Waiting Banner (replaces M2 Thermal slot after 3s amber flash until terminal focused)
    private var waitingAgentName: String? = nil

    // Callbacks
    var onFocusTerminal: (() -> Void)?

    // Cached Formatters & Symbol Images (eliminates repeated ICU / bitmap allocations per frame)
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "h:mm:ss"
        return df
    }()

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "a · EEE d"
        return df
    }()

    private static let waveformPalette: [NSColor] = [
        NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 1.0),
        NSColor(calibratedRed: 0.13, green: 0.83, blue: 0.93, alpha: 1.0),
        NSColor(calibratedRed: 0.18, green: 0.84, blue: 0.75, alpha: 1.0),
        NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.58, alpha: 1.0),
        NSColor(calibratedRed: 0.38, green: 0.65, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.65, green: 0.54, blue: 0.98, alpha: 1.0)
    ]

    private var tintedSymbolCache: [String: NSImage] = [:]
    private static var fontCache: [String: NSFont] = [:]

    private static func cachedFont(size: CGFloat, weight: NSFont.Weight, mono: Bool) -> NSFont {
        let key = "\(size)|\(weight.rawValue)|\(mono ? 1 : 0)"
        if let hit = fontCache[key] { return hit }
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        fontCache[key] = font
        return font
    }

    // Callbacks
    var onToggleKeepAwake: (() -> Void)?
    var onOpenFanControl: (() -> Void)?

    // MARK: - Init
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.direct]
        wantsRestingTouches = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    // MARK: - Public Updates
    func update(metrics: SystemMetrics) {
        self.metrics = metrics
        // Redraw live 1 Hz cockpit OR open Expanded Inspector; skip when Media/Slider/Flash covers it
        switch activeHUD {
        case .none:
            needsDisplay = true
        case .inspector(let kind):
            inspectorTickCount += 1
            if inspectorTickCount % 2 == 0 {
                if kind == .cpu {
                    refreshTopProcesses(isCPU: true)
                } else if kind == .ram {
                    refreshTopProcesses(isCPU: false)
                }
            }
            needsDisplay = true
        default:
            break
        }
    }

    func updateWaveform(bands: [Float], isActive: Bool) {
        let stateChanged = (self.isAudioPlaying != isActive)
        self.waveformBands = bands
        self.isAudioPlaying = isActive
        // Fast-path: only dirty the tiny 85x30pt waveform slot when cockpit is visible!
        if case .none = activeHUD {
            setNeedsDisplay(panelRects(for: bounds).clock)
        } else if case .media = activeHUD, stateChanged {
            // Immediately reflect on-screen play/pause in the Media Overlay!
            if mediaState.source == .universal {
                mediaState.isPlaying = isActive
                needsDisplay = true
            } else {
                MediaController.shared.fetchNowPlaying { [weak self] state in
                    self?.applyExternalMediaState(state)
                }
            }
        }
    }

    func showTransientToast(title: String, detail: String, accent: NSColor = .systemCyan, duration: TimeInterval = 3.0) {
        activeHUD = .infoToast(title: title, detail: detail, accent: accent)
        scheduleHUDDismiss(after: duration)
        needsDisplay = true
    }

    private func scheduleHUDDismiss(after seconds: TimeInterval) {
        hudDismissTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.dismissActiveHUD()
        }
        RunLoop.main.add(timer, forMode: .common)
        hudDismissTimer = timer
    }

    private func cancelLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }

    private func cancelSliderSyncAndEase() {
        sliderSyncWorkItem?.cancel()
        sliderSyncWorkItem = nil
        sliderEaseTimer?.invalidate()
        sliderEaseTimer = nil
    }

    private func dismissActiveHUD() {
        hudDismissTimer?.invalidate()
        hudDismissTimer = nil
        mediaTickTimer?.invalidate()
        mediaTickTimer = nil
        flashAnimTimer?.invalidate()
        flashAnimTimer = nil
        cancelSliderSyncAndEase()
        mediaPressedButton = nil
        isScrubbingMedia = false
        isMediaOverlayPinned = false
        activeHUD = .none
        needsDisplay = true
    }

    private func resetMediaAutoDismissIfNeeded() {
        if isMediaOverlayPinned {
            hudDismissTimer?.invalidate()
            hudDismissTimer = nil
        } else {
            scheduleHUDDismiss(after: 10.0)
        }
    }

    /// Gently glows the entire Touch Bar warm amber for a full 3.2s when a coding agent finishes its turn,
    /// then leaves a persistent amber "Agent Waiting" pill in the M2 Temp slot until a terminal is focused.
    func triggerAgentFlash(agent: String) {
        waitingAgentName = agent

        // Don't interrupt an active drag/gesture; still set the persistent badge in M2 Temp slot
        if case .volumeSlide = gestureMode { needsDisplay = true; return }
        if case .brightnessSlide = gestureMode { needsDisplay = true; return }
        if case .mediaScrubbing = gestureMode { needsDisplay = true; return }

        let wasMediaPinned = (isMediaOverlayPinned && {
            if case .media = activeHUD { return true }
            return false
        }())
        let previousInspector: InspectorKind? = {
            if case .inspector(let kind) = activeHUD { return kind }
            return nil
        }()

        hudDismissTimer?.invalidate()
        mediaTickTimer?.invalidate()
        flashAnimTimer?.invalidate()

        let start = CFAbsoluteTimeGetCurrent()
        activeHUD = .agentFlash(agent: agent, startTime: start)
        needsDisplay = true

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard case .agentFlash(_, let t0) = self.activeHUD else {
                self.flashAnimTimer?.invalidate()
                self.flashAnimTimer = nil
                return
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            if elapsed >= 3.2 {
                self.flashAnimTimer?.invalidate()
                self.flashAnimTimer = nil
                if wasMediaPinned {
                    self.activeHUD = .media
                    self.isMediaOverlayPinned = true
                    self.configureMediaTickTimer()
                    self.needsDisplay = true
                } else if let kind = previousInspector {
                    self.openInspector(kind)
                } else {
                    self.dismissActiveHUD()
                }
            } else {
                self.needsDisplay = true
            }
        }
        timer.tolerance = 0.008
        RunLoop.main.add(timer, forMode: .common)
        flashAnimTimer = timer
    }

    func clearWaitingAgent() {
        guard waitingAgentName != nil else { return }
        waitingAgentName = nil
        if case .agentFlash = activeHUD {
            dismissActiveHUD()
        } else {
            needsDisplay = true
        }
    }

    func applyExternalMediaState(_ state: NowPlayingState) {
        var next = state
        // For browser/universal players (Zen YouTube, Chrome, IINA), sync live Play/Pause icon from real audio signal
        if next.source == .universal {
            next.isPlaying = isAudioPlaying
        }
        let trackChanged = (next.title != mediaState.title || next.artist != mediaState.artist || next.appBundleID != mediaState.appBundleID)
        mediaState = next
        if trackChanged {
            mediaOverlayStartTime = CFAbsoluteTimeGetCurrent()
        }
        if case .media = activeHUD {
            configureMediaTickTimer()
            needsDisplay = true
        }
    }

    private func openMediaOverlay(togglePlayback: Bool, pinned: Bool) {
        cancelLongPress()
        // Immediately purge stale state if the previous player app was quit!
        MediaController.shared.invalidateIfClosed()
        mediaState = MediaController.shared.lastState
        activeHUD = .media
        isMediaOverlayPinned = pinned
        mediaPressedButton = nil
        isScrubbingMedia = false
        jogNormalizedOffset = 0
        jogAccumulatedSec = 0
        mediaOverlayStartTime = CFAbsoluteTimeGetCurrent()
        mediaMarqueeTickCount = 0
        needsDisplay = true
        resetMediaAutoDismissIfNeeded()

        let onState: (NowPlayingState) -> Void = { [weak self] state in
            self?.applyExternalMediaState(state)
        }

        if togglePlayback {
            MediaController.shared.togglePlayPause(completion: onState)
        } else {
            MediaController.shared.fetchNowPlaying(completion: onState)
        }

        configureMediaTickTimer()
    }

    /// Runs 30 FPS partial-rect marquee scrolling ONLY when Media Overlay is open AND text overflows;
    /// otherwise ticks gently at 2 Hz for the elapsed timestamp (and stops completely on dismiss).
    private func configureMediaTickTimer() {
        mediaTickTimer?.invalidate()
        let needsMarquee = mediaNeedsMarquee()
        let interval: TimeInterval = needsMarquee ? (1.0 / 30.0) : 0.5
        let metadataRefreshEvery = needsMarquee ? 30 : 2 // Sync Play/Pause, position & track every 1s while overlay is open
        let tick = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, case .media = self.activeHUD else { return }
            if self.isScrubbingMedia { return }
            self.mediaMarqueeTickCount += 1

            // Keep track title, album cover, player switch, and duration live while Media Overlay is open
            if self.mediaMarqueeTickCount % metadataRefreshEvery == 0 {
                MediaController.shared.fetchNowPlaying { [weak self] state in
                    self?.applyExternalMediaState(state)
                }
            }

            if needsMarquee {
                // Redraw only the text meta rect at 30 FPS; full redraw every ~0.5s for elapsed timestamp
                if self.mediaMarqueeTickCount % 15 == 0 {
                    self.needsDisplay = true
                } else {
                    self.setNeedsDisplay(self.mediaOverlayRects(for: self.bounds).meta)
                }
            } else {
                self.needsDisplay = true
            }
        }
        tick.tolerance = needsMarquee ? 0.008 : 0.08
        RunLoop.main.add(tick, forMode: .common)
        mediaTickTimer = tick
    }

    private func mediaNeedsMarquee() -> Bool {
        let r = mediaOverlayRects(for: bounds)
        let textW = mediaTextClipRect(metaRect: r.meta).width
        let titleW = measureTextWidth(mediaState.title, size: 10.5, weight: .semibold)
        let subW = measureTextWidth(mediaSubtitleText(), size: 8.5, weight: .medium)
        return titleW > textW || subW > textW
    }

    // MARK: - Multi-Touch Handling (Pure Eyes-Free Volume, Brightness & Long-Press Media)
    override func touchesBegan(with event: NSEvent) {
        let active = Array(event.touches(matching: .touching, in: self))
        let count = active.count
        peakTouchCount = max(peakTouchCount, count)
        let now = ProcessInfo.processInfo.systemUptime

        // Any multi-finger touch cancels single-finger long press immediately
        if count >= 2 {
            cancelLongPress()
        }

        if count == 1 {
            let pt = active[0].location(in: self)

            // If Volume or Brightness slider HUD is already open, 1 finger immediately grabs it for fine control!
            if case .volume(let displayedVol, _) = activeHUD {
                hudDismissTimer?.invalidate()
                let hadPendingSync = (sliderSyncWorkItem != nil || sliderEaseTimer != nil)
                cancelSliderSyncAndEase()
                let startVol = hadPendingSync ? displayedVol : AudioController.shared.getVolume()
                gestureMode = .volumeSlide(makeSliderState(touches: active, initialValue: startVol, now: now))
                return
            }
            if case .brightness(let displayedBright) = activeHUD {
                hudDismissTimer?.invalidate()
                let hadPendingSync = (sliderSyncWorkItem != nil || sliderEaseTimer != nil)
                cancelSliderSyncAndEase()
                let startBright = hadPendingSync ? displayedBright : BrightnessController.shared.getDisplayBrightness()
                gestureMode = .brightnessSlide(makeSliderState(touches: active, initialValue: startBright, now: now))
                return
            }

            // If Media Overlay is currently open, route 1-finger touches directly to Media controls / scrubber
            if case .media = activeHUD {
                let mRects = mediaOverlayRects(for: bounds)
                resetMediaAutoDismissIfNeeded()

                if mRects.prev.contains(pt) {
                    mediaPressedButton = .prev
                    gestureMode = .mediaButtonTap(button: .prev)
                    needsDisplay = true
                    return
                } else if mRects.playPause.contains(pt) {
                    mediaPressedButton = .playPause
                    gestureMode = .mediaButtonTap(button: .playPause)
                    needsDisplay = true
                    return
                } else if mRects.next.contains(pt) {
                    mediaPressedButton = .next
                    gestureMode = .mediaButtonTap(button: .next)
                    needsDisplay = true
                    return
                } else if mRects.close.contains(pt) {
                    mediaPressedButton = .close
                    gestureMode = .mediaButtonTap(button: .close)
                    needsDisplay = true
                    return
                } else if mediaState.canSeek && mediaState.duration > 0 {
                    if mRects.scrubberHit.contains(pt) {
                        isScrubbingMedia = true
                        scrubPreviewFraction = scrubFraction(forX: pt.x, trackRect: mRects.scrubberTrack)
                        gestureMode = .mediaScrubbing
                        hudDismissTimer?.invalidate()
                        needsDisplay = true
                        return
                    }
                } else {
                    // Universal scrub controls (-10s, Jog Scrubber, +10s)
                    if mRects.skipBack.contains(pt) {
                        mediaPressedButton = .skipBack
                        gestureMode = .mediaButtonTap(button: .skipBack)
                        needsDisplay = true
                        return
                    } else if mRects.skipFwd.contains(pt) {
                        mediaPressedButton = .skipFwd
                        gestureMode = .mediaButtonTap(button: .skipFwd)
                        needsDisplay = true
                        return
                    } else if mRects.jogHit.contains(pt) {
                        isScrubbingMedia = true
                        jogNormalizedOffset = 0
                        jogAccumulatedSec = 0
                        gestureMode = .mediaJogScrubbing(startX: pt.x, lastStep: 0)
                        hudDismissTimer?.invalidate()
                        needsDisplay = true
                        return
                    }
                }
            }

            gestureMode = .pendingTap(startPoint: pt, startTime: now)

            // Long-press anywhere (0.38s) -> Pause media & bring up Media Overlay
            // Uses DispatchWorkItem on main queue so it fires reliably even during Touch Bar event tracking!
            cancelLongPress()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if case .pendingTap = self.gestureMode, self.peakTouchCount == 1 {
                    self.gestureMode = .longPressConsumed
                    self.openMediaOverlay(togglePlayback: true, pinned: false)
                }
            }
            longPressWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
        } else if count == 2 {
            let avgX = averageX(active)
            // If already in a Brightness or Volume slide, smoothly re-anchor without resetting or jumping!
            switch gestureMode {
            case .brightnessSlide(var st):
                reanchorSliderState(&st, touches: active, now: now)
                gestureMode = .brightnessSlide(st)
                return
            case .volumeSlide(var st):
                reanchorSliderState(&st, touches: active, now: now)
                gestureMode = .volumeSlide(st)
                return
            default:
                break
            }
            let curVol = AudioController.shared.getVolume()
            gestureMode = .twoFingerPending(startX: avgX, startTime: now, startVolume: curVol)
        } else if count >= 3 {
            if case .brightnessSlide(var st) = gestureMode {
                reanchorSliderState(&st, touches: active, now: now)
                gestureMode = .brightnessSlide(st)
                return
            }
            cancelSliderSyncAndEase()
            let curBright = BrightnessController.shared.getDisplayBrightness()
            gestureMode = .brightnessSlide(makeSliderState(touches: active, initialValue: curBright, now: now, settle: true))
            hudDismissTimer?.invalidate()
            mediaTickTimer?.invalidate()
            activeHUD = .brightness(value: curBright)
            needsDisplay = true
        }
    }

    override func touchesMoved(with event: NSEvent) {
        let active = Array(event.touches(matching: .touching, in: self))
        let count = active.count
        peakTouchCount = max(peakTouchCount, count)
        guard count > 0 else { return }

        let now = ProcessInfo.processInfo.systemUptime

        if count >= 2 {
            cancelLongPress()
            mediaPressedButton = nil
            isScrubbingMedia = false
        }

        let avgX = averageX(active)

        switch gestureMode {
        case .pendingTap(let startPt, _):
            if count >= 3 {
                cancelSliderSyncAndEase()
                let b = BrightnessController.shared.getDisplayBrightness()
                gestureMode = .brightnessSlide(makeSliderState(touches: active, initialValue: b, now: now, settle: true))
                hudDismissTimer?.invalidate()
                mediaTickTimer?.invalidate()
                activeHUD = .brightness(value: b)
                needsDisplay = true
            } else if count == 2 {
                let v = AudioController.shared.getVolume()
                gestureMode = .twoFingerPending(startX: avgX, startTime: now, startVolume: v)
            } else if abs(avgX - startPt.x) > 22 {
                cancelLongPress()
                gestureMode = .idle
            }

        case .mediaScrubbing:
            if count == 1 {
                let mRects = mediaOverlayRects(for: bounds)
                scrubPreviewFraction = scrubFraction(forX: active[0].location(in: self).x, trackRect: mRects.scrubberTrack)
                needsDisplay = true
            }

        case .mediaJogScrubbing(let startX, let lastStep):
            if count == 1 {
                let mRects = mediaOverlayRects(for: bounds)
                let dx = active[0].location(in: self).x - startX
                let halfW = max(40, mRects.jogTrack.width / 2.0)
                jogNormalizedOffset = min(1.0, max(-1.0, dx / halfW))
                let curStep = Int(dx / 24.0) // Every 24pt = 5s scrub step
                let diff = curStep - lastStep
                if diff != 0 {
                    let deltaSec = Double(diff) * 5.0
                    jogAccumulatedSec += diff * 5
                    MediaController.shared.seekRelative(deltaSeconds: deltaSec)
                    gestureMode = .mediaJogScrubbing(startX: startX, lastStep: curStep)
                }
                needsDisplay = true
            }

        case .mediaButtonTap:
            if count >= 2 {
                mediaPressedButton = nil
                let v = AudioController.shared.getVolume()
                gestureMode = .twoFingerPending(startX: avgX, startTime: now, startVolume: v)
            }

        case .longPressConsumed:
            break

        case .twoFingerPending(let startX, let startTime, let startVol):
            if count >= 3 {
                cancelSliderSyncAndEase()
                let b = BrightnessController.shared.getDisplayBrightness()
                gestureMode = .brightnessSlide(makeSliderState(touches: active, initialValue: b, now: now, settle: true))
                hudDismissTimer?.invalidate()
                mediaTickTimer?.invalidate()
                activeHUD = .brightness(value: b)
                needsDisplay = true
            } else {
                // Slightly higher threshold during the first 55ms so landing 3 fingers for Brightness
                // never accidentally bumps Volume while finger 3 is still arriving.
                let threshold: CGFloat = (now - startTime) < 0.055 ? 9.0 : 4.5
                let initialDx = avgX - startX
                if abs(initialDx) > threshold {
                    cancelSliderSyncAndEase()
                    var st = makeSliderState(touches: active, initialValue: startVol, now: now)
                    applySliderDelta(initialDx, touchCount: count, isVolume: true, state: &st)
                    gestureMode = .volumeSlide(st)
                }
            }

        case .volumeSlide(var st):
            if count >= 3 {
                cancelSliderSyncAndEase()
                let b = BrightnessController.shared.getDisplayBrightness()
                gestureMode = .brightnessSlide(makeSliderState(touches: active, initialValue: b, now: now, settle: true))
                hudDismissTimer?.invalidate()
                mediaTickTimer?.invalidate()
                activeHUD = .brightness(value: b)
                needsDisplay = true
            } else {
                let rawDx = computeRobustDeltaX(touches: active, state: &st, now: now)
                if rawDx != 0 {
                    applySliderDelta(rawDx, touchCount: count, isVolume: true, state: &st)
                }
                gestureMode = .volumeSlide(st)
            }

        case .brightnessSlide(var st):
            let rawDx = computeRobustDeltaX(touches: active, state: &st, now: now)
            if rawDx != 0 {
                applySliderDelta(rawDx, touchCount: count, isVolume: false, state: &st)
            }
            gestureMode = .brightnessSlide(st)

        case .idle:
            break
        }
    }

    override func touchesEnded(with event: NSEvent) {
        let remaining = Array(event.touches(matching: .touching, in: self))
        let now = ProcessInfo.processInfo.systemUptime

        // If some fingers lifted while others remain (e.g., 3 -> 1 or 2 -> 1),
        // re-anchor touch identities immediately with a brief settle window so there is ZERO jump!
        if !remaining.isEmpty {
            switch gestureMode {
            case .brightnessSlide(var st):
                reanchorSliderState(&st, touches: remaining, now: now)
                gestureMode = .brightnessSlide(st)
            case .volumeSlide(var st):
                reanchorSliderState(&st, touches: remaining, now: now)
                gestureMode = .volumeSlide(st)
            case .twoFingerPending(_, _, let startVol):
                // User started with 2 fingers and dropped to 1 finger -> open Volume panel for 1-finger fine control!
                if remaining.count == 1 {
                    cancelSliderSyncAndEase()
                    let st = makeSliderState(touches: remaining, initialValue: startVol, now: now, settle: true)
                    gestureMode = .volumeSlide(st)
                    hudDismissTimer?.invalidate()
                    mediaTickTimer?.invalidate()
                    activeHUD = .volume(value: startVol, muted: AudioController.shared.isMuted())
                    needsDisplay = true
                }
            default:
                break
            }
            return
        }

        cancelLongPress()

        switch gestureMode {
        case .pendingTap(let startPt, let startTime):
            if peakTouchCount == 1 && (now - startTime) < 0.36 {
                handleSingleTap(at: startPt)
            }

        case .mediaButtonTap(let button):
            mediaPressedButton = nil
            handleMediaButton(button)
            needsDisplay = true

        case .mediaScrubbing:
            isScrubbingMedia = false
            if mediaState.canSeek && mediaState.duration > 0 {
                let targetSec = Double(scrubPreviewFraction) * mediaState.duration
                mediaState.elapsed = targetSec
                mediaState.fetchedAt = Date()
                MediaController.shared.seek(to: targetSec) { [weak self] state in
                    self?.mediaState = state
                    self?.needsDisplay = true
                }
            }
            resetMediaAutoDismissIfNeeded()
            needsDisplay = true

        case .mediaJogScrubbing:
            isScrubbingMedia = false
            jogNormalizedOffset = 0
            jogAccumulatedSec = 0
            resetMediaAutoDismissIfNeeded()
            needsDisplay = true

        case .longPressConsumed:
            break

        case .twoFingerPending(_, let startTime, _):
            if peakTouchCount == 2 && (now - startTime) < 0.28 {
                let muted = AudioController.shared.toggleMute()
                let vol = AudioController.shared.getVolume()
                mediaTickTimer?.invalidate()
                cancelSliderSyncAndEase()
                activeHUD = .volume(value: vol, muted: muted)
                scheduleHUDDismiss(after: 1.0)
                needsDisplay = true
            }

        case .volumeSlide:
            // Reconcile once with hardware after HID queue settles, and linger 3.0s for 1F fine tuning
            scheduleSliderHardwareSync(isVolume: true)
            scheduleHUDDismiss(after: 3.0)

        case .brightnessSlide:
            scheduleSliderHardwareSync(isVolume: false)
            scheduleHUDDismiss(after: 3.0)

        case .idle:
            break
        }

        gestureMode = .idle
        peakTouchCount = 0
    }

    override func touchesCancelled(with event: NSEvent) {
        cancelLongPress()
        mediaPressedButton = nil
        isScrubbingMedia = false
        if case .volumeSlide = gestureMode {
            scheduleSliderHardwareSync(isVolume: true)
            scheduleHUDDismiss(after: 3.0)
        }
        if case .brightnessSlide = gestureMode {
            scheduleSliderHardwareSync(isVolume: false)
            scheduleHUDDismiss(after: 3.0)
        }
        gestureMode = .idle
        peakTouchCount = 0
    }

    private func averageX(_ touches: [NSTouch]) -> CGFloat {
        guard !touches.isEmpty else { return 0 }
        let sum = touches.reduce(CGFloat(0)) { $0 + $1.location(in: self).x }
        return sum / CGFloat(touches.count)
    }

    private func touchKey(_ touch: NSTouch) -> AnyHashable {
        if let obj = touch.identity as? NSObject {
            return AnyHashable(obj)
        }
        return AnyHashable(ObjectIdentifier(touch.identity as AnyObject))
    }

    private func touchPositions(_ touches: [NSTouch]) -> [AnyHashable: CGFloat] {
        var map: [AnyHashable: CGFloat] = [:]
        map.reserveCapacity(touches.count)
        for t in touches {
            map[touchKey(t)] = t.location(in: self).x
        }
        return map
    }

    private func makeSliderState(touches: [NSTouch], initialValue: Float, now: TimeInterval, settle: Bool = false) -> SliderTrackState {
        SliderTrackState(
            touchXByID: touchPositions(touches),
            visualValue: max(0.0, min(1.0, initialValue)),
            stepCreditPx: 0,
            lastStepDir: 0,
            settleUntil: settle ? (now + 0.035) : 0,
            isAccessibilityTrusted: TBIsAccessibilityTrusted(false)
        )
    }

    private func reanchorSliderState(_ st: inout SliderTrackState, touches: [NSTouch], now: TimeInterval) {
        st.touchXByID = touchPositions(touches)
        st.stepCreditPx = 0
        st.settleUntil = now + 0.035
    }

    /// Computes a glitch-free per-frame horizontal delta across persistent touch identities.
    /// Eliminates finger-arrival/lift centroid jumps, rolling-finger spikes, and resting micro-jitter.
    private func computeRobustDeltaX(touches: [NSTouch], state st: inout SliderTrackState, now: TimeInterval) -> CGFloat {
        let prevCount = st.touchXByID.count
        var nextPositions: [AnyHashable: CGFloat] = [:]
        nextPositions.reserveCapacity(touches.count)
        var deltas: [CGFloat] = []
        deltas.reserveCapacity(touches.count)

        for t in touches {
            let key = touchKey(t)
            let x = t.location(in: self).x
            nextPositions[key] = x
            if let prevX = st.touchXByID[key] {
                let d = x - prevX
                // Reject impossible single-frame capacitive lift/edge glitches (> 48pt in one frame)
                if abs(d) <= 48.0 {
                    deltas.append(d)
                }
            }
        }
        st.touchXByID = nextPositions

        // Finger count changed -> absorb transition frame & settle briefly
        if touches.count != prevCount {
            st.stepCreditPx = 0
            st.settleUntil = now + 0.035
            return 0
        }

        if now < st.settleUntil || deltas.isEmpty {
            return 0
        }

        let rawDx: CGFloat
        if deltas.count == 1 {
            rawDx = deltas[0]
        } else if deltas.count == 2 {
            let d0 = deltas[0]
            let d1 = deltas[1]
            if d0 * d1 < 0 && abs(d0 - d1) > 2.5 {
                // Opposite-sign divergence happens when one finger rolls off while lifting -> ignore wobble
                return 0
            }
            let a0 = abs(d0), a1 = abs(d1)
            let hi = max(a0, a1), lo = min(a0, a1)
            if hi > 4.0 && hi > lo * 3.0 {
                // Single-finger roll outlier -> follow the steadier finger
                rawDx = (a0 <= a1) ? d0 : d1
            } else {
                rawDx = (d0 + d1) * 0.5
            }
        } else {
            // 3+ fingers: median completely ignores any single rolling/lifting finger!
            let sorted = deltas.sorted()
            rawDx = sorted[sorted.count / 2]
        }

        // Ignore sub-pixel capacitive shimmer when fingers are resting
        return abs(rawDx) < 0.25 ? 0 : rawDx
    }

    private func applySliderDelta(_ rawDx: CGFloat, touchCount: Int, isVolume: Bool, state st: inout SliderTrackState) {
        hudDismissTimer?.invalidate()
        mediaTickTimer?.invalidate()
        sliderEaseTimer?.invalidate()
        sliderEaseTimer = nil

        // Finer sensitivity with 1 finger (0.65x) vs quick glide with 2-3 fingers (1.0x)
        let scale: CGFloat = (touchCount == 1) ? 0.65 : 1.0
        let scaledDx = rawDx * scale

        // 5.5pt per 1/64th fine native HID step (~352pt full 0-100% sweep at 2F/3F; ~541pt at 1F)
        let stepPx: CGFloat = 5.5
        let fullSweepPx: CGFloat = stepPx * 64.0
        let reversalDeadband: CGFloat = 1.35

        // Continuous pixel-smooth visual tracking (eliminates chunky 28px stair-steps on the OLED bar!)
        let deltaFrac = Float(scaledDx / fullSweepPx)
        let prevVisual = st.visualValue
        st.visualValue = max(0.0, min(1.0, st.visualValue + deltaFrac))

        if st.isAccessibilityTrusted {
            st.stepCreditPx += scaledDx

            // Boundary clamping: prevent accumulating unbounded credit past 0% or 100%,
            // while still allowing final steps if hardware curve hasn't reached true 0% / 100% yet.
            if st.visualValue <= 0.001 && st.stepCreditPx <= -stepPx {
                let hwAtMin = isVolume
                    ? (AudioController.shared.getVolume() <= 0.002 || AudioController.shared.isMuted())
                    : (BrightnessController.shared.getDisplayBrightness() <= 0.002)
                if hwAtMin {
                    st.stepCreditPx = 0
                }
            } else if st.visualValue >= 0.999 && st.stepCreditPx >= stepPx {
                let hwAtMax = isVolume
                    ? (AudioController.shared.getVolume() >= 0.998)
                    : (BrightnessController.shared.getDisplayBrightness() >= 0.998)
                if hwAtMax {
                    st.stepCreditPx = 0
                }
            }

            // Hysteresis step emitter: requires 1.35x threshold on direction reversal to prevent +1/-1 chatter
            var stepsToEmit = 0
            let maxStepsPerFrame = 6

            while stepsToEmit < maxStepsPerFrame {
                let thresh = (st.lastStepDir < 0) ? (stepPx * reversalDeadband) : stepPx
                if st.stepCreditPx >= thresh {
                    st.stepCreditPx -= stepPx
                    st.lastStepDir = 1
                    stepsToEmit += 1
                } else {
                    break
                }
            }
            while stepsToEmit > -maxStepsPerFrame {
                let thresh = (st.lastStepDir > 0) ? (stepPx * reversalDeadband) : stepPx
                if st.stepCreditPx <= -thresh {
                    st.stepCreditPx += stepPx
                    st.lastStepDir = -1
                    stepsToEmit -= 1
                } else {
                    break
                }
            }

            if stepsToEmit != 0 {
                if isVolume {
                    AudioController.shared.nudgeVolumeFine(steps: stepsToEmit)
                } else {
                    BrightnessController.shared.nudgeDisplayBrightnessFine(steps: stepsToEmit)
                }
            }

            if isVolume {
                activeHUD = .volume(value: st.visualValue, muted: st.visualValue <= 0.004)
            } else {
                activeHUD = .brightness(value: st.visualValue)
            }
            if abs(st.visualValue - prevVisual) > 0.0004 || stepsToEmit != 0 {
                needsDisplay = true
            }

            // Debounced single hardware sync (only fires 160ms AFTER movement stops — never fights live drag!)
            scheduleSliderHardwareSync(isVolume: isVolume)
        } else {
            if isVolume {
                AudioController.shared.setVolume(st.visualValue, showOSD: true)
                activeHUD = .volume(value: st.visualValue, muted: AudioController.shared.isMuted())
            } else {
                let target = BrightnessController.shared.setDisplayBrightness(st.visualValue, showOSD: true)
                st.visualValue = target
                activeHUD = .brightness(value: target)
            }
            needsDisplay = true
        }
    }

    /// Reconciles the Touch Bar slider with the true hardware value ONCE after the user pauses or lifts,
    /// using a silky 90ms ease so tiny HID curve differences settle invisibly with zero snap-back.
    private func scheduleSliderHardwareSync(isVolume: Bool) {
        sliderSyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.sliderSyncWorkItem = nil

            let hwVal: Float
            let hwMuted: Bool
            let currentDisplayed: Float

            if isVolume {
                guard case .volume(let cur, _) = self.activeHUD else { return }
                currentDisplayed = cur
                hwVal = AudioController.shared.getVolume()
                hwMuted = AudioController.shared.isMuted()
                if case .volumeSlide(var st) = self.gestureMode {
                    st.visualValue = hwVal
                    st.stepCreditPx = 0
                    self.gestureMode = .volumeSlide(st)
                }
            } else {
                guard case .brightness(let cur) = self.activeHUD else { return }
                currentDisplayed = cur
                hwVal = BrightnessController.shared.getDisplayBrightness()
                hwMuted = false
                if case .brightnessSlide(var st) = self.gestureMode {
                    st.visualValue = hwVal
                    st.stepCreditPx = 0
                    self.gestureMode = .brightnessSlide(st)
                }
            }

            if abs(hwVal - currentDisplayed) <= 0.008 || hwMuted {
                self.activeHUD = isVolume ? .volume(value: hwVal, muted: hwMuted) : .brightness(value: hwVal)
                self.needsDisplay = true
                return
            }

            // Smooth 90ms ease (6 steps @ ~66Hz) to reconcile any tiny non-linear HID curve offset
            self.sliderEaseTimer?.invalidate()
            let totalSteps = 6
            var step = 0
            let startVal = currentDisplayed
            let timer = Timer(timeInterval: 0.015, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                step += 1
                let progress = min(1.0, Float(step) / Float(totalSteps))
                // Ease-out quadratic
                let eased = 1.0 - (1.0 - progress) * (1.0 - progress)
                let val = startVal + (hwVal - startVal) * eased

                if isVolume {
                    guard case .volume = self.activeHUD else { t.invalidate(); self.sliderEaseTimer = nil; return }
                    self.activeHUD = .volume(value: val, muted: hwMuted)
                } else {
                    guard case .brightness = self.activeHUD else { t.invalidate(); self.sliderEaseTimer = nil; return }
                    self.activeHUD = .brightness(value: val)
                }
                self.needsDisplay = true

                if step >= totalSteps {
                    t.invalidate()
                    self.sliderEaseTimer = nil
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.sliderEaseTimer = timer
        }
        sliderSyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func handleMediaButton(_ button: MediaButton) {
        switch button {
        case .close:
            dismissActiveHUD()
        case .prev:
            resetMediaAutoDismissIfNeeded()
            MediaController.shared.previousTrack { [weak self] state in
                guard let self = self else { return }
                self.mediaState = state
                self.mediaOverlayStartTime = CFAbsoluteTimeGetCurrent()
                self.configureMediaTickTimer()
                self.needsDisplay = true
            }
        case .playPause:
            resetMediaAutoDismissIfNeeded()
            mediaState.isPlaying.toggle()
            mediaState.fetchedAt = Date()
            needsDisplay = true
            MediaController.shared.togglePlayPause { [weak self] state in
                guard let self = self else { return }
                self.mediaState = state
                self.configureMediaTickTimer()
                self.needsDisplay = true
            }
        case .next:
            resetMediaAutoDismissIfNeeded()
            MediaController.shared.nextTrack { [weak self] state in
                guard let self = self else { return }
                self.mediaState = state
                self.mediaOverlayStartTime = CFAbsoluteTimeGetCurrent()
                self.configureMediaTickTimer()
                self.needsDisplay = true
            }
        case .skipBack:
            resetMediaAutoDismissIfNeeded()
            MediaController.shared.seekRelative(deltaSeconds: -10.0)
        case .skipFwd:
            resetMediaAutoDismissIfNeeded()
            MediaController.shared.seekRelative(deltaSeconds: 10.0)
        }
    }

    // MARK: - Expanded Live Panel Inspector (stays open until manually tapped/closed)
    private func openInspector(_ kind: InspectorKind) {
        cancelLongPress()
        hudDismissTimer?.invalidate()
        hudDismissTimer = nil
        mediaTickTimer?.invalidate()
        mediaTickTimer = nil
        flashAnimTimer?.invalidate()
        flashAnimTimer = nil
        cancelSliderSyncAndEase()
        inspectorTickCount = 0
        activeHUD = .inspector(kind)
        needsDisplay = true

        if kind == .cpu {
            refreshTopProcesses(isCPU: true)
        } else if kind == .ram {
            refreshTopProcesses(isCPU: false)
        }
    }

    private func refreshTopProcesses(isCPU: Bool) {
        guard !isFetchingTopProcesses else { return }
        isFetchingTopProcesses = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if isCPU {
                let top = CPUSampler.fetchTopProcesses(limit: 3)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isFetchingTopProcesses = false
                    self.topCPUProcesses = top
                    if case .inspector(.cpu) = self.activeHUD {
                        self.needsDisplay = true
                    }
                }
            } else {
                let top = MemorySampler.fetchTopRAMProcesses(limit: 3)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isFetchingTopProcesses = false
                    self.topRAMProcesses = top
                    if case .inspector(.ram) = self.activeHUD {
                        self.needsDisplay = true
                    }
                }
            }
        }
    }

    // MARK: - Single Tap Panel Interactions
    private func handleSingleTap(at point: NSPoint) {
        // Dismiss any active toast, inspector, or agent flash if tapped
        if case .infoToast = activeHUD {
            dismissActiveHUD()
            return
        }
        if case .inspector = activeHUD {
            dismissActiveHUD()
            return
        }
        if case .agentFlash = activeHUD {
            dismissActiveHUD()
            return
        }

        let rects = panelRects(for: bounds)
        if rects.cpu.contains(point) {
            openInspector(.cpu)
        } else if rects.ram.contains(point) {
            openInspector(.ram)
        } else if rects.thermal.contains(point) {
            if waitingAgentName != nil {
                clearWaitingAgent()
                onFocusTerminal?()
                return
            }
            openInspector(.thermal)
        } else if rects.power.contains(point) {
            openInspector(.power)
        } else if rects.network.contains(point) {
            openInspector(.network)
        } else if rects.clock.contains(point) {
            openMediaOverlay(togglePlayback: false, pinned: true)
        }
    }

    // MARK: - Panel Layout Geometry
    private struct PanelRects {
        let cpu: NSRect
        let ram: NSRect
        let thermal: NSRect
        let power: NSRect
        let network: NSRect
        let clock: NSRect
    }

    private func panelRects(for rect: NSRect) -> PanelRects {
        let w = rect.width
        let h = rect.height
        let weights: [CGFloat] = [0.225, 0.16, 0.19, 0.165, 0.175, 0.085]
        var x: CGFloat = 0
        var frames: [NSRect] = []
        for (i, weight) in weights.enumerated() {
            let pw = (i == weights.count - 1) ? (w - x) : floor(w * weight)
            frames.append(NSRect(x: x, y: 0, width: pw, height: h))
            x += pw
        }
        return PanelRects(
            cpu: frames[0],
            ram: frames[1],
            thermal: frames[2],
            power: frames[3],
            network: frames[4],
            clock: frames[5]
        )
    }

    // MARK: - CoreGraphics OLED Rendering
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Pure OLED Black Background (clipped to dirtyRect for fast partial redraws)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(dirtyRect)

        switch activeHUD {
        case .volume(let value, let muted):
            drawSliderHUD(
                ctx: ctx,
                iconName: muted || value <= 0.005 ? "speaker.slash.fill" : (value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"),
                label: muted ? "MUTED" : String(format: "%3d%%", Int(round(value * 100))),
                fraction: muted ? 0 : CGFloat(value),
                accent: muted ? NSColor.systemRed : NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.98, alpha: 1.0)
            )
            return

        case .brightness(let value):
            drawSliderHUD(
                ctx: ctx,
                iconName: value < 0.4 ? "sun.min.fill" : "sun.max.fill",
                label: String(format: "%3d%%", Int(round(value * 100))),
                fraction: CGFloat(value),
                accent: NSColor(calibratedRed: 0.99, green: 0.80, blue: 0.26, alpha: 1.0)
            )
            return

        case .infoToast(let title, let detail, let accent):
            drawToastHUD(ctx: ctx, title: title, detail: detail, accent: accent)
            return

        case .inspector(let kind):
            drawInspectorHUD(ctx: ctx, kind: kind)
            return

        case .media:
            drawMediaOverlay(ctx: ctx)
            return

        case .agentFlash(let agent, let startTime):
            drawAgentAmberFlash(ctx: ctx, agent: agent, elapsed: CFAbsoluteTimeGetCurrent() - startTime)
            return

        case .none:
            break
        }

        // Draw 6-Panel Info-Dense Cockpit (skip panels outside dirtyRect for ultra-low 20 FPS waveform CPU)
        let rects = panelRects(for: bounds)

        if dirtyRect.intersects(rects.cpu) {
            drawCPUPanel(ctx: ctx, rect: rects.cpu)
            drawDivider(ctx: ctx, x: rects.cpu.maxX, height: bounds.height)
        }
        if dirtyRect.intersects(rects.ram) {
            drawRAMPanel(ctx: ctx, rect: rects.ram)
            drawDivider(ctx: ctx, x: rects.ram.maxX, height: bounds.height)
        }
        if dirtyRect.intersects(rects.thermal) {
            drawThermalPanel(ctx: ctx, rect: rects.thermal)
            drawDivider(ctx: ctx, x: rects.thermal.maxX, height: bounds.height)
        }
        if dirtyRect.intersects(rects.power) {
            drawPowerPanel(ctx: ctx, rect: rects.power)
            drawDivider(ctx: ctx, x: rects.power.maxX, height: bounds.height)
        }
        if dirtyRect.intersects(rects.network) {
            drawNetworkPanel(ctx: ctx, rect: rects.network)
            drawDivider(ctx: ctx, x: rects.network.maxX, height: bounds.height)
        }
        if dirtyRect.intersects(rects.clock) {
            drawClockPanel(ctx: ctx, rect: rects.clock)
        }
    }

    // MARK: - Divider
    private func drawDivider(ctx: CGContext, x: CGFloat, height: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor)
        ctx.fill(CGRect(x: x, y: 4, width: 1, height: height - 8))
        ctx.restoreGState()
    }

    // MARK: - Panel 1: CPU Sparkline + 8 Per-Core P/E Bars
    private func drawCPUPanel(ctx: CGContext, rect: NSRect) {
        let padX: CGFloat = 7
        let innerW = rect.width - padX * 2

        let cpuColor: NSColor
        if metrics.cpuTotal >= 85 {
            cpuColor = NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.34, alpha: 1.0)
        } else if metrics.cpuTotal >= 55 {
            cpuColor = NSColor(calibratedRed: 0.99, green: 0.65, blue: 0.22, alpha: 1.0)
        } else {
            cpuColor = NSColor(calibratedRed: 0.24, green: 0.82, blue: 0.98, alpha: 1.0)
        }

        // Top-left: "CPU" + Percentage
        drawText("CPU", at: NSPoint(x: rect.minX + padX, y: 17), size: 9, weight: .semibold, color: NSColor(calibratedWhite: 0.52, alpha: 1.0))
        drawText(String(format: "%2.0f%%", metrics.cpuTotal), at: NSPoint(x: rect.minX + padX + 24, y: 16), size: 11, weight: .bold, color: cpuColor, mono: true)

        // Right-side per-core bars (8 cores on M2: 4 E-cores cyan, 4 P-cores orange/amber)
        let coreCount = max(1, metrics.coreLoads.count)
        let coreAreaW: CGFloat = min(56, CGFloat(coreCount) * 6.5)
        let coreStartX = rect.maxX - padX - coreAreaW
        let barW: CGFloat = max(2.5, (coreAreaW - CGFloat(coreCount - 1) * 2.0) / CGFloat(coreCount))
        let maxBarH: CGFloat = 22

        for (idx, load) in metrics.coreLoads.enumerated() {
            let bx = coreStartX + CGFloat(idx) * (barW + 2.0)
            let frac = CGFloat(min(1.0, max(0.06, load / 100.0)))
            let isPCore = idx >= metrics.eCoreCount

            // Track
            ctx.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 1.0).cgColor)
            ctx.fill(CGRect(x: bx, y: 4, width: barW, height: maxBarH))

            // Fill
            let barColor: NSColor
            if load >= 85 {
                barColor = NSColor(calibratedRed: 1.0, green: 0.32, blue: 0.32, alpha: 1.0)
            } else if isPCore {
                barColor = NSColor(calibratedRed: 0.99, green: 0.62, blue: 0.22, alpha: 1.0)
            } else {
                barColor = NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.98, alpha: 1.0)
            }
            ctx.setFillColor(barColor.cgColor)
            ctx.fill(CGRect(x: bx, y: 4, width: barW, height: maxBarH * frac))
        }

        // Bottom-left: 48-sample rolling area sparkline
        let sparkW = max(30, innerW - coreAreaW - 8)
        let sparkRect = CGRect(x: rect.minX + padX, y: 3, width: sparkW, height: 12)
        drawSparkline(ctx: ctx, values: metrics.cpuHistory, maxValue: 100.0, rect: sparkRect, strokeColor: cpuColor, fillAlpha: 0.26)
    }

    // MARK: - Panel 2: Unified Memory & Swap
    private func drawRAMPanel(ctx: CGContext, rect: NSRect) {
        let padX: CGFloat = 7
        let innerW = rect.width - padX * 2

        drawText("RAM", at: NSPoint(x: rect.minX + padX, y: 17), size: 9, weight: .semibold, color: NSColor(calibratedWhite: 0.52, alpha: 1.0))

        let memStr = String(format: "%.1f/%.0fG", metrics.memUsedGB, metrics.memTotalGB)
        let usedRatio = metrics.memTotalGB > 0 ? (metrics.memUsedGB / metrics.memTotalGB) : 0
        let memColor = usedRatio > 0.85
            ? NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.34, alpha: 1.0)
            : (usedRatio > 0.70 ? NSColor(calibratedRed: 0.99, green: 0.74, blue: 0.24, alpha: 1.0) : NSColor.white)
        drawText(memStr, at: NSPoint(x: rect.minX + padX + 25, y: 16), size: 10.5, weight: .semibold, color: memColor, mono: true)

        // Swap badge on top-right if actively swapping (>= 0.1 GB)
        if metrics.swapUsedGB >= 0.1 {
            let swText = String(format: "SW %.1f", metrics.swapUsedGB)
            let swColor = metrics.swapUsedGB >= 2.0
                ? NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.34, alpha: 1.0)
                : NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.20, alpha: 1.0)
            drawTextRight(swText, rightX: rect.maxX - padX, y: 17, size: 8.5, weight: .bold, color: swColor, mono: true)
        }

        // Segmented Memory Bar (Active / Wired / Compressed)
        let barRect = CGRect(x: rect.minX + padX, y: 5, width: innerW, height: 7)
        let clipPath = CGPath(roundedRect: barRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()

        ctx.setFillColor(NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor)
        ctx.fill(barRect)

        var sx = barRect.minX
        let segs: [(CGFloat, NSColor)] = [
            (CGFloat(metrics.memActiveFrac), NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)),
            (CGFloat(metrics.memWiredFrac), NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.98, alpha: 1.0)),
            (CGFloat(metrics.memCompressedFrac), NSColor(calibratedRed: 0.98, green: 0.73, blue: 0.22, alpha: 1.0))
        ]
        for (frac, color) in segs {
            let sw = max(0, barRect.width * frac)
            if sw > 0.5 {
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: sx, y: barRect.minY, width: sw, height: barRect.height))
                sx += sw
            }
        }
        ctx.restoreGState()
    }

    // MARK: - Panel 3: M2 Thermal & Fan RPM (or Persistent Amber "Agent Waiting" Banner)
    private func drawThermalPanel(ctx: CGContext, rect: NSRect) {
        if let agent = waitingAgentName {
            let pillRect = rect.insetBy(dx: 4, dy: 2.5)
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            let amber = NSColor(calibratedRed: 0.99, green: 0.66, blue: 0.14, alpha: 1.0)

            ctx.saveGState()
            ctx.setFillColor(amber.withAlphaComponent(0.24).cgColor)
            ctx.addPath(pillPath)
            ctx.fillPath()
            ctx.setStrokeColor(amber.withAlphaComponent(0.90).cgColor)
            ctx.setLineWidth(1.1)
            ctx.addPath(pillPath)
            ctx.strokePath()
            ctx.restoreGState()

            drawTextCentered("✦ \(agent.uppercased()) WAITING", centerX: rect.midX, y: 14.5, size: 9.5, weight: .bold, color: NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.42, alpha: 1.0))
            drawTextCentered("YOUR TURN · OPEN TERMINAL", centerX: rect.midX, y: 4.0, size: 7.2, weight: .semibold, color: amber.withAlphaComponent(0.85))
            return
        }

        let padX: CGFloat = 7
        let innerW = rect.width - padX * 2

        let temp = metrics.socTempC
        let tempColor: NSColor
        if temp < 0 {
            tempColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
        } else if temp >= 80 {
            tempColor = NSColor(calibratedRed: 1.0, green: 0.32, blue: 0.32, alpha: 1.0)
        } else if temp >= 62 {
            tempColor = NSColor(calibratedRed: 0.99, green: 0.66, blue: 0.22, alpha: 1.0)
        } else if temp >= 48 {
            tempColor = NSColor(calibratedRed: 0.26, green: 0.85, blue: 0.62, alpha: 1.0)
        } else {
            tempColor = NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.99, alpha: 1.0)
        }

        drawText("M2", at: NSPoint(x: rect.minX + padX, y: 17), size: 9, weight: .semibold, color: NSColor(calibratedWhite: 0.52, alpha: 1.0))
        let tempStr = temp > 0 ? String(format: "%.0f°C", temp) : "--°C"
        drawText(tempStr, at: NSPoint(x: rect.minX + padX + 20, y: 16), size: 11, weight: .bold, color: tempColor, mono: true)

        // Fan RPM right aligned
        let fanStr: String
        let fanColor: NSColor
        if metrics.fanAvailable {
            if metrics.fanRPM < 100 {
                fanStr = "0 rpm"
                fanColor = NSColor(calibratedWhite: 0.45, alpha: 1.0)
            } else {
                fanStr = String(format: "%.0frpm", metrics.fanRPM)
                fanColor = metrics.fanRPM > 4000
                    ? NSColor(calibratedRed: 0.99, green: 0.62, blue: 0.24, alpha: 1.0)
                    : NSColor(calibratedWhite: 0.80, alpha: 1.0)
            }
        } else {
            fanStr = "FAN --"
            fanColor = NSColor(calibratedWhite: 0.40, alpha: 1.0)
        }
        drawTextRight(fanStr, rightX: rect.maxX - padX, y: 16.5, size: 9.5, weight: .medium, color: fanColor, mono: true)

        // Dual micro-bars: Top = Temp (30..100C), Bottom = Fan RPM %
        let tempFrac = temp > 0 ? CGFloat(min(1.0, max(0.0, (temp - 30.0) / 70.0))) : 0
        drawRoundedBar(ctx: ctx, rect: CGRect(x: rect.minX + padX, y: 8.5, width: innerW, height: 3.5), fraction: tempFrac, fillColor: tempColor)

        let fanFrac = (metrics.fanAvailable && metrics.fanMaxRPM > 0) ? CGFloat(min(1.0, max(0.0, metrics.fanRPM / metrics.fanMaxRPM))) : 0
        drawRoundedBar(ctx: ctx, rect: CGRect(x: rect.minX + padX, y: 3.5, width: innerW, height: 3.0), fraction: fanFrac, fillColor: NSColor(calibratedRed: 0.56, green: 0.66, blue: 0.98, alpha: 0.9))
    }

    // MARK: - Panel 4: Live System Draw + Charger Power In + Battery
    private func drawPowerPanel(ctx: CGContext, rect: NSRect) {
        let padX: CGFloat = 7

        let sysWatts = metrics.powerWatts
        let inWatts = metrics.chargerInWatts

        let sysColor: NSColor
        if sysWatts >= 20.0 {
            sysColor = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.34, alpha: 1.0)
        } else if sysWatts >= 12.0 {
            sysColor = NSColor(calibratedRed: 0.99, green: 0.68, blue: 0.24, alpha: 1.0)
        } else {
            sysColor = NSColor(calibratedRed: 0.28, green: 0.84, blue: 0.98, alpha: 1.0)
        }

        let inColor: NSColor
        if !metrics.isPluggedIn {
            inColor = NSColor(calibratedWhite: 0.40, alpha: 1.0)
        } else if metrics.isCharging || inWatts > sysWatts + 1.0 {
            inColor = NSColor(calibratedRed: 0.24, green: 0.90, blue: 0.54, alpha: 1.0)
        } else {
            inColor = NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.25, alpha: 1.0)
        }

        let battColor: NSColor
        if metrics.batteryPercent <= 15 && !metrics.isPluggedIn {
            battColor = NSColor(calibratedRed: 1.0, green: 0.32, blue: 0.32, alpha: 1.0)
        } else if metrics.isCharging {
            battColor = NSColor(calibratedRed: 0.24, green: 0.90, blue: 0.54, alpha: 1.0)
        } else {
            battColor = NSColor(calibratedWhite: 0.86, alpha: 1.0)
        }

        // Row 1: System Draw (SYS 14.4W) + Battery %
        drawText("SYS", at: NSPoint(x: rect.minX + padX, y: 17), size: 8.5, weight: .semibold, color: NSColor(calibratedWhite: 0.52, alpha: 1.0))
        drawText(String(format: "%.1fW", sysWatts), at: NSPoint(x: rect.minX + padX + 24, y: 16), size: 10, weight: .bold, color: sysColor, mono: true)
        drawTextRight("\(metrics.batteryPercent)%", rightX: rect.maxX - padX, y: 16, size: 9.5, weight: .semibold, color: battColor, mono: true)

        // Row 2: Charger Power In (⚡IN 38.2W) + Compact Battery Bar
        let inTag = metrics.isPluggedIn ? "⚡IN" : "IN"
        drawText(inTag, at: NSPoint(x: rect.minX + padX, y: 4.5), size: 8.5, weight: .semibold, color: metrics.isPluggedIn ? inColor.withAlphaComponent(0.85) : NSColor(calibratedWhite: 0.42, alpha: 1.0))
        drawText(String(format: "%.1fW", inWatts), at: NSPoint(x: rect.minX + padX + 24, y: 3.5), size: 10, weight: .bold, color: inColor, mono: true)

        // Right-aligned mini battery bar (or time remaining on battery)
        let barStart = rect.minX + padX + 68
        let barAvailW = max(18, (rect.maxX - padX) - barStart)
        if !metrics.isPluggedIn, let mins = metrics.minutesRemaining {
            let rem = String(format: "%dh%02d", mins / 60, mins % 60)
            drawTextRight(rem, rightX: rect.maxX - padX, y: 4.0, size: 8.5, weight: .semibold, color: NSColor(calibratedWhite: 0.55, alpha: 1.0), mono: true)
        } else {
            let battFrac = CGFloat(metrics.batteryPercent) / 100.0
            drawRoundedBar(ctx: ctx, rect: CGRect(x: barStart, y: 6.0, width: barAvailW, height: 5.5), fraction: battFrac, fillColor: battColor)
        }
    }

    // MARK: - Panel 5: Network Sparkline + Tailscale/VPN/Proxy Dots
    private func drawNetworkPanel(ctx: CGContext, rect: NSRect) {
        let padX: CGFloat = 7
        let innerW = rect.width - padX * 2

        let downColor = NSColor(calibratedRed: 0.24, green: 0.80, blue: 0.99, alpha: 1.0)
        let upColor = NSColor(calibratedRed: 0.68, green: 0.54, blue: 0.99, alpha: 1.0)

        let downStr = "↓" + formatSpeedCompact(metrics.netDownBps)
        let upStr = "↑" + formatSpeedCompact(metrics.netUpBps)

        drawText(downStr, at: NSPoint(x: rect.minX + padX, y: 16.5), size: 9.0, weight: .semibold, color: downColor, mono: true)
        drawText(upStr, at: NSPoint(x: rect.minX + padX + 57, y: 16.5), size: 9.0, weight: .semibold, color: upColor, mono: true)

        // Status indicator dots on top-right (only bright when active)
        var dotX = rect.maxX - padX
        let indicators: [(Bool, String, NSColor)] = [
            (metrics.proxyActive, "P", NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.20, alpha: 1.0)),
            (metrics.vpnActive, "V", NSColor(calibratedRed: 0.24, green: 0.88, blue: 0.54, alpha: 1.0)),
            (metrics.tailscaleActive, "T", NSColor(calibratedRed: 0.24, green: 0.78, blue: 0.98, alpha: 1.0))
        ]
        for (active, tag, color) in indicators where active {
            let pillRect = CGRect(x: dotX - 13, y: 17, width: 13, height: 10)
            let path = CGPath(roundedRect: pillRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(color.withAlphaComponent(0.22).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(0.75)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
            drawText(tag, at: NSPoint(x: pillRect.minX + 3.5, y: 16.8), size: 7.5, weight: .bold, color: color)
            dotX -= 16
        }

        // Dynamic auto-scaled dual sparkline
        let peakVal = max(
            128 * 1024.0, // 128 KB/s floor so idle noise stays flat
            max(metrics.netDownHistory.max() ?? 0, metrics.netUpHistory.max() ?? 0)
        )
        let sparkRect = CGRect(x: rect.minX + padX, y: 3, width: innerW, height: 11)
        drawSparkline(ctx: ctx, values: metrics.netDownHistory, maxValue: peakVal, rect: sparkRect, strokeColor: downColor, fillAlpha: 0.22)
        drawSparkline(ctx: ctx, values: metrics.netUpHistory, maxValue: peakVal, rect: sparkRect, strokeColor: upColor, fillAlpha: 0.14)
    }

    // MARK: - Panel 6: Live Dynamic Island Audio Waveform (when playing) or Clock (when idle)
    private func drawClockPanel(ctx: CGContext, rect: NSRect) {
        if isAudioPlaying {
            drawDynamicIslandWaveform(ctx: ctx, rect: rect)
            return
        }

        let centerX = rect.midX
        let timeStr = Self.timeFormatter.string(from: metrics.timestamp)
        drawTextCentered(timeStr, centerX: centerX, y: 13.5, size: 11.5, weight: .semibold, color: .white, mono: true)

        if metrics.keepAwakeActive {
            drawTextCentered("☕ AWAKE", centerX: centerX, y: 3.0, size: 7.5, weight: .bold, color: NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.22, alpha: 1.0))
        } else {
            let dayStr = Self.dayFormatter.string(from: metrics.timestamp).uppercased()
            drawTextCentered(dayStr, centerX: centerX, y: 3.0, size: 7.5, weight: .medium, color: NSColor(calibratedWhite: 0.48, alpha: 1.0))
        }
    }

    private func drawDynamicIslandWaveform(ctx: CGContext, rect: NSRect) {
        let count = waveformBands.count
        guard count > 0 else { return }

        let barW: CGFloat = 4.5
        let gap: CGFloat = 4.5
        let totalW = CGFloat(count) * barW + CGFloat(count - 1) * gap
        let startX = rect.midX - totalW / 2.0
        let midY = rect.midY
        let minH: CGFloat = 4.5
        let maxH: CGFloat = 22.0

        let palette = Self.waveformPalette
        ctx.saveGState()
        for i in 0..<count {
            let level = CGFloat(min(1.0, max(0.0, waveformBands[i])))
            let h = minH + level * (maxH - minH)
            let x = startX + CGFloat(i) * (barW + gap)
            let y = midY - h / 2.0
            let barRect = CGRect(x: x, y: y, width: barW, height: h)
            let path = CGPath(roundedRect: barRect, cornerWidth: barW / 2.0, cornerHeight: barW / 2.0, transform: nil)
            let baseColor = palette[i % palette.count]
            let alpha = 0.55 + 0.45 * level
            ctx.setFillColor(baseColor.withAlphaComponent(alpha).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Tiny amber dot in top-right corner if Keep Awake is active
        if metrics.keepAwakeActive {
            ctx.setFillColor(NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.22, alpha: 1.0).cgColor)
            ctx.fillEllipse(in: CGRect(x: rect.maxX - 9, y: rect.maxY - 8, width: 4, height: 4))
        }
        ctx.restoreGState()
    }

    // MARK: - Full-Width OLED Gesture HUD (Volume / Brightness)
    private func drawSliderHUD(ctx: CGContext, iconName: String, label: String, fraction: CGFloat, accent: NSColor) {
        let padX: CGFloat = 24
        let cy = bounds.midY

        // SF Symbol Icon (cached to avoid per-frame lockFocus bitmap allocation during drags)
        if let tinted = cachedTintedSymbol(iconName, pointSize: 15, color: accent) {
            let sz = tinted.size
            tinted.draw(in: NSRect(x: padX, y: cy - sz.height / 2, width: sz.width, height: sz.height))
        }

        // Right Percentage Label
        drawTextRight(label, rightX: bounds.width - padX, y: cy - 7, size: 13, weight: .bold, color: accent, mono: true)

        // Precision Full-Width Progress Track
        let barX = padX + 34
        let barW = bounds.width - barX - (padX + 54)
        let barRect = CGRect(x: barX, y: cy - 4.5, width: max(60, barW), height: 9)
        drawRoundedBar(ctx: ctx, rect: barRect, fraction: fraction, fillColor: accent)

        // Subtle tick marks every 10%
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        for i in 1..<10 {
            let tx = barRect.minX + barRect.width * CGFloat(i) / 10.0
            ctx.fill(CGRect(x: tx, y: barRect.minY, width: 1, height: barRect.height))
        }
        ctx.restoreGState()
    }

    // MARK: - Inline Transient Toast HUD
    private func drawToastHUD(ctx: CGContext, title: String, detail: String, accent: NSColor) {
        let padX: CGFloat = 16
        let badgeRect = CGRect(x: padX, y: 6, width: 88, height: 18)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(accent.withAlphaComponent(0.20).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        drawTextCentered(title, centerX: badgeRect.midX, y: 9.5, size: 9.5, weight: .bold, color: accent)
        drawText(detail, at: NSPoint(x: badgeRect.maxX + 14, y: 8.5), size: 11.5, weight: .medium, color: .white, mono: true)
    }

    // MARK: - Full-Width Expanded Live Telemetry Inspectors (1004x30pt)
    private func drawInspectorHUD(ctx: CGContext, kind: InspectorKind) {
        let h = bounds.height
        let badgeW: CGFloat = 56
        let badgeRect = CGRect(x: 6, y: 4, width: badgeW, height: h - 8)
        let closeW: CGFloat = 28
        let closeRect = NSRect(x: bounds.width - 6 - closeW, y: 3, width: closeW, height: h - 6)
        let contentRect = NSRect(x: badgeRect.maxX + 8, y: 0, width: max(200, closeRect.minX - badgeRect.maxX - 16), height: h)

        let title: String
        let accent: NSColor
        switch kind {
        case .cpu:
            title = "CPU"
            accent = metrics.cpuTotal >= 85
                ? NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.34, alpha: 1.0)
                : (metrics.cpuTotal >= 55
                    ? NSColor(calibratedRed: 0.99, green: 0.65, blue: 0.22, alpha: 1.0)
                    : NSColor(calibratedRed: 0.24, green: 0.82, blue: 0.98, alpha: 1.0))
        case .ram:
            title = "RAM"
            accent = NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)
        case .thermal:
            title = "THERM"
            accent = tempColor(for: metrics.socTempC)
        case .power:
            title = "POWER"
            accent = NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.24, alpha: 1.0)
        case .network:
            title = "NET"
            accent = NSColor(calibratedRed: 0.65, green: 0.55, blue: 0.98, alpha: 1.0)
        }

        // Left Accent Pill Badge
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(accent.withAlphaComponent(0.20).cgColor)
        ctx.addPath(badgePath)
        ctx.fillPath()
        ctx.setStrokeColor(accent.withAlphaComponent(0.80).cgColor)
        ctx.setLineWidth(0.9)
        ctx.addPath(badgePath)
        ctx.strokePath()
        ctx.restoreGState()
        drawTextCentered(title, centerX: badgeRect.midX, y: 9.0, size: 9.5, weight: .bold, color: accent)

        // Right Compact Close Button
        drawMediaButton(ctx: ctx, rect: closeRect, symbol: "xmark", pressed: false, accent: nil)

        switch kind {
        case .cpu:
            drawCPUInspector(ctx: ctx, rect: contentRect, accent: accent)
        case .ram:
            drawRAMInspector(ctx: ctx, rect: contentRect, accent: accent)
        case .thermal:
            drawThermalInspector(ctx: ctx, rect: contentRect, accent: accent)
        case .power:
            drawPowerInspector(ctx: ctx, rect: contentRect, accent: accent)
        case .network:
            drawNetworkInspector(ctx: ctx, rect: contentRect, accent: accent)
        }
    }

    private func tempColor(for temp: Double) -> NSColor {
        if temp < 0 { return NSColor(calibratedWhite: 0.55, alpha: 1.0) }
        if temp >= 80 { return NSColor(calibratedRed: 1.0, green: 0.32, blue: 0.32, alpha: 1.0) }
        if temp >= 62 { return NSColor(calibratedRed: 0.99, green: 0.66, blue: 0.22, alpha: 1.0) }
        if temp >= 48 { return NSColor(calibratedRed: 0.26, green: 0.85, blue: 0.62, alpha: 1.0) }
        return NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.99, alpha: 1.0)
    }

    private func drawExpandedGraph(
        ctx: CGContext,
        values: [Double],
        secondaryValues: [Double]? = nil,
        minValue: Double = 0,
        maxValue: Double,
        rect: CGRect,
        strokeColor: NSColor,
        secondaryColor: NSColor? = nil,
        fillAlpha: CGFloat = 0.26,
        guideFrac: CGFloat? = 0.5,
        leftTag: String? = nil,
        rightTag: String? = nil,
        rightTagColor: NSColor? = nil
    ) {
        let bgPath = CGPath(roundedRect: rect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.addPath(bgPath)
        ctx.clip()

        if let gf = guideFrac {
            let gy = rect.minY + rect.height * gf
            ctx.setStrokeColor(NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)
            ctx.setLineWidth(0.5)
            ctx.setLineDash(phase: 0, lengths: [2, 2])
            ctx.move(to: CGPoint(x: rect.minX, y: gy))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: gy))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        let span = max(0.0001, maxValue - minValue)
        let inner = rect.insetBy(dx: 1, dy: 1)

        if values.count >= 2 {
            let stepX = inner.width / CGFloat(values.count - 1)
            let linePath = CGMutablePath()
            let fillPath = CGMutablePath()
            for (i, v) in values.enumerated() {
                let x = inner.minX + CGFloat(i) * stepX
                let norm = CGFloat(min(1.0, max(0.0, (v - minValue) / span)))
                let y = inner.minY + norm * (inner.height - 1.5) + 0.5
                if i == 0 {
                    linePath.move(to: CGPoint(x: x, y: y))
                    fillPath.move(to: CGPoint(x: x, y: inner.minY))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                } else {
                    linePath.addLine(to: CGPoint(x: x, y: y))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                }
            }
            fillPath.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
            fillPath.closeSubpath()

            ctx.setFillColor(strokeColor.withAlphaComponent(fillAlpha).cgColor)
            ctx.addPath(fillPath)
            ctx.fillPath()

            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(1.4)
            ctx.setLineJoin(.round)
            ctx.addPath(linePath)
            ctx.strokePath()
        }

        if let sec = secondaryValues, let secColor = secondaryColor, sec.count >= 2 {
            let stepX = inner.width / CGFloat(sec.count - 1)
            let linePath = CGMutablePath()
            for (i, v) in sec.enumerated() {
                let x = inner.minX + CGFloat(i) * stepX
                let norm = CGFloat(min(1.0, max(0.0, (v - minValue) / span)))
                let y = inner.minY + norm * (inner.height - 1.5) + 0.5
                if i == 0 { linePath.move(to: CGPoint(x: x, y: y)) }
                else { linePath.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.setStrokeColor(secColor.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(1.25)
            ctx.setLineJoin(.round)
            ctx.addPath(linePath)
            ctx.strokePath()
        }

        ctx.restoreGState()

        if let lt = leftTag {
            let font = Self.cachedFont(size: 7.5, weight: .semibold, mono: true)
            let tw = (lt as NSString).size(withAttributes: [.font: font]).width
            let pill = CGRect(x: rect.minX + 2.5, y: rect.maxY - 10.5, width: tw + 5, height: 9.0)
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            drawText(lt, at: NSPoint(x: rect.minX + 5.0, y: rect.maxY - 10.5), size: 7.5, weight: .semibold, color: NSColor(calibratedWhite: 0.62, alpha: 1.0), mono: true)
        }
        if let rt = rightTag {
            let font = Self.cachedFont(size: 7.5, weight: .bold, mono: true)
            let tw = (rt as NSString).size(withAttributes: [.font: font]).width
            let pill = CGRect(x: rect.maxX - tw - 7.5, y: rect.maxY - 10.5, width: tw + 5, height: 9.0)
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            drawTextRight(rt, rightX: rect.maxX - 5.0, y: rect.maxY - 10.5, size: 7.5, weight: .bold, color: rightTagColor ?? strokeColor, mono: true)
        }
    }

    private func drawTopProcessColumn(ctx: CGContext, rect: NSRect, rows: [(name: String, value: String)], accent: NSColor, emptyText: String) {
        if rows.isEmpty {
            drawTextCentered(isFetchingTopProcesses ? "Scanning…" : emptyText, centerX: rect.midX, y: 10.5, size: 8.5, weight: .medium, color: NSColor(calibratedWhite: 0.48, alpha: 1.0))
            return
        }
        let ys: [CGFloat] = [20.0, 10.5, 1.0]
        let nameMaxW = max(50, rect.width - 52)
        for (i, row) in rows.prefix(3).enumerated() {
            let y = ys[i]
            let rankColor = NSColor(calibratedWhite: i == 0 ? 0.62 : 0.42, alpha: 1.0)
            let nameColor = NSColor(calibratedWhite: i == 0 ? 0.94 : 0.72, alpha: 1.0)
            let valColor = (i == 0) ? accent : accent.withAlphaComponent(0.75)

            drawText("\(i + 1)", at: NSPoint(x: rect.minX, y: y), size: 7.8, weight: .bold, color: rankColor, mono: true)
            let cleanName = (row.name as NSString).lastPathComponent
            let trimmed = truncateText(cleanName, maxWidth: nameMaxW, size: 8.0, weight: i == 0 ? .semibold : .medium)
            drawText(trimmed, at: NSPoint(x: rect.minX + 10, y: y), size: 8.0, weight: i == 0 ? .semibold : .medium, color: nameColor)
            drawTextRight(row.value, rightX: rect.maxX, y: y, size: 8.0, weight: .bold, color: valColor, mono: true)
        }
    }

    // MARK: - 1. CPU Expanded Inspector (Total/Usr/Sys + 48s Graph + Per-Core E/P Grid + Top 3)
    private func drawCPUInspector(ctx: CGContext, rect: NSRect, accent: NSColor) {
        let w = rect.width
        let x0 = rect.minX
        let cyan = NSColor(calibratedRed: 0.24, green: 0.82, blue: 0.98, alpha: 1.0)
        let orange = NSColor(calibratedRed: 0.99, green: 0.62, blue: 0.22, alpha: 1.0)

        let z1W = floor(w * 0.180) // Overall + User/Sys + Load
        let z2W = floor(w * 0.245) // Expanded 48s Sparkline
        let z3W = floor(w * 0.325) // Per-core live breakdown
        let z4W = w - z1W - z2W - z3W // Top 3 CPU processes

        // Zone 1: Overall Load + User/Sys Split + 1m Load Avg
        let z1 = NSRect(x: x0, y: 0, width: z1W - 6, height: rect.height)
        drawText(String(format: "%.0f%%", metrics.cpuTotal), at: NSPoint(x: z1.minX, y: 15.5), size: 12, weight: .bold, color: accent, mono: true)
        let usrSys = String(format: "U%.0f S%.0f", metrics.cpuUser, metrics.cpuSystem)
        drawTextRight(usrSys, rightX: z1.maxX, y: 17.0, size: 8.5, weight: .semibold, color: NSColor(calibratedWhite: 0.72, alpha: 1.0), mono: true)

        // Stacked User (cyan) + System (orange) bar + 1m Load Avg
        let barW = max(44, z1.width - 54)
        let barRect = CGRect(x: z1.minX, y: 6.0, width: barW, height: 5.5)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: 2.75, cornerHeight: 2.75, transform: nil)
        ctx.saveGState()
        ctx.addPath(barPath)
        ctx.clip()
        ctx.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor)
        ctx.fill(barRect)
        let uFrac = CGFloat(min(1.0, max(0.0, metrics.cpuUser / 100.0)))
        let sFrac = CGFloat(min(1.0 - uFrac, max(0.0, metrics.cpuSystem / 100.0)))
        ctx.setFillColor(cyan.cgColor)
        ctx.fill(CGRect(x: barRect.minX, y: barRect.minY, width: barRect.width * uFrac, height: barRect.height))
        ctx.setFillColor(orange.cgColor)
        ctx.fill(CGRect(x: barRect.minX + barRect.width * uFrac, y: barRect.minY, width: barRect.width * sFrac, height: barRect.height))
        ctx.restoreGState()

        drawTextRight(String(format: "LD %.2f", metrics.loadAvg1m), rightX: z1.maxX, y: 4.0, size: 8.2, weight: .medium, color: NSColor(calibratedWhite: 0.56, alpha: 1.0), mono: true)
        drawDivider(ctx: ctx, x: x0 + z1W - 2, height: rect.height)

        // Zone 2: Expanded 48s CPU History Graph
        let z2 = CGRect(x: x0 + z1W + 4, y: 3, width: z2W - 10, height: rect.height - 6)
        let peakCPU = metrics.cpuHistory.max() ?? metrics.cpuTotal
        drawExpandedGraph(
            ctx: ctx,
            values: metrics.cpuHistory,
            maxValue: 100.0,
            rect: z2,
            strokeColor: accent,
            fillAlpha: 0.28,
            guideFrac: 0.5,
            leftTag: "48s",
            rightTag: String(format: "PK %.0f%%", peakCPU)
        )
        drawDivider(ctx: ctx, x: x0 + z1W + z2W - 2, height: rect.height)

        // Zone 3: Per-Core Live E/P Breakdown Grid
        let z3 = NSRect(x: x0 + z1W + z2W + 5, y: 0, width: z3W - 12, height: rect.height)
        let loads = metrics.coreLoads
        let count = loads.count
        if count > 0 {
            let eCount = min(metrics.eCoreCount, count)
            let hasClusterGap = (eCount > 0 && eCount < count)
            let clusterGap: CGFloat = hasClusterGap ? 6.0 : 0.0
            let colGap: CGFloat = count <= 10 ? 3.5 : 2.0
            let totalGaps = CGFloat(max(0, count - 1)) * colGap + clusterGap
            let colW = max(12, (z3.width - totalGaps) / CGFloat(count))
            let showPctSign = colW >= 26

            var cx = z3.minX
            for i in 0..<count {
                if hasClusterGap && i == eCount {
                    // Subtle hairline between E-cores and P-cores
                    ctx.saveGState()
                    ctx.setFillColor(NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)
                    ctx.fill(CGRect(x: cx + 1.0, y: 5, width: 1, height: rect.height - 10))
                    ctx.restoreGState()
                    cx += clusterGap
                }
                let load = loads[i]
                let isE = i < eCount
                let baseColor = isE ? cyan : orange
                let coreColor = load >= 85 ? NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.34, alpha: 1.0) : baseColor
                let pctStr = showPctSign ? String(format: "%.0f%%", load) : String(format: "%.0f", load)
                let labelStr = isE ? "E\(i + 1)" : "P\(i - eCount + 1)"

                drawTextCentered(pctStr, centerX: cx + colW / 2.0, y: 18.0, size: colW >= 24 ? 8.2 : 7.2, weight: .bold, color: coreColor, mono: true)
                drawRoundedBar(ctx: ctx, rect: CGRect(x: cx + 1, y: 11.5, width: max(8, colW - 2), height: 4.5), fraction: CGFloat(load / 100.0), fillColor: coreColor)
                drawTextCentered(labelStr, centerX: cx + colW / 2.0, y: 1.5, size: 7.2, weight: .semibold, color: NSColor(calibratedWhite: 0.50, alpha: 1.0), mono: true)

                cx += colW + colGap
            }
        }
        drawDivider(ctx: ctx, x: x0 + z1W + z2W + z3W - 2, height: rect.height)

        // Zone 4: Rightmost Top-3 CPU Processes
        let z4 = NSRect(x: x0 + z1W + z2W + z3W + 5, y: 0, width: max(80, z4W - 5), height: rect.height)
        let rows = topCPUProcesses.map { (name: $0.name, value: String(format: "%.0f%%", $0.pct)) }
        drawTopProcessColumn(ctx: ctx, rect: z4, rows: rows, accent: orange, emptyText: "No CPU procs")
    }

    // MARK: - 2. RAM Expanded Inspector (Used/Total + App/Wired/Comp/Cache/Swap + 48s Graph + Top 3)
    private func drawRAMInspector(ctx: CGContext, rect: NSRect, accent: NSColor) {
        let w = rect.width
        let x0 = rect.minX
        let green = NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)
        let blue = NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.98, alpha: 1.0)
        let amber = NSColor(calibratedRed: 0.98, green: 0.73, blue: 0.22, alpha: 1.0)
        let purple = NSColor(calibratedRed: 0.66, green: 0.56, blue: 0.92, alpha: 1.0)
        let coral = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.38, alpha: 1.0)

        let z1W = floor(w * 0.195) // Total + Segmented Bar
        let z2W = floor(w * 0.290) // 3x2 Breakdown Grid
        let z3W = floor(w * 0.265) // 48s History Graph
        let z4W = w - z1W - z2W - z3W // Top 3 RAM Processes

        // Zone 1: Used / Total + 4-Segment Bar
        let z1 = NSRect(x: x0, y: 0, width: z1W - 6, height: rect.height)
        let pct = metrics.memTotalGB > 0 ? (metrics.memUsedGB / metrics.memTotalGB) * 100.0 : 0
        drawText(String(format: "%.1f", metrics.memUsedGB), at: NSPoint(x: z1.minX, y: 15.5), size: 11.5, weight: .bold, color: green, mono: true)
        drawText(String(format: "/%.0fG", metrics.memTotalGB), at: NSPoint(x: z1.minX + 33, y: 16.5), size: 9.0, weight: .medium, color: NSColor(calibratedWhite: 0.54, alpha: 1.0), mono: true)
        drawTextRight(String(format: "%.0f%%", pct), rightX: z1.maxX, y: 16.0, size: 10.0, weight: .bold, color: pct >= 85 ? coral : NSColor(calibratedWhite: 0.88, alpha: 1.0), mono: true)

        let barRect = CGRect(x: z1.minX, y: 5.5, width: z1.width, height: 6.5)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: 3.25, cornerHeight: 3.25, transform: nil)
        ctx.saveGState()
        ctx.addPath(barPath)
        ctx.clip()
        ctx.setFillColor(NSColor(calibratedWhite: 0.15, alpha: 1.0).cgColor)
        ctx.fill(barRect)
        let cacheFrac = metrics.memTotalGB > 0 ? min(1.0, metrics.memCachedGB / metrics.memTotalGB) : 0
        var sx = barRect.minX
        for (frac, col) in [(CGFloat(metrics.memActiveFrac), green), (CGFloat(metrics.memWiredFrac), blue), (CGFloat(metrics.memCompressedFrac), amber), (CGFloat(cacheFrac), purple.withAlphaComponent(0.55))] {
            let sw = max(0, min(barRect.maxX - sx, barRect.width * frac))
            if sw > 0.5 {
                ctx.setFillColor(col.cgColor)
                ctx.fill(CGRect(x: sx, y: barRect.minY, width: sw, height: barRect.height))
                sx += sw
            }
        }
        ctx.restoreGState()
        drawDivider(ctx: ctx, x: x0 + z1W - 2, height: rect.height)

        // Zone 2: Detailed 3x2 Breakdown Grid (App, Wired, Compressed, Cached, Free, Swap)
        let z2 = NSRect(x: x0 + z1W + 5, y: 0, width: z2W - 11, height: rect.height)
        let colW = z2.width / 3.0
        let freeGB = max(0, metrics.memTotalGB - metrics.memUsedGB)
        let items: [(Int, Int, String, String, NSColor)] = [
            (0, 0, "APP", String(format: "%.1fG", metrics.memAppGB), green),
            (0, 1, "WIR", String(format: "%.1fG", metrics.memWiredGB), blue),
            (1, 0, "CMP", String(format: "%.1fG", metrics.memCompressedGB), amber),
            (1, 1, "CCH", String(format: "%.1fG", metrics.memCachedGB), purple),
            (2, 0, "FRE", String(format: "%.1fG", freeGB), NSColor(calibratedWhite: 0.85, alpha: 1.0)),
            (2, 1, "SWP", String(format: "%.1fG", metrics.swapUsedGB), metrics.swapUsedGB > 0.05 ? coral : NSColor(calibratedWhite: 0.48, alpha: 1.0))
        ]
        for (col, row, tag, val, color) in items {
            let cx = z2.minX + CGFloat(col) * colW
            let y: CGFloat = (row == 0) ? 16.5 : 4.0
            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx, y: y + 3.0, width: 4.5, height: 4.5))
            ctx.restoreGState()
            drawText(tag, at: NSPoint(x: cx + 7, y: y + 0.5), size: 7.8, weight: .semibold, color: NSColor(calibratedWhite: 0.54, alpha: 1.0), mono: true)
            drawText(val, at: NSPoint(x: cx + 31, y: y), size: 8.8, weight: .bold, color: color, mono: true)
        }
        drawDivider(ctx: ctx, x: x0 + z1W + z2W - 2, height: rect.height)

        // Zone 3: Expanded 48s RAM History Graph
        let z3 = CGRect(x: x0 + z1W + z2W + 4, y: 3, width: z3W - 10, height: rect.height - 6)
        let peakRAM = metrics.memHistory.max() ?? pct
        drawExpandedGraph(
            ctx: ctx,
            values: metrics.memHistory,
            maxValue: 100.0,
            rect: z3,
            strokeColor: green,
            fillAlpha: 0.26,
            guideFrac: 0.75,
            leftTag: "48s",
            rightTag: String(format: "PK %.0f%%", peakRAM)
        )
        drawDivider(ctx: ctx, x: x0 + z1W + z2W + z3W - 2, height: rect.height)

        // Zone 4: Rightmost Top-3 RAM Processes
        let z4 = NSRect(x: x0 + z1W + z2W + z3W + 5, y: 0, width: max(80, z4W - 5), height: rect.height)
        let rows = topRAMProcesses.map { proc -> (name: String, value: String) in
            let v = proc.mb >= 1024 ? String(format: "%.1fG", proc.mb / 1024.0) : String(format: "%.0fM", proc.mb)
            return (name: proc.name, value: v)
        }
        drawTopProcessColumn(ctx: ctx, rect: z4, rows: rows, accent: green, emptyText: "No RAM procs")
    }

    // MARK: - 3. M2 Thermal & Fan Expanded Inspector (Die Avg/Peak + P/E/SoC Clusters + Temp Graph + Fan Gauge)
    private func drawThermalInspector(ctx: CGContext, rect: NSRect, accent: NSColor) {
        let w = rect.width
        let x0 = rect.minX

        let z1W = floor(w * 0.195) // Die Avg + Peak + Thermal State
        let z2W = floor(w * 0.245) // P-Core / E-Core / SoC Cluster Temps
        let z3W = floor(w * 0.290) // Thermal History Sparkline
        let z4W = w - z1W - z2W - z3W // Fan Telemetry Gauge

        // Zone 1: Avg & Peak + Thermal State
        let z1 = NSRect(x: x0, y: 0, width: z1W - 6, height: rect.height)
        let avgStr = metrics.socTempC > 0 ? String(format: "%.0f°C", metrics.socTempC) : "--°C"
        drawText(avgStr, at: NSPoint(x: z1.minX, y: 15.5), size: 12, weight: .bold, color: accent, mono: true)
        if metrics.socPeakTempC > 0 {
            drawTextRight(String(format: "PK %.0f°", metrics.socPeakTempC), rightX: z1.maxX, y: 16.5, size: 9.0, weight: .semibold, color: tempColor(for: metrics.socPeakTempC), mono: true)
        }

        let (stateLabel, stateColor): (String, NSColor) = {
            switch metrics.thermalStateRaw {
            case 0: return ("NOMINAL", NSColor(calibratedRed: 0.24, green: 0.88, blue: 0.56, alpha: 1.0))
            case 1: return ("FAIR", NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.22, alpha: 1.0))
            case 2: return ("SERIOUS", NSColor(calibratedRed: 0.99, green: 0.54, blue: 0.20, alpha: 1.0))
            default: return ("CRITICAL", NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.30, alpha: 1.0))
            }
        }()
        drawText(stateLabel, at: NSPoint(x: z1.minX, y: 4.5), size: 8.2, weight: .bold, color: stateColor, mono: true)
        if metrics.batteryTempC > 0 {
            drawTextRight(String(format: "BAT %.0f°", metrics.batteryTempC), rightX: z1.maxX, y: 4.5, size: 8.2, weight: .medium, color: NSColor(calibratedWhite: 0.56, alpha: 1.0), mono: true)
        }
        drawDivider(ctx: ctx, x: x0 + z1W - 2, height: rect.height)

        // Zone 2: Cluster Temps (P-Core, E-Core, SoC Die)
        let z2 = NSRect(x: x0 + z1W + 5, y: 0, width: z2W - 11, height: rect.height)
        let clusters: [(String, Double)] = [
            ("P-CORE", metrics.pCoreTempC > 0 ? metrics.pCoreTempC : metrics.socPeakTempC),
            ("E-CORE", metrics.eCoreTempC > 0 ? metrics.eCoreTempC : metrics.socTempC),
            ("SoC DIE", metrics.socClusterTempC > 0 ? metrics.socClusterTempC : metrics.socTempC)
        ]
        let colGap: CGFloat = 6
        let colW = (z2.width - colGap * 2) / 3.0
        for (i, (label, t)) in clusters.enumerated() {
            let cx = z2.minX + CGFloat(i) * (colW + colGap)
            let col = tempColor(for: t)
            let tStr = t > 0 ? String(format: "%.0f°C", t) : "--"
            drawTextCentered(tStr, centerX: cx + colW / 2.0, y: 18.0, size: 9.0, weight: .bold, color: col, mono: true)
            let frac = t > 0 ? CGFloat(min(1.0, max(0.0, (t - 25.0) / 75.0))) : 0
            drawRoundedBar(ctx: ctx, rect: CGRect(x: cx, y: 11.5, width: colW, height: 4.5), fraction: frac, fillColor: col)
            drawTextCentered(label, centerX: cx + colW / 2.0, y: 1.5, size: 7.2, weight: .semibold, color: NSColor(calibratedWhite: 0.52, alpha: 1.0), mono: true)
        }
        drawDivider(ctx: ctx, x: x0 + z1W + z2W - 2, height: rect.height)

        // Zone 3: Expanded Thermal History Graph
        let z3 = CGRect(x: x0 + z1W + z2W + 4, y: 3, width: z3W - 10, height: rect.height - 6)
        let validTemps = metrics.tempHistory.filter { $0 > 0 }
        let minT = validTemps.min() ?? max(30, metrics.socTempC)
        let maxT = validTemps.max() ?? max(30, metrics.socTempC)
        drawExpandedGraph(
            ctx: ctx,
            values: metrics.tempHistory,
            minValue: 25.0,
            maxValue: 100.0,
            rect: z3,
            strokeColor: accent,
            fillAlpha: 0.25,
            guideFrac: (65.0 - 25.0) / 75.0,
            leftTag: validTemps.isEmpty ? "TEMP" : String(format: "LO %.0f°", minT),
            rightTag: validTemps.isEmpty ? nil : String(format: "HI %.0f°", maxT)
        )
        drawDivider(ctx: ctx, x: x0 + z1W + z2W + z3W - 2, height: rect.height)

        // Zone 4: Fan Telemetry Gauge
        let z4 = NSRect(x: x0 + z1W + z2W + z3W + 6, y: 0, width: max(100, z4W - 6), height: rect.height)
        let fanColor = metrics.fanRPM > 4000
            ? NSColor(calibratedRed: 0.99, green: 0.62, blue: 0.24, alpha: 1.0)
            : NSColor(calibratedRed: 0.56, green: 0.66, blue: 0.98, alpha: 1.0)
        if metrics.fanAvailable {
            let fanPct = metrics.fanMaxRPM > 0 ? min(100, Int(round((metrics.fanRPM / metrics.fanMaxRPM) * 100.0))) : 0
            let rpmText = metrics.fanRPM < 100 ? "FAN 0 RPM (SILENT)" : String(format: "FAN %.0f RPM", metrics.fanRPM)
            drawText(rpmText, at: NSPoint(x: z4.minX, y: 16.0), size: 9.5, weight: .bold, color: metrics.fanRPM < 100 ? NSColor(calibratedWhite: 0.56, alpha: 1.0) : fanColor, mono: true)
            drawTextRight("\(fanPct)%", rightX: z4.maxX, y: 16.0, size: 9.5, weight: .bold, color: fanColor, mono: true)

            let barW = max(60, z4.width - 54)
            let frac = metrics.fanMaxRPM > 0 ? CGFloat(min(1.0, max(0.0, metrics.fanRPM / metrics.fanMaxRPM))) : 0
            drawRoundedBar(ctx: ctx, rect: CGRect(x: z4.minX, y: 6.0, width: barW, height: 6.0), fraction: frac, fillColor: fanColor)
            drawTextRight(String(format: "MAX %.1fk", metrics.fanMaxRPM / 1000.0), rightX: z4.maxX, y: 4.0, size: 8.0, weight: .medium, color: NSColor(calibratedWhite: 0.50, alpha: 1.0), mono: true)
        } else {
            drawText("FAN PASSIVE", at: NSPoint(x: z4.minX, y: 16.0), size: 9.5, weight: .bold, color: NSColor(calibratedWhite: 0.56, alpha: 1.0), mono: true)
            drawText("No active cooling fan detected", at: NSPoint(x: z4.minX, y: 4.5), size: 8.0, weight: .medium, color: NSColor(calibratedWhite: 0.42, alpha: 1.0))
        }
    }

    // MARK: - 4. Power & Battery Expanded Inspector (Sys/In/Batt Flow + 48s Watt Graph + Battery + Health/Cycles)
    private func drawPowerInspector(ctx: CGContext, rect: NSRect, accent: NSColor) {
        let w = rect.width
        let x0 = rect.minX
        let cyan = NSColor(calibratedRed: 0.28, green: 0.84, blue: 0.98, alpha: 1.0)
        let green = NSColor(calibratedRed: 0.24, green: 0.90, blue: 0.54, alpha: 1.0)
        let amber = NSColor(calibratedRed: 0.99, green: 0.68, blue: 0.24, alpha: 1.0)
        let red = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.34, alpha: 1.0)

        let z1W = floor(w * 0.245) // Live Wattage Flow
        let z2W = floor(w * 0.320) // Expanded 48s Power Graph
        let z3W = floor(w * 0.230) // Battery % + Gauge + Time
        let z4W = w - z1W - z2W - z3W // Health / Cycles / V / Temp

        let sysColor = metrics.powerWatts >= 20 ? red : (metrics.powerWatts >= 12 ? amber : cyan)

        // Zone 1: Live Power Flow (SYS / IN / BATT / PD)
        let z1 = NSRect(x: x0, y: 0, width: z1W - 6, height: rect.height)
        drawText("SYS", at: NSPoint(x: z1.minX, y: 17.0), size: 8.2, weight: .semibold, color: NSColor(calibratedWhite: 0.52, alpha: 1.0))
        drawText(String(format: "%.1fW", metrics.powerWatts), at: NSPoint(x: z1.minX + 24, y: 16.0), size: 10.5, weight: .bold, color: sysColor, mono: true)
        let inColor = metrics.isPluggedIn ? green : NSColor(calibratedWhite: 0.42, alpha: 1.0)
        drawTextRight(String(format: "%@ %.1fW", metrics.isPluggedIn ? "⚡IN" : "IN", metrics.chargerInWatts), rightX: z1.maxX, y: 16.0, size: 9.5, weight: .bold, color: inColor, mono: true)

        let battFlowColor = metrics.batteryNetWatts >= 0.1 ? green : (metrics.batteryNetWatts <= -0.1 ? amber : NSColor(calibratedWhite: 0.55, alpha: 1.0))
        drawText(String(format: "BATT %+.1fW", metrics.batteryNetWatts), at: NSPoint(x: z1.minX, y: 4.0), size: 8.8, weight: .semibold, color: battFlowColor, mono: true)
        let adapterStr = metrics.isPluggedIn
            ? (metrics.adapterMaxWatts > 0 ? "\(metrics.adapterMaxWatts)W PD" : "AC POWER")
            : "ON BATT"
        drawTextRight(adapterStr, rightX: z1.maxX, y: 4.5, size: 8.2, weight: .semibold, color: NSColor(calibratedWhite: 0.58, alpha: 1.0), mono: true)
        drawDivider(ctx: ctx, x: x0 + z1W - 2, height: rect.height)

        // Zone 2: Expanded 48s Power Draw + Charger In Graph
        let z2 = CGRect(x: x0 + z1W + 4, y: 3, width: z2W - 10, height: rect.height - 6)
        let peakDraw = metrics.powerHistory.max() ?? metrics.powerWatts
        let peakIn = metrics.isPluggedIn ? (metrics.chargerInHistory.max() ?? metrics.chargerInWatts) : 0
        let maxW = max(15.0, max(peakDraw, peakIn) * 1.15)
        drawExpandedGraph(
            ctx: ctx,
            values: metrics.powerHistory,
            secondaryValues: metrics.isPluggedIn ? metrics.chargerInHistory : nil,
            maxValue: maxW,
            rect: z2,
            strokeColor: sysColor,
            secondaryColor: green,
            fillAlpha: 0.25,
            guideFrac: 0.5,
            leftTag: "DRAW 48s",
            rightTag: String(format: "PK %.1fW", peakDraw),
            rightTagColor: sysColor
        )
        drawDivider(ctx: ctx, x: x0 + z1W + z2W - 2, height: rect.height)

        // Zone 3: Battery Percentage + Wide Gauge + Time Remaining
        let z3 = NSRect(x: x0 + z1W + z2W + 6, y: 0, width: z3W - 12, height: rect.height)
        let battColor = (metrics.batteryPercent <= 15 && !metrics.isPluggedIn) ? red : (metrics.isCharging ? green : NSColor(calibratedWhite: 0.88, alpha: 1.0))
        drawText("\(metrics.batteryPercent)%", at: NSPoint(x: z3.minX, y: 15.5), size: 11.5, weight: .bold, color: battColor, mono: true)
        let statusStr = metrics.isCharging ? "CHARGING" : (metrics.isPluggedIn ? "PLUGGED" : "BATTERY")
        drawText(statusStr, at: NSPoint(x: z3.minX + 38, y: 17.0), size: 8.0, weight: .semibold, color: NSColor(calibratedWhite: 0.56, alpha: 1.0))
        if let mins = metrics.minutesRemaining {
            let remStr = String(format: "%dh%02dm", mins / 60, mins % 60)
            drawTextRight(remStr, rightX: z3.maxX, y: 16.5, size: 8.8, weight: .bold, color: battColor, mono: true)
        }
        drawRoundedBar(ctx: ctx, rect: CGRect(x: z3.minX, y: 5.5, width: z3.width, height: 6.5), fraction: CGFloat(metrics.batteryPercent) / 100.0, fillColor: battColor)
        drawDivider(ctx: ctx, x: x0 + z1W + z2W + z3W - 2, height: rect.height)

        // Zone 4: Battery Health, Cycles, Voltage & Battery Temp
        let z4 = NSRect(x: x0 + z1W + z2W + z3W + 6, y: 0, width: max(90, z4W - 6), height: rect.height)
        let healthStr = metrics.batteryHealthPct > 0 ? "HLTH \(metrics.batteryHealthPct)%" : "HLTH --"
        let healthColor = metrics.batteryHealthPct >= 85 ? green : (metrics.batteryHealthPct >= 75 ? accent : red)
        drawText(healthStr, at: NSPoint(x: z4.minX, y: 16.5), size: 8.8, weight: .bold, color: metrics.batteryHealthPct > 0 ? healthColor : NSColor(calibratedWhite: 0.52, alpha: 1.0), mono: true)
        let cycStr = metrics.batteryCycleCount > 0 ? "\(metrics.batteryCycleCount) CYC" : "-- CYC"
        drawTextRight(cycStr, rightX: z4.maxX, y: 16.5, size: 8.5, weight: .medium, color: NSColor(calibratedWhite: 0.70, alpha: 1.0), mono: true)

        let voltStr = metrics.batteryVoltageV > 0 ? String(format: "%.2fV", metrics.batteryVoltageV) : "--V"
        drawText(voltStr, at: NSPoint(x: z4.minX, y: 4.0), size: 8.8, weight: .semibold, color: cyan, mono: true)
        let btStr = metrics.batteryTempC > 0 ? String(format: "%.1f°C", metrics.batteryTempC) : "--°C"
        drawTextRight(btStr, rightX: z4.maxX, y: 4.0, size: 8.5, weight: .semibold, color: tempColor(for: metrics.batteryTempC), mono: true)
    }

    // MARK: - 5. Network & Privacy Expanded Inspector (Down/Up + Dual Graph + Interface/Session Totals + Tunnel Pills)
    private func drawNetworkInspector(ctx: CGContext, rect: NSRect, accent: NSColor) {
        let w = rect.width
        let x0 = rect.minX
        let downColor = NSColor(calibratedRed: 0.24, green: 0.80, blue: 0.99, alpha: 1.0)
        let upColor = NSColor(calibratedRed: 0.68, green: 0.54, blue: 0.99, alpha: 1.0)

        let z1W = floor(w * 0.220) // Live Down/Up + Peak
        let z2W = floor(w * 0.365) // Expanded Dual Sparkline
        let z3W = floor(w * 0.235) // Interface/IP + Session Totals
        let z4W = w - z1W - z2W - z3W // TS / VPN / Proxy Pills

        // Zone 1: Live Throughput + Peaks
        let z1 = NSRect(x: x0, y: 0, width: z1W - 6, height: rect.height)
        let peakDown = metrics.netDownHistory.max() ?? metrics.netDownBps
        let peakUp = metrics.netUpHistory.max() ?? metrics.netUpBps
        drawText("↓ " + formatSpeed(metrics.netDownBps), at: NSPoint(x: z1.minX, y: 16.0), size: 10.0, weight: .bold, color: downColor, mono: true)
        drawTextRight("PK " + formatSpeedCompact(peakDown), rightX: z1.maxX, y: 17.0, size: 8.0, weight: .medium, color: downColor.withAlphaComponent(0.65), mono: true)

        drawText("↑ " + formatSpeed(metrics.netUpBps), at: NSPoint(x: z1.minX, y: 4.0), size: 9.5, weight: .bold, color: upColor, mono: true)
        drawTextRight("PK " + formatSpeedCompact(peakUp), rightX: z1.maxX, y: 4.5, size: 8.0, weight: .medium, color: upColor.withAlphaComponent(0.65), mono: true)
        drawDivider(ctx: ctx, x: x0 + z1W - 2, height: rect.height)

        // Zone 2: Expanded Dual Down + Up History Graph
        let z2 = CGRect(x: x0 + z1W + 4, y: 3, width: z2W - 10, height: rect.height - 6)
        let maxBps = max(64.0 * 1024.0, max(peakDown, peakUp) * 1.15)
        drawExpandedGraph(
            ctx: ctx,
            values: metrics.netDownHistory,
            secondaryValues: metrics.netUpHistory,
            maxValue: maxBps,
            rect: z2,
            strokeColor: downColor,
            secondaryColor: upColor,
            fillAlpha: 0.25,
            guideFrac: 0.5,
            leftTag: "↓/↑ 36s",
            rightTag: formatSpeed(maxBps),
            rightTagColor: NSColor(calibratedWhite: 0.62, alpha: 1.0)
        )
        drawDivider(ctx: ctx, x: x0 + z1W + z2W - 2, height: rect.height)

        // Zone 3: Primary Interface / Local IP + Session Totals
        let z3 = NSRect(x: x0 + z1W + z2W + 6, y: 0, width: z3W - 12, height: rect.height)
        let ifLabel = metrics.primaryInterface.isEmpty ? "OFFLINE" : metrics.primaryInterface.uppercased()
        drawText(ifLabel, at: NSPoint(x: z3.minX, y: 16.5), size: 8.8, weight: .bold, color: metrics.primaryInterface.isEmpty ? NSColor.systemRed : downColor, mono: true)
        let ipLabel = metrics.localIPv4.isEmpty ? "No IPv4" : metrics.localIPv4
        drawTextRight(ipLabel, rightX: z3.maxX, y: 16.5, size: 8.8, weight: .medium, color: NSColor(calibratedWhite: 0.84, alpha: 1.0), mono: true)

        let sessDown = formatBytesCompact(metrics.sessionDownBytes)
        let sessUp = formatBytesCompact(metrics.sessionUpBytes)
        drawText("Σ ↓\(sessDown)", at: NSPoint(x: z3.minX, y: 4.0), size: 8.5, weight: .semibold, color: downColor.withAlphaComponent(0.85), mono: true)
        drawTextRight("↑\(sessUp)", rightX: z3.maxX, y: 4.0, size: 8.5, weight: .semibold, color: upColor.withAlphaComponent(0.85), mono: true)
        drawDivider(ctx: ctx, x: x0 + z1W + z2W + z3W - 2, height: rect.height)

        // Zone 4: Privacy & Tunnel Status Pills (TS / VPN / PRX)
        let z4 = NSRect(x: x0 + z1W + z2W + z3W + 6, y: 0, width: max(90, z4W - 6), height: rect.height)
        let pills: [(String, Bool, NSColor)] = [
            ("TS", metrics.tailscaleActive, NSColor(calibratedRed: 0.18, green: 0.86, blue: 0.56, alpha: 1.0)),
            ("VPN", metrics.vpnActive, NSColor(calibratedRed: 0.99, green: 0.74, blue: 0.20, alpha: 1.0)),
            ("PRX", metrics.proxyActive, NSColor(calibratedRed: 0.24, green: 0.80, blue: 0.99, alpha: 1.0))
        ]
        let gap: CGFloat = 4
        let pillW = (z4.width - gap * 2) / 3.0
        for (i, (lbl, active, col)) in pills.enumerated() {
            let pr = CGRect(x: z4.minX + CGFloat(i) * (pillW + gap), y: 14.5, width: pillW, height: 12.5)
            let pPath = CGPath(roundedRect: pr, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            ctx.saveGState()
            ctx.setFillColor((active ? col.withAlphaComponent(0.24) : NSColor(calibratedWhite: 0.12, alpha: 1.0)).cgColor)
            ctx.addPath(pPath)
            ctx.fillPath()
            if active {
                ctx.setStrokeColor(col.withAlphaComponent(0.85).cgColor)
                ctx.setLineWidth(0.8)
                ctx.addPath(pPath)
                ctx.strokePath()
            }
            ctx.restoreGState()
            drawTextCentered(lbl, centerX: pr.midX, y: 16.0, size: 7.8, weight: .bold, color: active ? col : NSColor(calibratedWhite: 0.38, alpha: 1.0), mono: true)
        }

        let anyTunnel = metrics.tailscaleActive || metrics.vpnActive || metrics.proxyActive
        let statusTxt = anyTunnel ? "TUNNEL ACTIVE" : "DIRECT LINK"
        drawTextCentered(statusTxt, centerX: z4.midX, y: 3.0, size: 7.5, weight: .semibold, color: anyTunnel ? NSColor(calibratedRed: 0.20, green: 0.86, blue: 0.56, alpha: 0.9) : NSColor(calibratedWhite: 0.46, alpha: 1.0), mono: true)
    }

    private func formatBytesCompact(_ bytes: UInt64) -> String {
        let d = Double(bytes)
        if d >= 1024 * 1024 * 1024 {
            return String(format: "%.1fGB", d / (1024 * 1024 * 1024))
        } else if d >= 1024 * 1024 {
            return String(format: "%.0fMB", d / (1024 * 1024))
        } else if d >= 1024 {
            return String(format: "%.0fKB", d / 1024)
        } else {
            return "\(bytes)B"
        }
    }

    // MARK: - Full-Width Gentle Breathing Amber Flash (Coding Agent Turn Complete)
    private func drawAgentAmberFlash(ctx: CGContext, agent: String, elapsed: TimeInterval) {
        let duration: Double = 3.2
        let t = min(duration, max(0, elapsed))

        // Sustained 3-second envelope: smooth 0.25s ease-in, 2.5s luminous gentle pulse, 0.45s ease-out
        let envelope: Double
        if t < 0.25 {
            envelope = t / 0.25
        } else if t > 2.75 {
            envelope = max(0.0, (duration - t) / 0.45)
        } else {
            envelope = 1.0
        }
        // Gentle breathing modulation between 0.62 and 1.0 during the sustained window
        let wave = 0.81 + 0.19 * sin(.pi * 2.0 * (t - 0.25) / 1.25 - .pi / 2.0)
        let intensity = CGFloat(envelope * wave)

        // Warm OLED amber gradient across full 1004x30pt width
        let edgeAmber = NSColor(calibratedRed: 0.92, green: 0.46, blue: 0.04, alpha: 0.72 * intensity).cgColor
        let midAmber  = NSColor(calibratedRed: 0.99, green: 0.68, blue: 0.12, alpha: 0.92 * intensity).cgColor
        let cs = CGColorSpaceCreateDeviceRGB()

        ctx.saveGState()
        if let grad = CGGradient(colorsSpace: cs, colors: [edgeAmber, midAmber, edgeAmber] as CFArray, locations: [0.0, 0.5, 1.0]) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: bounds.minX, y: bounds.midY),
                end: CGPoint(x: bounds.maxX, y: bounds.midY),
                options: []
            )
        }

        // Subtle luminous top hairline
        ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.50, alpha: 0.90 * intensity).cgColor)
        ctx.fill(CGRect(x: 0, y: bounds.height - 1.5, width: bounds.width, height: 1.5))
        ctx.restoreGState()

        // Crisp centered pill label so you immediately know which harness is waiting
        let label = "✦  \(agent.uppercased()) WAITING FOR YOUR TURN"
        let pillW: CGFloat = 248
        let pillRect = CGRect(x: bounds.midX - pillW / 2.0, y: 5, width: pillW, height: 20)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.60 * CGFloat(envelope)).cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.restoreGState()

        let textColor = NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.65, alpha: CGFloat(envelope))
        drawTextCentered(label, centerX: bounds.midX, y: 8.5, size: 10, weight: .bold, color: textColor)
    }

    // MARK: - Interactive Long-Press Media Overlay
    private struct MediaOverlayRects {
        let prev: NSRect
        let playPause: NSRect
        let next: NSRect
        let meta: NSRect
        let scrubberHit: NSRect
        let scrubberTrack: CGRect
        let skipBack: NSRect
        let skipFwd: NSRect
        let jogHit: NSRect
        let jogTrack: CGRect
        let close: NSRect
    }

    private func mediaOverlayRects(for rect: NSRect) -> MediaOverlayRects {
        let padX: CGFloat = 8
        let h = rect.height
        let btnH: CGFloat = h - 4
        let btnY: CGFloat = 2

        let prevR = NSRect(x: padX, y: btnY, width: 48, height: btnH)
        let playR = NSRect(x: prevR.maxX + 4, y: btnY, width: 54, height: btnH)
        let nextR = NSRect(x: playR.maxX + 4, y: btnY, width: 48, height: btnH)

        let closeW: CGFloat = 38
        let closeR = NSRect(x: rect.width - padX - closeW, y: btnY, width: closeW, height: btnH)

        let metaX = nextR.maxX + 10
        let metaW: CGFloat = min(256, max(160, rect.width * 0.255))
        let metaR = NSRect(x: metaX, y: 0, width: metaW, height: h)

        let scrubAreaX = metaR.maxX + 10
        let scrubAreaW = max(120, closeR.minX - scrubAreaX - 10)
        let scrubHit = NSRect(x: scrubAreaX, y: 0, width: scrubAreaW, height: h)

        let timeLabelW: CGFloat = 34
        let trackX = scrubAreaX + timeLabelW + 6
        let trackW = max(40, scrubAreaW - (timeLabelW + 6) * 2)
        let trackR = CGRect(x: trackX, y: h / 2.0 - 4.0, width: trackW, height: 8.0)

        // Universal scrub controls: [-10s]  [◄ ───●─── ►]  [+10s]
        let skipW: CGFloat = 50
        let skipBackR = NSRect(x: scrubAreaX, y: btnY, width: skipW, height: btnH)
        let skipFwdR = NSRect(x: scrubHit.maxX - skipW, y: btnY, width: skipW, height: btnH)
        let jogHitR = NSRect(x: skipBackR.maxX + 8, y: 0, width: max(60, skipFwdR.minX - skipBackR.maxX - 16), height: h)
        let jogTrackR = CGRect(x: jogHitR.minX + 18, y: h / 2.0 - 3.5, width: max(40, jogHitR.width - 36), height: 7.0)

        return MediaOverlayRects(
            prev: prevR,
            playPause: playR,
            next: nextR,
            meta: metaR,
            scrubberHit: scrubHit,
            scrubberTrack: trackR,
            skipBack: skipBackR,
            skipFwd: skipFwdR,
            jogHit: jogHitR,
            jogTrack: jogTrackR,
            close: closeR
        )
    }

    private func scrubFraction(forX x: CGFloat, trackRect: CGRect) -> CGFloat {
        guard trackRect.width > 0 else { return 0 }
        return min(1.0, max(0.0, (x - trackRect.minX) / trackRect.width))
    }

    private func drawMediaOverlay(ctx: CGContext) {
        let r = mediaOverlayRects(for: bounds)
        let accent = NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.56, alpha: 1.0)
        let cyan = NSColor(calibratedRed: 0.24, green: 0.80, blue: 0.99, alpha: 1.0)

        // Transport Buttons: Prev · Play/Pause · Next
        drawMediaButton(ctx: ctx, rect: r.prev, symbol: "backward.fill", pressed: mediaPressedButton == .prev, accent: nil)
        drawMediaButton(
            ctx: ctx,
            rect: r.playPause,
            symbol: mediaState.isPlaying ? "pause.fill" : "play.fill",
            pressed: mediaPressedButton == .playPause,
            accent: accent
        )
        drawMediaButton(ctx: ctx, rect: r.next, symbol: "forward.fill", pressed: mediaPressedButton == .next, accent: nil)

        // Track Metadata: [26x26 Album Cover]  [Marquee Title / Artist]  [24x24 Playing App Logo]
        let textRect = mediaTextClipRect(metaRect: r.meta)

        if let art = mediaState.artwork {
            let artSize: CGFloat = 26
            let artRect = CGRect(x: r.meta.minX, y: (bounds.height - artSize) / 2.0, width: artSize, height: artSize)
            let artPath = CGPath(roundedRect: artRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
            ctx.saveGState()
            ctx.addPath(artPath)
            ctx.clip()
            art.draw(in: artRect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(0.75)
            ctx.addPath(artPath)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Right-side symmetric Playing App Logo (Apple Music / Spotify / Zen / IINA / VLC)
        if let appLogo = mediaState.appIcon {
            let logoSize: CGFloat = 24
            let logoRect = CGRect(x: r.meta.maxX - logoSize, y: (bounds.height - logoSize) / 2.0, width: logoSize, height: logoSize)
            appLogo.draw(in: logoRect)
        }

        // Marquee-scrolling Title & Subtitle (pauses 1.5s, then smoothly scrolls if overflowing!)
        let elapsedSinceOpen = max(0, CFAbsoluteTimeGetCurrent() - mediaOverlayStartTime)
        drawMarqueeText(
            ctx: ctx,
            text: mediaState.title,
            clipRect: CGRect(x: textRect.minX, y: 14.5, width: textRect.width, height: 14.5),
            y: 15.5,
            size: 10.5,
            weight: .semibold,
            color: .white,
            elapsed: elapsedSinceOpen
        )
        drawMarqueeText(
            ctx: ctx,
            text: mediaSubtitleText(),
            clipRect: CGRect(x: textRect.minX, y: 1.5, width: textRect.width, height: 13.0),
            y: 3.5,
            size: 8.5,
            weight: .medium,
            color: NSColor(calibratedWhite: 0.56, alpha: 1.0),
            elapsed: elapsedSinceOpen
        )

        // Interactive Media Scrubber
        if mediaState.canSeek && mediaState.duration > 0 {
            let curElapsed = isScrubbingMedia
                ? Double(scrubPreviewFraction) * mediaState.duration
                : mediaState.interpolatedElapsed()
            let frac = CGFloat(min(1.0, max(0.0, curElapsed / mediaState.duration)))

            // Elapsed & Duration labels
            drawTextRight(formatMediaTime(curElapsed), rightX: r.scrubberTrack.minX - 6, y: 9.5, size: 9.5, weight: .semibold, color: isScrubbingMedia ? accent : NSColor(calibratedWhite: 0.78, alpha: 1.0), mono: true)
            drawText(formatMediaTime(mediaState.duration), at: NSPoint(x: r.scrubberTrack.maxX + 6, y: 9.5), size: 9.5, weight: .medium, color: NSColor(calibratedWhite: 0.50, alpha: 1.0), mono: true)

            // Track + Filled Progress (Apple Touch Bar style progress scrubber)
            drawRoundedBar(ctx: ctx, rect: r.scrubberTrack, fraction: frac, fillColor: accent)

            // Apple-style vertical pill playhead indicator at current progress
            let thumbX = r.scrubberTrack.minX + r.scrubberTrack.width * frac
            let thumbW: CGFloat = isScrubbingMedia ? 5.5 : 4.0
            let thumbH: CGFloat = isScrubbingMedia ? 22.0 : 18.0
            let thumbRect = CGRect(x: thumbX - thumbW / 2.0, y: r.scrubberTrack.midY - thumbH / 2.0, width: thumbW, height: thumbH)
            let thumbPath = CGPath(roundedRect: thumbRect, cornerWidth: thumbW / 2.0, cornerHeight: thumbW / 2.0, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(thumbPath)
            ctx.fillPath()
            ctx.restoreGState()
        } else {
            // Universal Interactive Scrub Controls: [-10s] [◄ ───●─── ►] [+10s]
            drawMediaButton(ctx: ctx, rect: r.skipBack, symbol: "gobackward.10", pressed: mediaPressedButton == .skipBack, accent: nil)
            drawMediaButton(ctx: ctx, rect: r.skipFwd, symbol: "goforward.10", pressed: mediaPressedButton == .skipFwd, accent: nil)

            // Jog Track Background
            let trackPath = CGPath(roundedRect: r.jogTrack, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor)
            ctx.addPath(trackPath)
            ctx.fillPath()

            // Center tick + Directional Fill while scrubbing
            let midX = r.jogTrack.midX
            let thumbX = midX + (r.jogTrack.width / 2.0 - 6.0) * jogNormalizedOffset
            if abs(jogNormalizedOffset) > 0.02 {
                let fillX = min(midX, thumbX)
                let fillW = abs(thumbX - midX)
                let fillColor = jogNormalizedOffset >= 0 ? accent : cyan
                ctx.setFillColor(fillColor.cgColor)
                ctx.fill(CGRect(x: fillX, y: r.jogTrack.minY, width: fillW, height: r.jogTrack.height))
            }

            // Tick marks along jog scrubber
            ctx.setFillColor(NSColor(calibratedWhite: 0.30, alpha: 1.0).cgColor)
            for i in 1...7 {
                let tx = r.jogTrack.minX + r.jogTrack.width * CGFloat(i) / 8.0
                ctx.fill(CGRect(x: tx, y: r.jogTrack.minY + 1, width: 1, height: r.jogTrack.height - 2))
            }

            // Thumb Knob
            let thumbR: CGFloat = isScrubbingMedia ? 7.0 : 5.5
            let thumbColor = isScrubbingMedia ? (jogNormalizedOffset >= 0 ? accent : cyan) : NSColor.white
            ctx.setFillColor(thumbColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: thumbX - thumbR, y: r.jogTrack.midY - thumbR, width: thumbR * 2, height: thumbR * 2))
            ctx.restoreGState()

            // Side chevrons & live scrub delta label
            drawText("‹", at: NSPoint(x: r.jogHit.minX + 4, y: 8.0), size: 12, weight: .bold, color: NSColor(calibratedWhite: 0.45, alpha: 1.0))
            drawTextRight("›", rightX: r.jogHit.maxX - 4, y: 8.0, size: 12, weight: .bold, color: NSColor(calibratedWhite: 0.45, alpha: 1.0))
            if isScrubbingMedia && jogAccumulatedSec != 0 {
                let deltaLabel = String(format: "%+ds", jogAccumulatedSec)
                drawTextCentered(deltaLabel, centerX: r.jogTrack.midX, y: 18.0, size: 8.5, weight: .bold, color: jogAccumulatedSec > 0 ? accent : cyan, mono: true)
            }
        }

        // Close Button
        drawMediaButton(ctx: ctx, rect: r.close, symbol: "xmark", pressed: mediaPressedButton == .close, accent: nil)
    }

    private func drawMediaButton(ctx: CGContext, rect: NSRect, symbol: String, pressed: Bool, accent: NSColor?) {
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        let bg: NSColor
        if pressed {
            bg = accent?.withAlphaComponent(0.55) ?? NSColor(calibratedWhite: 0.38, alpha: 1.0)
        } else if let accent = accent {
            bg = accent.withAlphaComponent(0.22)
        } else {
            bg = NSColor(calibratedWhite: 0.16, alpha: 1.0)
        }
        ctx.setFillColor(bg.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        if let accent = accent {
            ctx.setStrokeColor(accent.withAlphaComponent(0.65).cgColor)
            ctx.setLineWidth(0.8)
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()

        if let tinted = cachedTintedSymbol(symbol, pointSize: 12.5, color: accent ?? .white) {
            let sz = tinted.size
            tinted.draw(in: NSRect(
                x: rect.midX - sz.width / 2.0,
                y: rect.midY - sz.height / 2.0,
                width: sz.width,
                height: sz.height
            ))
        }
    }

    private func mediaTextClipRect(metaRect: NSRect) -> CGRect {
        let leftInset: CGFloat = (mediaState.artwork != nil) ? 33.0 : 0.0
        let rightInset: CGFloat = (mediaState.appIcon != nil) ? 31.0 : 0.0
        let x = metaRect.minX + leftInset
        let w = max(44.0, metaRect.width - leftInset - rightInset)
        return CGRect(x: x, y: metaRect.minY, width: w, height: metaRect.height)
    }

    private func mediaSubtitleText() -> String {
        if !mediaState.artist.isEmpty {
            return mediaState.artist
        }
        return mediaState.source.rawValue
    }

    private func measureTextWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Spotify / iOS-style marquee text: displays stationary for 1.5s, then smoothly scrolls
    /// in a seamless loop with subtle OLED black edge fades whenever the text overflows clipRect.
    private func drawMarqueeText(ctx: CGContext, text: String, clipRect: CGRect, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, elapsed: TimeInterval) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textW = (text as NSString).size(withAttributes: attrs).width

        ctx.saveGState()
        ctx.clip(to: clipRect)

        if textW <= clipRect.width {
            (text as NSString).draw(at: NSPoint(x: clipRect.minX, y: y), withAttributes: attrs)
            ctx.restoreGState()
            return
        }

        let pauseDuration: Double = 1.5
        let speedPtsPerSec: Double = 28.0
        let gap: CGFloat = 36.0
        let cycleDist = Double(textW + gap)
        let scrollDuration = cycleDist / speedPtsPerSec
        let totalCycle = pauseDuration + scrollDuration

        let phase = elapsed.truncatingRemainder(dividingBy: totalCycle)
        let offset: CGFloat
        if phase < pauseDuration {
            offset = 0
        } else {
            offset = CGFloat((phase - pauseDuration) * speedPtsPerSec)
        }

        (text as NSString).draw(at: NSPoint(x: clipRect.minX - offset, y: y), withAttributes: attrs)
        if offset > 0 {
            (text as NSString).draw(at: NSPoint(x: clipRect.minX - offset + textW + gap, y: y), withAttributes: attrs)
        }

        // Subtle OLED black edge fade on right (and left while actively scrolling)
        let fadeW: CGFloat = 8.0
        let cs = CGColorSpaceCreateDeviceRGB()
        let clearBlack = NSColor.black.withAlphaComponent(0.0).cgColor
        let solidBlack = NSColor.black.cgColor
        if let rightGrad = CGGradient(colorsSpace: cs, colors: [clearBlack, solidBlack] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(
                rightGrad,
                start: CGPoint(x: clipRect.maxX - fadeW, y: clipRect.midY),
                end: CGPoint(x: clipRect.maxX, y: clipRect.midY),
                options: []
            )
        }
        if offset > 1.0, let leftGrad = CGGradient(colorsSpace: cs, colors: [solidBlack, clearBlack] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(
                leftGrad,
                start: CGPoint(x: clipRect.minX, y: clipRect.midY),
                end: CGPoint(x: clipRect.minX + fadeW, y: clipRect.midY),
                options: []
            )
        }

        ctx.restoreGState()
    }

    private func truncateText(_ text: String, maxWidth: CGFloat, size: CGFloat, weight: NSFont.Weight) -> String {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attrs).width <= maxWidth {
            return text
        }
        var s = text
        while s.count > 1 {
            s.removeLast()
            let candidate = s + "…"
            if (candidate as NSString).size(withAttributes: attrs).width <= maxWidth {
                return candidate
            }
        }
        return "…"
    }

    private func formatMediaTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Drawing Primitives
    private func drawSparkline(ctx: CGContext, values: [Double], maxValue: Double, rect: CGRect, strokeColor: NSColor, fillAlpha: CGFloat) {
        guard values.count >= 2, maxValue > 0 else { return }
        let stepX = rect.width / CGFloat(values.count - 1)

        let linePath = CGMutablePath()
        let fillPath = CGMutablePath()

        for (i, v) in values.enumerated() {
            let x = rect.minX + CGFloat(i) * stepX
            let norm = CGFloat(min(1.0, max(0.0, v / maxValue)))
            let y = rect.minY + norm * (rect.height - 1.0) + 0.5
            if i == 0 {
                linePath.move(to: CGPoint(x: x, y: y))
                fillPath.move(to: CGPoint(x: x, y: rect.minY))
                fillPath.addLine(to: CGPoint(x: x, y: y))
            } else {
                linePath.addLine(to: CGPoint(x: x, y: y))
                fillPath.addLine(to: CGPoint(x: x, y: y))
            }
        }
        fillPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        fillPath.closeSubpath()

        ctx.saveGState()
        ctx.setFillColor(strokeColor.withAlphaComponent(fillAlpha).cgColor)
        ctx.addPath(fillPath)
        ctx.fillPath()

        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineJoin(.round)
        ctx.addPath(linePath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawRoundedBar(ctx: CGContext, rect: CGRect, fraction: CGFloat, fillColor: NSColor) {
        let clamped = min(1.0, max(0.0, fraction))
        let r = rect.height / 2.0
        let trackPath = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

        ctx.saveGState()
        ctx.addPath(trackPath)
        ctx.clip()

        ctx.setFillColor(NSColor(calibratedWhite: 0.15, alpha: 1.0).cgColor)
        ctx.fill(rect)

        let fillW = rect.width * clamped
        if fillW > 0.5 {
            ctx.setFillColor(fillColor.cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: fillW, height: rect.height))
        }
        ctx.restoreGState()
    }

    private func drawText(_ text: String, at pt: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        let font = Self.cachedFont(size: size, weight: weight, mono: mono)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: pt, withAttributes: attrs)
    }

    private func drawTextRight(_ text: String, rightX: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        let font = Self.cachedFont(size: size, weight: weight, mono: mono)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rightX - sz.width, y: y), withAttributes: attrs)
    }

    private func drawTextCentered(_ text: String, centerX: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        let font = Self.cachedFont(size: size, weight: weight, mono: mono)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: centerX - sz.width / 2.0, y: y), withAttributes: attrs)
    }

    private func cachedTintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(color.description)"
        if let hit = tintedSymbolCache[key] {
            return hit
        }
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let styled = sym.withSymbolConfiguration(cfg) ?? sym
        let tinted = tintImage(styled, with: color)
        tintedSymbolCache[key] = tinted
        return tinted
    }

    private func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        let img = image.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private func formatSpeedCompact(_ bps: Double) -> String {
        if bps >= 1024 * 1024 * 100 {
            return String(format: "%.0fMB", bps / (1024 * 1024))
        } else if bps >= 1024 * 1024 {
            return String(format: "%.1fMB", bps / (1024 * 1024))
        } else if bps >= 1024 * 10 {
            return String(format: "%.0fKB", bps / 1024)
        } else if bps >= 1024 {
            return String(format: "%.1fKB", bps / 1024)
        } else {
            return String(format: "%.0fB", bps)
        }
    }

    private func formatSpeed(_ bps: Double) -> String {
        return formatSpeedCompact(bps) + "/s"
    }

    // MARK: - Offscreen Retina Preview Renderer (for README screenshots)
    static func renderPreviewScreenshots(to outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let view = CockpitView(frame: NSRect(x: 0, y: 0, width: 1004, height: 30))

        // Realistic Apple Silicon M2 sample telemetry
        var m = SystemMetrics()
        m.cpuTotal = 41
        m.cpuUser = 29
        m.cpuSystem = 12
        m.loadAvg1m = 2.41
        m.eCoreCount = 4
        m.coreLoads = [28, 35, 22, 40, 74, 62, 58, 49]
        m.cpuHistory = [18, 22, 20, 26, 31, 28, 34, 42, 48, 52, 45, 38, 35, 40, 56, 68, 72, 64, 58, 49, 44, 39, 43, 51, 47, 42, 36, 33, 38, 46, 54, 61, 58, 49, 44, 41, 37, 35, 39, 44, 48, 43, 40, 42, 46, 44, 41, 41]
        m.memUsedGB = 11.6
        m.memTotalGB = 16
        m.memAppGB = 7.0
        m.memWiredGB = 2.6
        m.memCompressedGB = 2.0
        m.memCachedGB = 3.1
        m.memActiveFrac = 0.44
        m.memWiredFrac = 0.16
        m.memCompressedFrac = 0.12
        m.swapUsedGB = 0.0
        m.memHistory = [62, 63, 64, 64, 65, 66, 67, 68, 68, 69, 70, 71, 72, 72, 73, 74, 73, 72, 72, 71, 70, 71, 72, 73, 74, 75, 75, 74, 73, 73, 72, 72, 73, 73, 74, 74, 73, 73, 72, 72, 72, 73, 73, 72, 72, 72, 73, 73]
        m.socTempC = 58
        m.socPeakTempC = 64
        m.pCoreTempC = 62
        m.eCoreTempC = 54
        m.socClusterTempC = 57
        m.fanAvailable = true
        m.fanRPM = 2150
        m.fanMaxRPM = 7200
        m.thermalStateRaw = 0
        m.tempHistory = [46, 47, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 63, 61, 60, 59, 58, 57, 56, 57, 58, 59, 60, 61, 60, 59, 58, 57, 56, 57, 58, 59, 59, 58, 57, 57, 58, 59, 58, 58, 58, 58, 58]
        m.powerWatts = 14.2
        m.chargerInWatts = 36.8
        m.batteryNetWatts = 22.6
        m.adapterMaxWatts = 45
        m.batteryPercent = 84
        m.batteryHealthPct = 94
        m.batteryCycleCount = 142
        m.batteryTempC = 31.2
        m.batteryVoltageV = 12.42
        m.isPluggedIn = true
        m.isCharging = true
        m.minutesRemaining = 42
        m.powerHistory = [8.2, 9.1, 8.8, 10.4, 11.2, 12.0, 14.5, 16.2, 18.4, 17.0, 15.2, 13.8, 12.4, 11.8, 13.0, 15.6, 19.2, 21.4, 18.8, 16.4, 15.0, 13.8, 14.2, 15.1, 14.8, 13.6, 12.9, 13.4, 14.6, 15.8, 16.2, 15.4, 14.2, 13.8, 14.0, 14.5, 15.1, 14.6, 13.9, 14.1, 14.4, 14.8, 14.5, 14.2, 14.0, 14.3, 14.2, 14.2]
        m.chargerInHistory = [32, 34, 35, 36, 36, 37, 38, 39, 40, 39, 38, 37, 36, 36, 37, 38, 41, 42, 40, 38, 37, 36, 36, 37, 37, 36, 36, 36, 37, 38, 38, 37, 37, 36, 36, 37, 37, 37, 36, 37, 37, 37, 37, 37, 37, 37, 36.8, 36.8]
        m.netDownBps = 2.4 * 1024 * 1024
        m.netUpBps = 185 * 1024
        m.netDownHistory = [120, 240, 310, 480, 920, 1400, 1850, 2200, 1950, 1600, 1100, 840, 620, 950, 1500, 2450, 2800, 2300, 1900, 1700, 1450, 1200, 1650, 2100, 2500, 2250, 1800, 1550, 1300, 1750, 2200, 2600, 2400, 2100, 2350, 2450].map { $0 * 1024.0 }
        m.netUpHistory = [40, 65, 80, 110, 140, 210, 190, 160, 130, 120, 95, 110, 150, 220, 280, 240, 190, 170, 150, 130, 140, 180, 210, 250, 220, 190, 160, 145, 175, 205, 195, 180, 165, 175, 190, 185].map { $0 * 1024.0 }
        m.primaryInterface = "en0"
        m.localIPv4 = "192.168.1.42"
        m.sessionDownBytes = 1_480_000_000
        m.sessionUpBytes = 218_000_000
        m.tailscaleActive = true
        m.vpnActive = true
        m.proxyActive = false
        m.timestamp = Date()

        func saveFramed(_ filename: String) {
            let scale: CGFloat = 2.0
            let barW: CGFloat = 1004
            let barH: CGFloat = 30
            let padX: CGFloat = 20
            let padY: CGFloat = 14
            let outW = Int((barW + padX * 2) * scale)
            let outH = Int((barH + padY * 2) * scale)

            guard let barRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            barRep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: barRep)
            guard let barCG = barRep.cgImage else { return }

            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.scaleBy(x: scale, y: scale)

            // Sleek space-gray MacBook chassis frame
            let fullRect = CGRect(x: 0, y: 0, width: barW + padX * 2, height: barH + padY * 2)
            let chassisPath = CGPath(roundedRect: fullRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
            ctx.saveGState()
            ctx.addPath(chassisPath)
            ctx.clip()
            let topC = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1.0).cgColor
            let botC = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0).cgColor
            if let g = CGGradient(colorsSpace: cs, colors: [topC, botC] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: fullRect.maxY), end: CGPoint(x: 0, y: 0), options: [])
            }
            ctx.restoreGState()

            // Recessed OLED Touch Bar bezel
            let barRect = CGRect(x: padX, y: padY, width: barW, height: barH)
            let barPath = CGPath(roundedRect: barRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.saveGState()
            ctx.addPath(barPath)
            ctx.clip()
            ctx.draw(barCG, in: barRect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(0.75)
            ctx.addPath(barPath)
            ctx.strokePath()
            ctx.restoreGState()

            if let outCG = ctx.makeImage(),
               let png = NSBitmapImageRep(cgImage: outCG).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outDir + "/" + filename))
            }
        }

        // 1. Cockpit + Live Dynamic Island Waveform
        view.metrics = m
        view.activeHUD = .none
        view.waitingAgentName = nil
        view.isAudioPlaying = true
        view.waveformBands = [0.68, 0.92, 0.56, 0.84, 0.42, 0.64]
        saveFramed("cockpit-waveform.png")

        // 2. Cockpit + Clock + Persistent Agent Waiting Badge
        view.isAudioPlaying = false
        view.waitingAgentName = "Claude"
        saveFramed("cockpit-agent-waiting.png")
        view.waitingAgentName = nil

        // 3. Full-Width Gentle Amber Agent Alert
        view.activeHUD = .agentFlash(agent: "Claude", startTime: CFAbsoluteTimeGetCurrent() - 1.2)
        saveFramed("agent-flash.png")

        // 4. Full-Width Media Overlay (with synthetic vibrant album art + Apple Music icon)
        let artSize = 52
        let artCS = CGColorSpaceCreateDeviceRGB()
        var sampleArt: NSImage? = nil
        if let actx = CGContext(data: nil, width: artSize, height: artSize, bitsPerComponent: 8, bytesPerRow: 0, space: artCS, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let c1 = NSColor(calibratedRed: 0.14, green: 0.36, blue: 0.88, alpha: 1.0).cgColor
            let c2 = NSColor(calibratedRed: 0.88, green: 0.24, blue: 0.52, alpha: 1.0).cgColor
            if let g = CGGradient(colorsSpace: artCS, colors: [c1, c2] as CFArray, locations: [0, 1]) {
                actx.drawLinearGradient(g, start: CGPoint(x: 0, y: 52), end: CGPoint(x: 52, y: 0), options: [])
            }
            actx.setFillColor(NSColor.white.withAlphaComponent(0.28).cgColor)
            actx.fillEllipse(in: CGRect(x: 10, y: 10, width: 32, height: 32))
            if let cg = actx.makeImage() {
                sampleArt = NSImage(cgImage: cg, size: NSSize(width: 26, height: 26))
            }
        }
        var musicIcon: NSImage? = nil
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            musicIcon = NSWorkspace.shared.icon(forFile: url.path)
            musicIcon?.size = NSSize(width: 24, height: 24)
        }
        view.mediaState = NowPlayingState(
            source: .music,
            title: "Midnight City",
            artist: "M83",
            duration: 243,
            elapsed: 108,
            isPlaying: true,
            canSeek: true,
            artwork: sampleArt,
            appIcon: musicIcon,
            appBundleID: "com.apple.Music",
            fetchedAt: Date()
        )
        view.mediaOverlayStartTime = CFAbsoluteTimeGetCurrent()
        view.activeHUD = .media
        saveFramed("media-overlay.png")

        // 5. Eyes-Free Volume Slider HUD
        view.activeHUD = .volume(value: 0.68, muted: false)
        saveFramed("slider-volume.png")

        // 6. Expanded Live Telemetry Inspectors
        view.topCPUProcesses = [("swift-frontend", 64.2), ("WindowServer", 18.4), ("ghostty", 7.1)]
        view.topRAMProcesses = [("Zen Browser", 2480), ("Xcode", 1890), ("WindowServer", 640)]
        view.activeHUD = .inspector(.cpu)
        saveFramed("inspector-cpu.png")
        view.activeHUD = .inspector(.ram)
        saveFramed("inspector-ram.png")
        view.activeHUD = .inspector(.thermal)
        saveFramed("inspector-thermal.png")
        view.activeHUD = .inspector(.power)
        saveFramed("inspector-power.png")
        view.activeHUD = .inspector(.network)
        saveFramed("inspector-network.png")
    }
}

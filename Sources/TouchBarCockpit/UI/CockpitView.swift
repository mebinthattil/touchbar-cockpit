import AppKit
import CPrivateAPIs

final class CockpitView: NSView {
    // MARK: - State
    private var metrics = SystemMetrics()

    private enum ActiveHUD {
        case none
        case volume(value: Float, muted: Bool)
        case brightness(value: Float)
        case infoToast(title: String, detail: String, accent: NSColor)
        case media
    }

    private var activeHUD: ActiveHUD = .none
    private var hudDismissTimer: Timer?

    // MARK: - Media Overlay State
    private var mediaState = NowPlayingState()
    private var mediaTickTimer: Timer?
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
        var lastAvgX: CGFloat
        var lastTouchCount: Int
        var accumulatedPx: CGFloat = 0
        var lastStepOffset: Int = 0
        var startValue: Float
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

    // Live Audio Waveform State (Dynamic Island style in Clock slot)
    private var waveformBands: [Float] = Array(repeating: 0, count: AudioSpectrumTap.bandCount)
    private var isAudioPlaying: Bool = false

    // Cached Formatters & Symbol Images (eliminates repeated ICU / bitmap allocations per frame)
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEE d"
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
        needsDisplay = true
    }

    func updateWaveform(bands: [Float], isActive: Bool) {
        self.waveformBands = bands
        self.isAudioPlaying = isActive
        // Fast-path: only dirty the tiny 85x30pt waveform slot when cockpit is visible!
        if case .none = activeHUD {
            setNeedsDisplay(panelRects(for: bounds).clock)
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

    private func dismissActiveHUD() {
        hudDismissTimer?.invalidate()
        hudDismissTimer = nil
        mediaTickTimer?.invalidate()
        mediaTickTimer = nil
        mediaPressedButton = nil
        isScrubbingMedia = false
        activeHUD = .none
        needsDisplay = true
    }

    private func openMediaOverlay(togglePlayback: Bool) {
        cancelLongPress()
        activeHUD = .media
        mediaPressedButton = nil
        isScrubbingMedia = false
        jogNormalizedOffset = 0
        jogAccumulatedSec = 0
        needsDisplay = true
        scheduleHUDDismiss(after: 8.0)

        let onState: (NowPlayingState) -> Void = { [weak self] state in
            guard let self = self else { return }
            self.mediaState = state
            if case .media = self.activeHUD {
                self.needsDisplay = true
            }
        }

        if togglePlayback {
            // Immediately toggle play/pause universally (works for Zen YouTube, Apple Music, Spotify, IINA)
            MediaController.shared.togglePlayPause(completion: onState)
        } else {
            // Open media controls without pausing/toggling playback
            MediaController.shared.fetchNowPlaying(completion: onState)
        }

        // Smooth live elapsed ticking while Media Overlay is visible
        mediaTickTimer?.invalidate()
        let tick = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, case .media = self.activeHUD else { return }
            if !self.isScrubbingMedia {
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        mediaTickTimer = tick
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
            if case .volume = activeHUD {
                hudDismissTimer?.invalidate()
                let curVol = AudioController.shared.getVolume()
                gestureMode = .volumeSlide(SliderTrackState(lastAvgX: pt.x, lastTouchCount: 1, startValue: curVol))
                return
            }
            if case .brightness = activeHUD {
                hudDismissTimer?.invalidate()
                let curBright = BrightnessController.shared.getDisplayBrightness()
                gestureMode = .brightnessSlide(SliderTrackState(lastAvgX: pt.x, lastTouchCount: 1, startValue: curBright))
                return
            }

            // If Media Overlay is currently open, route 1-finger touches directly to Media controls / scrubber
            if case .media = activeHUD {
                let mRects = mediaOverlayRects(for: bounds)
                scheduleHUDDismiss(after: 8.0)

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
                    self.openMediaOverlay(togglePlayback: true)
                }
            }
            longPressWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
        } else if count == 2 {
            let avgX = averageX(active)
            // If already in a Brightness or Volume slide, smoothly re-anchor without resetting or jumping!
            switch gestureMode {
            case .brightnessSlide(var st):
                st.lastAvgX = avgX
                st.lastTouchCount = count
                gestureMode = .brightnessSlide(st)
                return
            case .volumeSlide(var st):
                st.lastAvgX = avgX
                st.lastTouchCount = count
                gestureMode = .volumeSlide(st)
                return
            default:
                break
            }
            let curVol = AudioController.shared.getVolume()
            gestureMode = .twoFingerPending(startX: avgX, startTime: now, startVolume: curVol)
        } else if count >= 3 {
            let avgX = averageX(active)
            if case .brightnessSlide(var st) = gestureMode {
                st.lastAvgX = avgX
                st.lastTouchCount = count
                gestureMode = .brightnessSlide(st)
                return
            }
            let curBright = BrightnessController.shared.getDisplayBrightness()
            gestureMode = .brightnessSlide(SliderTrackState(lastAvgX: avgX, lastTouchCount: count, startValue: curBright))
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

        if count >= 2 {
            cancelLongPress()
            mediaPressedButton = nil
            isScrubbingMedia = false
        }

        let avgX = averageX(active)

        switch gestureMode {
        case .pendingTap(let startPt, _):
            if count >= 3 {
                let b = BrightnessController.shared.getDisplayBrightness()
                gestureMode = .brightnessSlide(SliderTrackState(lastAvgX: avgX, lastTouchCount: count, startValue: b))
                hudDismissTimer?.invalidate()
                mediaTickTimer?.invalidate()
                activeHUD = .brightness(value: b)
                needsDisplay = true
            } else if count == 2 {
                let v = AudioController.shared.getVolume()
                gestureMode = .twoFingerPending(startX: avgX, startTime: ProcessInfo.processInfo.systemUptime, startVolume: v)
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
                gestureMode = .twoFingerPending(startX: avgX, startTime: ProcessInfo.processInfo.systemUptime, startVolume: v)
            }

        case .longPressConsumed:
            break

        case .twoFingerPending(let startX, _, let startVol):
            if count >= 3 {
                let b = BrightnessController.shared.getDisplayBrightness()
                gestureMode = .brightnessSlide(SliderTrackState(lastAvgX: avgX, lastTouchCount: count, startValue: b))
                hudDismissTimer?.invalidate()
                mediaTickTimer?.invalidate()
                activeHUD = .brightness(value: b)
                needsDisplay = true
            } else if abs(avgX - startX) > 4.0 {
                var st = SliderTrackState(lastAvgX: avgX, lastTouchCount: count, accumulatedPx: avgX - startX, lastStepOffset: 0, startValue: startVol)
                applyVolumeSlide(&st)
                gestureMode = .volumeSlide(st)
            }

        case .volumeSlide(var st):
            if count >= 3 {
                let b = BrightnessController.shared.getDisplayBrightness()
                gestureMode = .brightnessSlide(SliderTrackState(lastAvgX: avgX, lastTouchCount: count, startValue: b))
                hudDismissTimer?.invalidate()
                mediaTickTimer?.invalidate()
                activeHUD = .brightness(value: b)
                needsDisplay = true
            } else {
                if count != st.lastTouchCount {
                    // Seamless finger-count handoff (e.g. 2 -> 1 finger): re-anchor with ZERO jump!
                    st.lastAvgX = avgX
                    st.lastTouchCount = count
                } else {
                    let rawDx = avgX - st.lastAvgX
                    st.lastAvgX = avgX
                    // Finer sensitivity when using 1 finger (0.65x) vs quick glide with 2 fingers (1.0x)
                    let scale: CGFloat = (count == 1) ? 0.65 : 1.0
                    st.accumulatedPx += rawDx * scale
                    applyVolumeSlide(&st)
                }
                gestureMode = .volumeSlide(st)
            }

        case .brightnessSlide(var st):
            if count != st.lastTouchCount {
                // Seamless finger-count handoff (e.g. 3 -> 2 -> 1 finger): re-anchor with ZERO jump!
                st.lastAvgX = avgX
                st.lastTouchCount = count
            } else {
                let rawDx = avgX - st.lastAvgX
                st.lastAvgX = avgX
                // Finer sensitivity when using 1 finger (0.65x) vs quick glide with 2-3 fingers (1.0x)
                let scale: CGFloat = (count == 1) ? 0.65 : 1.0
                st.accumulatedPx += rawDx * scale
                applyBrightnessSlide(&st)
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
        // re-anchor centroid immediately so the remaining 1 finger continues with ZERO jump!
        if !remaining.isEmpty {
            let newAvgX = averageX(remaining)
            switch gestureMode {
            case .brightnessSlide(var st):
                st.lastAvgX = newAvgX
                st.lastTouchCount = remaining.count
                gestureMode = .brightnessSlide(st)
            case .volumeSlide(var st):
                st.lastAvgX = newAvgX
                st.lastTouchCount = remaining.count
                gestureMode = .volumeSlide(st)
            case .twoFingerPending(_, _, let startVol):
                // User started with 2 fingers and dropped to 1 finger -> open Volume panel for 1-finger fine control!
                if remaining.count == 1 {
                    let st = SliderTrackState(lastAvgX: newAvgX, lastTouchCount: 1, startValue: startVol)
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
            scheduleHUDDismiss(after: 8.0)
            needsDisplay = true

        case .mediaJogScrubbing:
            isScrubbingMedia = false
            jogNormalizedOffset = 0
            jogAccumulatedSec = 0
            scheduleHUDDismiss(after: 8.0)
            needsDisplay = true

        case .longPressConsumed:
            break

        case .twoFingerPending(_, let startTime, _):
            if peakTouchCount == 2 && (now - startTime) < 0.28 {
                let muted = AudioController.shared.toggleMute()
                let vol = AudioController.shared.getVolume()
                mediaTickTimer?.invalidate()
                activeHUD = .volume(value: vol, muted: muted)
                scheduleHUDDismiss(after: 1.0)
                needsDisplay = true
            }

        case .volumeSlide, .brightnessSlide:
            // Linger for 3.0s after last adjustment so you can put 1 finger right back down for fine tuning
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
        if case .volumeSlide = gestureMode { scheduleHUDDismiss(after: 3.0) }
        if case .brightnessSlide = gestureMode { scheduleHUDDismiss(after: 3.0) }
        gestureMode = .idle
        peakTouchCount = 0
    }

    private func averageX(_ touches: [NSTouch]) -> CGFloat {
        guard !touches.isEmpty else { return 0 }
        let sum = touches.reduce(CGFloat(0)) { $0 + $1.location(in: self).x }
        return sum / CGFloat(touches.count)
    }

    private func applyVolumeSlide(_ st: inout SliderTrackState) {
        hudDismissTimer?.invalidate()
        mediaTickTimer?.invalidate()

        if TBIsAccessibilityTrusted(false) {
            // 5.5pt per 1/64th fine native HID step (~350pt full sweep at 2F; ~540pt at 1F fine control!)
            let targetOffset = Int(round(st.accumulatedPx / 5.5))
            let diff = targetOffset - st.lastStepOffset
            if diff != 0 {
                _ = AudioController.shared.nudgeVolumeFine(steps: diff)
                st.lastStepOffset = targetOffset
                let approx = max(0.0, min(1.0, st.startValue + Float(targetOffset) / 64.0))
                activeHUD = .volume(value: approx, muted: approx <= 0.004)
                needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self = self, case .volume = self.activeHUD else { return }
                    self.activeHUD = .volume(value: AudioController.shared.getVolume(), muted: AudioController.shared.isMuted())
                    self.needsDisplay = true
                }
            } else if case .none = activeHUD {
                activeHUD = .volume(value: AudioController.shared.getVolume(), muted: AudioController.shared.isMuted())
                needsDisplay = true
            }
        } else {
            let delta = Float(st.accumulatedPx / 320.0)
            let target = max(0.0, min(1.0, st.startValue + delta))
            AudioController.shared.setVolume(target, showOSD: true)
            let muted = AudioController.shared.isMuted()
            activeHUD = .volume(value: target, muted: muted)
            needsDisplay = true
        }
    }

    private func applyBrightnessSlide(_ st: inout SliderTrackState) {
        hudDismissTimer?.invalidate()
        mediaTickTimer?.invalidate()

        if TBIsAccessibilityTrusted(false) {
            let targetOffset = Int(round(st.accumulatedPx / 5.5))
            let diff = targetOffset - st.lastStepOffset
            if diff != 0 {
                _ = BrightnessController.shared.nudgeDisplayBrightnessFine(steps: diff)
                st.lastStepOffset = targetOffset
                let approx = max(0.0, min(1.0, st.startValue + Float(targetOffset) / 64.0))
                activeHUD = .brightness(value: approx)
                needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self = self, case .brightness = self.activeHUD else { return }
                    self.activeHUD = .brightness(value: BrightnessController.shared.getDisplayBrightness())
                    self.needsDisplay = true
                }
            } else if case .none = activeHUD {
                activeHUD = .brightness(value: BrightnessController.shared.getDisplayBrightness())
                needsDisplay = true
            }
        } else {
            let delta = Float(st.accumulatedPx / 320.0)
            let target = BrightnessController.shared.setDisplayBrightness(st.startValue + delta, showOSD: true)
            activeHUD = .brightness(value: target)
            needsDisplay = true
        }
    }

    private func handleMediaButton(_ button: MediaButton) {
        switch button {
        case .close:
            dismissActiveHUD()
        case .prev:
            scheduleHUDDismiss(after: 8.0)
            MediaController.shared.previousTrack { [weak self] state in
                self?.mediaState = state
                self?.needsDisplay = true
            }
        case .playPause:
            scheduleHUDDismiss(after: 8.0)
            mediaState.isPlaying.toggle()
            mediaState.fetchedAt = Date()
            needsDisplay = true
            MediaController.shared.togglePlayPause { [weak self] state in
                self?.mediaState = state
                self?.needsDisplay = true
            }
        case .next:
            scheduleHUDDismiss(after: 8.0)
            MediaController.shared.nextTrack { [weak self] state in
                self?.mediaState = state
                self?.needsDisplay = true
            }
        case .skipBack:
            scheduleHUDDismiss(after: 8.0)
            MediaController.shared.seekRelative(deltaSeconds: -10.0)
        case .skipFwd:
            scheduleHUDDismiss(after: 8.0)
            MediaController.shared.seekRelative(deltaSeconds: 10.0)
        }
    }

    // MARK: - Single Tap Panel Interactions
    private func handleSingleTap(at point: NSPoint) {
        // Dismiss any active toast if tapped
        if case .infoToast = activeHUD {
            hudDismissTimer?.invalidate()
            activeHUD = .none
            needsDisplay = true
            return
        }

        let rects = panelRects(for: bounds)
        if rects.cpu.contains(point) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let top = CPUSampler.fetchTopProcesses(limit: 3)
                let summary = top.isEmpty
                    ? "No active processes"
                    : top.map { String(format: "%@ %.0f%%", $0.name, $0.pct) }.joined(separator: "   ·   ")
                DispatchQueue.main.async {
                    self?.showTransientToast(title: "TOP CPU", detail: summary, accent: NSColor(calibratedRed: 0.98, green: 0.57, blue: 0.24, alpha: 1.0), duration: 3.5)
                }
            }
        } else if rects.ram.contains(point) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let top = MemorySampler.fetchTopRAMProcesses(limit: 3)
                let summary = top.isEmpty
                    ? "No memory info"
                    : top.map { proc -> String in
                        if proc.mb >= 1024 {
                            return String(format: "%@ %.1fG", proc.name, proc.mb / 1024.0)
                        } else {
                            return String(format: "%@ %.0fM", proc.name, proc.mb)
                        }
                    }.joined(separator: "   ·   ")
                DispatchQueue.main.async {
                    self?.showTransientToast(title: "TOP RAM", detail: summary, accent: NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1.0), duration: 3.5)
                }
            }
        } else if rects.thermal.contains(point) {
            let peakStr = metrics.socPeakTempC > 0 ? String(format: "Peak %.0f°C", metrics.socPeakTempC) : "Thermal OK"
            let fanPct = metrics.fanMaxRPM > 0 ? Int((metrics.fanRPM / metrics.fanMaxRPM) * 100.0) : 0
            let fanStr = metrics.fanAvailable ? String(format: "Fan %.0f RPM (%d%%)", metrics.fanRPM, fanPct) : "Fan Passive"
            showTransientToast(title: "M2 THERMALS", detail: "\(peakStr)   ·   \(fanStr)", accent: NSColor(calibratedRed: 0.38, green: 0.75, blue: 0.98, alpha: 1.0), duration: 2.6)
        } else if rects.power.contains(point) {
            let detail: String
            if metrics.isPluggedIn {
                let adapterStr = metrics.adapterMaxWatts > 0 ? " (\(metrics.adapterMaxWatts)W PD)" : ""
                let battFlow = abs(metrics.batteryNetWatts) >= 0.2
                    ? String(format: "   ·   Batt %+.1fW", metrics.batteryNetWatts)
                    : ""
                detail = String(format: "Draw %.1fW   ·   In %.1fW%@%@   ·   %d%%", metrics.powerWatts, metrics.chargerInWatts, adapterStr, battFlow, metrics.batteryPercent)
            } else {
                let remStr: String
                if let mins = metrics.minutesRemaining {
                    remStr = String(format: "   ·   %dh %02dm left", mins / 60, mins % 60)
                } else {
                    remStr = ""
                }
                detail = String(format: "Draw %.1fW   ·   On Battery %d%%%@", metrics.powerWatts, metrics.batteryPercent, remStr)
            }
            showTransientToast(title: "POWER", detail: detail, accent: NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.20, alpha: 1.0), duration: 3.2)
        } else if rects.network.contains(point) {
            var flags: [String] = []
            if metrics.tailscaleActive { flags.append("Tailscale ON") }
            if metrics.vpnActive { flags.append("VPN ON") }
            if metrics.proxyActive { flags.append("Proxy ON") }
            let netFlags = flags.isEmpty ? "Direct (No VPN/Proxy)" : flags.joined(separator: " · ")
            showTransientToast(title: "NETWORK", detail: "↓ \(formatSpeed(metrics.netDownBps))   ↑ \(formatSpeed(metrics.netUpBps))   ·   \(netFlags)", accent: NSColor(calibratedRed: 0.65, green: 0.55, blue: 0.98, alpha: 1.0), duration: 3.0)
        } else if rects.clock.contains(point) {
            openMediaOverlay(togglePlayback: false)
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

        case .media:
            drawMediaOverlay(ctx: ctx)
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

    // MARK: - Panel 3: M2 Thermal & Fan RPM
    private func drawThermalPanel(ctx: CGContext, rect: NSRect) {
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

    // MARK: - Inline Transient Toast HUD (Tap to Inspect)
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
        let metaW: CGFloat = min(228, max(140, rect.width * 0.225))
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

        // Track Metadata (Optional 26x26 rounded Album Art + Title + Artist · Source)
        var textX = r.meta.minX
        var textW = r.meta.width
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

            textX = artRect.maxX + 7
            textW = max(50, r.meta.maxX - textX)
        }

        let titleClip = truncateText(mediaState.title, maxWidth: textW, size: 10.5, weight: .semibold)
        drawText(titleClip, at: NSPoint(x: textX, y: 15.5), size: 10.5, weight: .semibold, color: .white)

        let subRaw: String
        if !mediaState.artist.isEmpty && mediaState.source != .universal {
            subRaw = "\(mediaState.artist) · \(mediaState.source.rawValue)"
        } else if !mediaState.artist.isEmpty {
            subRaw = mediaState.artist
        } else {
            subRaw = mediaState.source.rawValue
        }
        let subClip = truncateText(subRaw, maxWidth: textW, size: 8.5, weight: .medium)
        drawText(subClip, at: NSPoint(x: textX, y: 3.5), size: 8.5, weight: .medium, color: NSColor(calibratedWhite: 0.55, alpha: 1.0))

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
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: pt, withAttributes: attrs)
    }

    private func drawTextRight(_ text: String, rightX: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rightX - sz.width, y: y), withAttributes: attrs)
    }

    private func drawTextCentered(_ text: String, centerX: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
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
}

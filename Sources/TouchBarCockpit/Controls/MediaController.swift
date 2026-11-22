import AppKit
import ApplicationServices
import Carbon
import CPrivateAPIs

struct NowPlayingState {
    enum Source: String {
        case spotify = "Spotify"
        case music = "Music"
        case vlc = "VLC"
        case universal = "Media"
    }

    var source: Source = .universal
    var title: String = "No Media Playing"
    var artist: String = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var isPlaying: Bool = false
    var canSeek: Bool = false
    var artwork: NSImage? = nil
    var appIcon: NSImage? = nil
    var appBundleID: String? = nil
    var fetchedAt: Date = Date()

    func interpolatedElapsed(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        if isPlaying {
            let dt = max(0, now.timeIntervalSince(fetchedAt))
            return min(duration, max(0, elapsed + dt))
        }
        return min(duration, max(0, elapsed))
    }
}

final class MediaController {
    static let shared = MediaController()

    private let queue = DispatchQueue(label: "com.mebin.touchbarcockpit.media", qos: .userInitiated)
    private(set) var lastState = NowPlayingState()
    private var lastPlayingBundleID: String? = nil

    // Permission tracking (non-blocking consent flow)
    private var consentInFlight: Set<String> = []
    private var deniedUntil: [String: CFAbsoluteTime] = [:]

    // Caches
    private var cachedArtworkKey: String = ""
    private var cachedArtworkImage: NSImage? = nil
    private var artworkFetchInFlightKey: String? = nil
    private var appIconCache: [String: NSImage] = [:]

    // Called on main thread whenever async artwork finishes downloading or active player terminates
    var onStateUpdated: ((NowPlayingState) -> Void)?

    private lazy var urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 5.0
        return URLSession(configuration: cfg)
    }()

    // MARK: - App Lifecycle Cleanup (Eliminates Stale Info When Closing Apple Music / Spotify / VLC)
    func handleAppTerminated(bundleID: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.lastPlayingBundleID == bundleID {
                self.lastPlayingBundleID = nil
            }
            if self.lastState.appBundleID == bundleID {
                self.cachedArtworkKey = ""
                self.cachedArtworkImage = nil
                self.lastState = NowPlayingState()
                self.fetchNowPlaying { state in
                    self.onStateUpdated?(state)
                }
            }
        }
    }

    func invalidateIfClosed() {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        if let bid = lastState.appBundleID, !runningIDs.contains(bid) {
            lastState = NowPlayingState()
            cachedArtworkKey = ""
            cachedArtworkImage = nil
        }
    }

    private func iconForApp(bundleID: String) -> NSImage? {
        if let hit = appIconCache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 24, height: 24)
        appIconCache[bundleID] = icon
        return icon
    }

    // MARK: - Fetch Live Metadata (Smart Priority: Playing Native > Frontmost App > Last Playing > Any Native > Browser Tab)
    func fetchNowPlaying(completion: @escaping (NowPlayingState) -> Void) {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningIDs = Set(runningApps.compactMap { $0.bundleIdentifier })
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBid = frontApp?.bundleIdentifier

        queue.async { [weak self] in
            guard let self = self else { return }

            // Purge stale lastState if its app is no longer running
            if let oldBid = self.lastState.appBundleID, !runningIDs.contains(oldBid) {
                self.lastState = NowPlayingState()
                self.cachedArtworkKey = ""
                self.cachedArtworkImage = nil
            }
            if let lpBid = self.lastPlayingBundleID, !runningIDs.contains(lpBid) {
                self.lastPlayingBundleID = nil
            }

            // Query all running native players (fast ~3ms each when permitted; non-blocking consent if needed)
            var nativeStates: [String: NowPlayingState] = [:]
            if runningIDs.contains("com.spotify.client") {
                if self.checkAutomationPermission(bundleID: "com.spotify.client"),
                   let s = self.querySpotify() {
                    nativeStates["com.spotify.client"] = s
                } else if let axSpotify = self.fallbackSpotifyFromAX(runningApps: runningApps) {
                    nativeStates["com.spotify.client"] = axSpotify
                }
            }
            if runningIDs.contains("com.apple.Music"),
               self.checkAutomationPermission(bundleID: "com.apple.Music"),
               let m = self.queryMusic() {
                nativeStates["com.apple.Music"] = m
            }
            if runningIDs.contains("org.videolan.vlc"),
               self.checkAutomationPermission(bundleID: "org.videolan.vlc"),
               let v = self.queryVLC() {
                nativeStates["org.videolan.vlc"] = v
            }

            var detected: NowPlayingState? = nil

            // Priority 1: Any native player that is actively PLAYING right now
            // (If frontmost app is playing, prefer it; else check Spotify -> Music -> VLC)
            if let fBid = frontBid, let st = nativeStates[fBid], st.isPlaying {
                detected = st
            } else {
                for bid in ["com.spotify.client", "com.apple.Music", "org.videolan.vlc"] {
                    if let st = nativeStates[bid], st.isPlaying {
                        detected = st
                        break
                    }
                }
            }

            // Priority 2: If a native player is frontmost (even if paused), show it!
            if detected == nil, let fBid = frontBid, let st = nativeStates[fBid] {
                detected = st
            }

            // Priority 3: If frontmost app is a browser/video player with an active media tab (YouTube, IINA, etc.)
            if detected == nil,
               Self.isBrowserOrVideoBundle(frontBid),
               let browserMedia = self.detectBrowserOrPlayerWindowMedia(runningApps: runningApps, frontmost: frontApp) {
                detected = browserMedia
            }

            // Priority 4: Last native player that was playing (if still running with a track)
            if detected == nil, let lpBid = self.lastPlayingBundleID, let st = nativeStates[lpBid] {
                detected = st
            }

            // Priority 5: Any running native player with a loaded track (Spotify -> Music -> VLC)
            if detected == nil {
                for bid in ["com.spotify.client", "com.apple.Music", "org.videolan.vlc"] {
                    if let st = nativeStates[bid] {
                        detected = st
                        break
                    }
                }
            }

            // Priority 6: Background browser media tab (YouTube / YouTube Music / IINA)
            if detected == nil,
               let browserMedia = self.detectBrowserOrPlayerWindowMedia(runningApps: runningApps, frontmost: frontApp) {
                detected = browserMedia
            }

            let finalState: NowPlayingState
            if let d = detected {
                finalState = d
                if d.isPlaying, let bid = d.appBundleID {
                    self.lastPlayingBundleID = bid
                }
            } else {
                // Fresh clean fallback — NEVER carry over stale title/artwork/appIcon from a closed app!
                finalState = NowPlayingState(
                    source: .universal,
                    title: "No Active Media",
                    artist: "Play Music, Spotify, or Video",
                    duration: 0,
                    elapsed: 0,
                    isPlaying: false,
                    canSeek: false,
                    artwork: nil,
                    appIcon: frontBid.flatMap { self.iconForApp(bundleID: $0) },
                    appBundleID: nil,
                    fetchedAt: Date()
                )
            }

            self.lastState = finalState
            DispatchQueue.main.async {
                completion(finalState)
            }
        }
    }

    // MARK: - Transport Controls (Targets active native player directly when known, universal HID otherwise!)
    func togglePlayPause(completion: ((NowPlayingState) -> Void)? = nil) {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        queue.async { [weak self] in
            guard let self = self else { return }
            var handled = false

            if let bid = self.lastState.appBundleID, runningIDs.contains(bid) {
                switch self.lastState.source {
                case .spotify where self.checkAutomationPermission(bundleID: "com.spotify.client"):
                    handled = (self.runInProcessAppleScript("tell application \"Spotify\" to playpause") != nil)
                case .music where self.checkAutomationPermission(bundleID: "com.apple.Music"):
                    handled = (self.runInProcessAppleScript("tell application \"Music\" to playpause") != nil)
                case .vlc where self.checkAutomationPermission(bundleID: "org.videolan.vlc"):
                    handled = (self.runInProcessAppleScript("tell application \"VLC\" to play") != nil)
                default:
                    break
                }
            }

            if !handled {
                // Universal HID NX_KEYTYPE_PLAY (controls Zen YouTube, Chrome, Safari, IINA, or macOS Now Playing)
                TBPostAuxKey(16, false)
                self.lastState.isPlaying.toggle()
                self.lastState.fetchedAt = Date()
            }

            if let completion = completion {
                self.queue.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    self?.fetchNowPlaying(completion: completion)
                }
            }
        }
    }

    func nextTrack(completion: ((NowPlayingState) -> Void)? = nil) {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        queue.async { [weak self] in
            guard let self = self else { return }
            var handled = false

            if let bid = self.lastState.appBundleID, runningIDs.contains(bid) {
                switch self.lastState.source {
                case .spotify where self.checkAutomationPermission(bundleID: "com.spotify.client"):
                    handled = (self.runInProcessAppleScript("tell application \"Spotify\" to next track") != nil)
                case .music where self.checkAutomationPermission(bundleID: "com.apple.Music"):
                    handled = (self.runInProcessAppleScript("tell application \"Music\" to next track") != nil)
                case .vlc where self.checkAutomationPermission(bundleID: "org.videolan.vlc"):
                    handled = (self.runInProcessAppleScript("tell application \"VLC\" to next") != nil)
                default:
                    break
                }
            }

            if !handled {
                TBPostAuxKey(19, false) // NX_KEYTYPE_FAST
            }

            if let completion = completion {
                self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.fetchNowPlaying(completion: completion)
                }
            }
        }
    }

    func previousTrack(completion: ((NowPlayingState) -> Void)? = nil) {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        queue.async { [weak self] in
            guard let self = self else { return }
            var handled = false

            if let bid = self.lastState.appBundleID, runningIDs.contains(bid) {
                switch self.lastState.source {
                case .spotify where self.checkAutomationPermission(bundleID: "com.spotify.client"):
                    handled = (self.runInProcessAppleScript("tell application \"Spotify\" to previous track") != nil)
                case .music where self.checkAutomationPermission(bundleID: "com.apple.Music"):
                    handled = (self.runInProcessAppleScript("tell application \"Music\" to previous track") != nil)
                case .vlc where self.checkAutomationPermission(bundleID: "org.videolan.vlc"):
                    handled = (self.runInProcessAppleScript("tell application \"VLC\" to previous") != nil)
                default:
                    break
                }
            }

            if !handled {
                TBPostAuxKey(20, false) // NX_KEYTYPE_REWIND
            }

            if let completion = completion {
                self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.fetchNowPlaying(completion: completion)
                }
            }
        }
    }

    // MARK: - Absolute & Relative Scrubbing
    func seek(to seconds: Double, completion: ((NowPlayingState) -> Void)? = nil) {
        let clamped = max(0, seconds)
        queue.async { [weak self] in
            guard let self = self else { return }
            switch self.lastState.source {
            case .spotify:
                _ = self.runInProcessAppleScript(String(format: "tell application \"Spotify\" to set player position to %.2f", clamped))
            case .music:
                _ = self.runInProcessAppleScript(String(format: "tell application \"Music\" to set player position to %.2f", clamped))
            case .vlc:
                _ = self.runInProcessAppleScript(String(format: "tell application \"VLC\" to set current time to %d", Int(clamped)))
            case .universal:
                break
            }
            if let completion = completion {
                self.queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.fetchNowPlaying(completion: completion)
                }
            }
        }
    }

    func seekRelative(deltaSeconds: Double, completion: ((NowPlayingState) -> Void)? = nil) {
        let frontIsVideoApp = Self.isBrowserOrVideoBundle(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        queue.async { [weak self] in
            guard let self = self else { return }
            switch self.lastState.source {
            case .spotify:
                let target = max(0, self.lastState.interpolatedElapsed() + deltaSeconds)
                _ = self.runInProcessAppleScript(String(format: "tell application \"Spotify\" to set player position to %.2f", target))
            case .music:
                let target = max(0, self.lastState.interpolatedElapsed() + deltaSeconds)
                _ = self.runInProcessAppleScript(String(format: "tell application \"Music\" to set player position to %.2f", target))
            case .vlc:
                let target = max(0, self.lastState.interpolatedElapsed() + deltaSeconds)
                _ = self.runInProcessAppleScript(String(format: "tell application \"VLC\" to set current time to %d", Int(target)))
            case .universal:
                let ok = TBMediaRemoteSkip(deltaSeconds)
                if frontIsVideoApp {
                    let steps = max(1, Int(round(abs(deltaSeconds) / 5.0)))
                    let keyCode: UInt16 = deltaSeconds >= 0 ? 124 : 123
                    for _ in 0..<min(4, steps) {
                        TBPostKeyCode(keyCode)
                    }
                } else if !ok {
                    TBPostAuxKey(deltaSeconds >= 0 ? 19 : 20, false)
                }
            }
            if let completion = completion {
                self.fetchNowPlaying(completion: completion)
            }
        }
    }

    // MARK: - Non-Blocking Automation Permission Check
    private func checkAutomationPermission(bundleID: String) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let until = deniedUntil[bundleID], now < until {
            return false
        }

        var targetDesc = AEAddressDesc()
        guard let cStr = bundleID.cString(using: .utf8) else { return false }
        guard AECreateDesc(DescType(typeApplicationBundleID), cStr, strlen(cStr), &targetDesc) == noErr else {
            return false
        }
        defer { AEDisposeDesc(&targetDesc) }

        // First do an instant non-blocking check
        let status = AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )

        if status == noErr {
            deniedUntil.removeValue(forKey: bundleID)
            return true
        }

        if status == OSStatus(errAEEventWouldRequireUserConsent) {
            // Trigger the consent dialog on a detached thread so MediaController.queue NEVER blocks!
            if !consentInFlight.contains(bundleID) {
                consentInFlight.insert(bundleID)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    var askDesc = AEAddressDesc()
                    if let s = bundleID.cString(using: .utf8),
                       AECreateDesc(DescType(typeApplicationBundleID), s, strlen(s), &askDesc) == noErr {
                        let askStatus = AEDeterminePermissionToAutomateTarget(
                            &askDesc,
                            AEEventClass(typeWildCard),
                            AEEventID(typeWildCard),
                            true
                        )
                        AEDisposeDesc(&askDesc)
                        self?.queue.async {
                            self?.consentInFlight.remove(bundleID)
                            if askStatus == noErr {
                                self?.deniedUntil.removeValue(forKey: bundleID)
                                self?.fetchNowPlaying { state in
                                    self?.onStateUpdated?(state)
                                }
                            } else {
                                // Back off 15s before checking again in case user enables in System Settings
                                self?.deniedUntil[bundleID] = CFAbsoluteTimeGetCurrent() + 15.0
                            }
                        }
                    }
                }
            }
            return false
        }

        if status == OSStatus(errAEEventNotPermitted) {
            deniedUntil[bundleID] = now + 15.0
        }
        return false
    }

    // Fallback: if Spotify Automation consent hasn't been clicked yet, read Spotify window title via AX!
    private func fallbackSpotifyFromAX(runningApps: [NSRunningApplication]) -> NowPlayingState? {
        guard TBIsAccessibilityTrusted(false),
              let spotifyApp = runningApps.first(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            return nil
        }
        let titles = windowTitles(forPID: spotifyApp.processIdentifier)
        let icon = iconForApp(bundleID: "com.spotify.client")
        for t in titles where !t.isEmpty && t != "Spotify" && t != "Spotify Free" && t != "Spotify Premium" {
            // Spotify macOS window title format while playing is often "Artist - Track"
            let parts = t.components(separatedBy: " - ")
            let artist = parts.count >= 2 ? parts[0] : "Spotify"
            let title = parts.count >= 2 ? parts.dropFirst().joined(separator: " - ") : t
            return NowPlayingState(
                source: .universal,
                title: title,
                artist: artist,
                duration: 0,
                elapsed: 0,
                isPlaying: true,
                canSeek: false,
                artwork: nil,
                appIcon: icon,
                appBundleID: "com.spotify.client",
                fetchedAt: Date()
            )
        }
        return nil
    }

    // MARK: - Accessibility Window Title Detection for Zen / Chrome / Safari / IINA
    private func detectBrowserOrPlayerWindowMedia(runningApps: [NSRunningApplication], frontmost: NSRunningApplication?) -> NowPlayingState? {
        guard TBIsAccessibilityTrusted(false) else { return nil }

        let mediaAppHints = ["iina", "zen", "chrome", "safari", "firefox", "arc", "brave"]
        var candidates = runningApps.filter { app in
            guard let bid = app.bundleIdentifier?.lowercased() else { return false }
            return mediaAppHints.contains(where: { bid.contains($0) })
        }
        if let frontPID = frontmost?.processIdentifier {
            candidates.sort { ($0.processIdentifier == frontPID ? 0 : 1) < ($1.processIdentifier == frontPID ? 0 : 1) }
        }

        for app in candidates {
            let appName = app.localizedName ?? "Browser"
            let rawBid = app.bundleIdentifier ?? ""
            let bid = rawBid.lowercased()
            let appIcon = !rawBid.isEmpty ? iconForApp(bundleID: rawBid) : nil
            let titles = windowTitles(forPID: app.processIdentifier)

            for rawTitle in titles {
                if bid.contains("iina"), !rawTitle.isEmpty, rawTitle != "IINA" {
                    return NowPlayingState(
                        source: .universal,
                        title: rawTitle,
                        artist: "IINA",
                        duration: 0,
                        elapsed: 0,
                        isPlaying: lastState.isPlaying,
                        canSeek: false,
                        artwork: nil,
                        appIcon: appIcon,
                        appBundleID: rawBid,
                        fetchedAt: Date()
                    )
                }

                if let parsed = parseMediaBrowserTitle(rawTitle, appName: appName) {
                    return NowPlayingState(
                        source: .universal,
                        title: parsed.title,
                        artist: parsed.subtitle,
                        duration: 0,
                        elapsed: 0,
                        isPlaying: lastState.isPlaying,
                        canSeek: false,
                        artwork: nil,
                        appIcon: appIcon,
                        appBundleID: rawBid,
                        fetchedAt: Date()
                    )
                }
            }
        }
        return nil
    }

    private func windowTitles(forPID pid: pid_t) -> [String] {
        let appElem = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }
        var result: [String] = []
        for win in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                result.append(title)
            }
        }
        return result
    }

    private func parseMediaBrowserTitle(_ raw: String, appName: String) -> (title: String, subtitle: String)? {
        var cleaned = raw
        for suffix in [" — Zen Browser", " - Zen Browser", " — Mozilla Firefox", " - Google Chrome", " - Brave", " - Arc"] {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
            }
        }

        if cleaned.hasPrefix("("), let closeParen = cleaned.firstIndex(of: ")") {
            let inside = cleaned[cleaned.index(after: cleaned.startIndex)..<closeParen]
            if inside.allSatisfy({ $0.isNumber }) {
                cleaned = String(cleaned[cleaned.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        let services: [(marker: String, label: String)] = [
            (" - YouTube Music", "YouTube Music"),
            (" - YouTube", "YouTube"),
            (" | Spotify", "Spotify Web"),
            (" - SoundCloud", "SoundCloud"),
            (" - Twitch", "Twitch"),
            (" - Netflix", "Netflix")
        ]

        for svc in services {
            if let range = cleaned.range(of: svc.marker, options: .backwards) {
                let title = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    return (title, svc.label)
                }
            }
        }
        return nil
    }

    private static func isBrowserOrVideoBundle(_ bundleID: String?) -> Bool {
        guard let bid = bundleID?.lowercased() else { return false }
        return bid.contains("zen") ||
               bid.contains("firefox") ||
               bid.contains("chrome") ||
               bid.contains("safari") ||
               bid.contains("arc") ||
               bid.contains("brave") ||
               bid.contains("iina") ||
               bid.contains("vlc")
    }

    // MARK: - Native Player Queries (In-Process NSAppleScript -> ~3ms!)
    private func querySpotify() -> NowPlayingState? {
        let script = """
        tell application "Spotify"
            try
                set pState to (player state as string)
                if pState is "stopped" then return "NONE"
                set tName to name of current track
                set tArtist to artist of current track
                set tDur to (duration of current track) / 1000.0
                set tPos to player position
                set tArt to ""
                try
                    set tArt to artwork url of current track
                end try
                return pState & "|||" & tName & "|||" & tArtist & "|||" & (tDur as string) & "|||" & (tPos as string) & "|||" & tArt
            on error
                return "NONE"
            end try
        end tell
        """
        guard let out = runInProcessAppleScript(script), out != "NONE" else { return nil }
        let parts = out.components(separatedBy: "|||")
        guard parts.count >= 5 else { return nil }
        let dur = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        let pos = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let title = parts[1].isEmpty ? "Spotify" : parts[1]
        let artist = parts[2]
        let artURL = parts.count >= 6 ? parts[5] : ""
        let cacheKey = "spotify|\(title)|\(artist)"
        let art = resolveArtwork(cacheKey: cacheKey, spotifyURL: artURL, isMusic: false)
        return NowPlayingState(
            source: .spotify,
            title: title,
            artist: artist,
            duration: dur,
            elapsed: pos,
            isPlaying: parts[0].lowercased() == "playing",
            canSeek: dur > 0,
            artwork: art,
            appIcon: iconForApp(bundleID: "com.spotify.client"),
            appBundleID: "com.spotify.client",
            fetchedAt: Date()
        )
    }

    private func queryMusic() -> NowPlayingState? {
        let script = """
        tell application "Music"
            try
                set pState to (player state as string)
                if pState is "stopped" then return "NONE"
                set tName to name of current track
                set tArtist to artist of current track
                set tDur to duration of current track
                set tPos to player position
                return pState & "|||" & tName & "|||" & tArtist & "|||" & (tDur as string) & "|||" & (tPos as string)
            on error
                return "NONE"
            end try
        end tell
        """
        guard let out = runInProcessAppleScript(script), out != "NONE" else { return nil }
        let parts = out.components(separatedBy: "|||")
        guard parts.count >= 5 else { return nil }
        let dur = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        let pos = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let title = parts[1].isEmpty ? "Music" : parts[1]
        let artist = parts[2]
        let art = resolveArtwork(cacheKey: "music|\(title)|\(artist)", spotifyURL: nil, isMusic: true)
        return NowPlayingState(
            source: .music,
            title: title,
            artist: artist,
            duration: dur,
            elapsed: pos,
            isPlaying: parts[0].lowercased() == "playing",
            canSeek: dur > 0,
            artwork: art,
            appIcon: iconForApp(bundleID: "com.apple.Music"),
            appBundleID: "com.apple.Music",
            fetchedAt: Date()
        )
    }

    private func queryVLC() -> NowPlayingState? {
        let script = """
        tell application "VLC"
            try
                set isP to playing
                set tName to name of current item
                set tDur to duration of current item
                set tPos to current time
                return (isP as string) & "|||" & tName & "|||" & (tDur as string) & "|||" & (tPos as string)
            on error
                return "NONE"
            end try
        end tell
        """
        guard let out = runInProcessAppleScript(script), out != "NONE" else { return nil }
        let parts = out.components(separatedBy: "|||")
        guard parts.count >= 4 else { return nil }
        let dur = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
        let pos = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        return NowPlayingState(
            source: .vlc,
            title: parts[1].isEmpty ? "VLC" : parts[1],
            artist: "VLC",
            duration: dur,
            elapsed: pos,
            isPlaying: parts[0].lowercased() == "true",
            canSeek: dur > 0,
            artwork: nil,
            appIcon: iconForApp(bundleID: "org.videolan.vlc"),
            appBundleID: "org.videolan.vlc",
            fetchedAt: Date()
        )
    }

    /// Fetches & downsamples album cover to a crisp 52x52px Retina thumbnail.
    /// Apple Music artwork is read instantaneously from local memory; Spotify URL artwork downloads asynchronously so the UI never blocks!
    private func resolveArtwork(cacheKey: String, spotifyURL: String?, isMusic: Bool) -> NSImage? {
        if cacheKey == cachedArtworkKey {
            return cachedArtworkImage
        }

        if isMusic {
            let artScript = """
            tell application "Music"
                try
                    return raw data of artwork 1 of current track
                end try
            end tell
            """
            var thumb: NSImage? = nil
            if let script = NSAppleScript(source: artScript) {
                var err: NSDictionary?
                let desc = script.executeAndReturnError(&err)
                if err == nil && desc.data.count > 64 {
                    thumb = Self.downsampleThumbnail(data: desc.data, pixelSize: 52)
                }
            }
            cachedArtworkKey = cacheKey
            cachedArtworkImage = thumb
            return thumb
        }

        // Spotify: non-blocking async URL download -> refreshes Touch Bar as soon as cover arrives
        if let urlStr = spotifyURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
            if artworkFetchInFlightKey != cacheKey {
                artworkFetchInFlightKey = cacheKey
                urlSession.dataTask(with: url) { [weak self] data, _, _ in
                    guard let self = self else { return }
                    let thumb = data.flatMap { Self.downsampleThumbnail(data: $0, pixelSize: 52) }
                    self.queue.async {
                        self.artworkFetchInFlightKey = nil
                        self.cachedArtworkKey = cacheKey
                        self.cachedArtworkImage = thumb
                        let currentKey = "\(self.lastState.source.rawValue.lowercased())|\(self.lastState.title)|\(self.lastState.artist)"
                        if currentKey == cacheKey {
                            self.lastState.artwork = thumb
                            let updated = self.lastState
                            DispatchQueue.main.async {
                                self.onStateUpdated?(updated)
                            }
                        }
                    }
                }.resume()
            }
        }
        return nil
    }

    private static func downsampleThumbnail(data: Data, pixelSize: Int) -> NSImage? {
        guard let src = NSImage(data: data),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: 26, height: 26))
    }

    private func runInProcessAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        guard err == nil else { return nil }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import CPrivateAPIs

struct NowPlayingState {
    enum Source: String {
        case spotify = "Spotify"
        case music = "Music"
        case vlc = "VLC"
        case universal = "Media"
    }

    var source: Source = .universal
    var title: String = "No Active Media"
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

    // Live push cache populated instantaneously via DistributedNotificationCenter
    // (Spotify: com.spotify.client.PlaybackStateChanged, Apple Music: com.apple.Music.playerInfo)
    // Works with ZERO Automation permission & 0ms latency!
    private var pushedStates: [String: NowPlayingState] = [:]

    // Caches
    private var cachedArtworkKey: String = ""
    private var cachedArtworkImage: NSImage? = nil
    private var artworkFetchInFlightKey: String? = nil
    private var appIconCache: [String: NSImage] = [:]

    // Called on main thread whenever live playback state or async artwork updates
    var onStateUpdated: ((NowPlayingState) -> Void)?

    private lazy var urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 5.0
        return URLSession(configuration: cfg)
    }()

    private init() {
        setupDistributedPlayerObservers()
    }

    // MARK: - Zero-Permission Live Push Observers (Spotify & Apple Music)
    private func setupDistributedPlayerObservers() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleSpotifyNotification(note.userInfo)
        }
        dnc.addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleMusicNotification(note.userInfo)
        }
    }

    private func handleSpotifyNotification(_ info: [AnyHashable: Any]?) {
        guard let info = info else { return }
        let playerState = (info["Player State"] as? String ?? "").lowercased()
        let title = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        // Spotify broadcasts Duration in seconds (only convert if unexpectedly in ms > 24h)
        let rawDur = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
        let dur = rawDur > 86400 ? (rawDur / 1000.0) : rawDur
        let pos = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        let isPlaying = (playerState == "playing")

        queue.async { [weak self] in
            guard let self = self else { return }
            if playerState == "stopped" || title.isEmpty {
                self.pushedStates.removeValue(forKey: "com.spotify.client")
                return
            }
            let cacheKey = "spotify|\(title)|\(artist)"
            let existingArt = (self.cachedArtworkKey == cacheKey) ? self.cachedArtworkImage : nil
            let state = NowPlayingState(
                source: .spotify,
                title: title,
                artist: artist,
                duration: dur,
                elapsed: pos,
                isPlaying: isPlaying,
                canSeek: dur > 0,
                artwork: existingArt,
                appIcon: self.iconForApp(bundleID: "com.spotify.client"),
                appBundleID: "com.spotify.client",
                fetchedAt: Date()
            )
            self.pushedStates["com.spotify.client"] = state
            if isPlaying {
                self.lastPlayingBundleID = "com.spotify.client"
            }
            // Promote immediately if playing or if Spotify is our active source
            if isPlaying || self.lastState.appBundleID == "com.spotify.client" || self.lastState.appBundleID == nil {
                self.lastState = state
                DispatchQueue.main.async {
                    self.onStateUpdated?(state)
                }
                // Try fetching Spotify album art via AppleScript asynchronously if not cached yet
                if existingArt == nil {
                    self.fetchSpotifyArtworkAsync(cacheKey: cacheKey)
                }
            }
        }
    }

    private func handleMusicNotification(_ info: [AnyHashable: Any]?) {
        guard let info = info else { return }
        let playerState = (info["Player State"] as? String ?? "").lowercased()
        let title = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        // Apple Music always broadcasts Total Time in milliseconds
        let rawDur = (info["Total Time"] as? NSNumber)?.doubleValue ?? 0
        let dur = rawDur / 1000.0
        let isPlaying = (playerState == "playing")

        queue.async { [weak self] in
            guard let self = self else { return }
            if playerState == "stopped" || title.isEmpty {
                self.pushedStates.removeValue(forKey: "com.apple.Music")
                return
            }
            let cacheKey = "music|\(title)|\(artist)"
            let existingArt = (self.cachedArtworkKey == cacheKey) ? self.cachedArtworkImage : nil
            let prevPos = (self.lastState.title == title && self.lastState.source == .music)
                ? self.lastState.interpolatedElapsed()
                : 0
            let state = NowPlayingState(
                source: .music,
                title: title,
                artist: artist,
                duration: dur,
                elapsed: prevPos,
                isPlaying: isPlaying,
                canSeek: dur > 0,
                artwork: existingArt,
                appIcon: self.iconForApp(bundleID: "com.apple.Music"),
                appBundleID: "com.apple.Music",
                fetchedAt: Date()
            )
            self.pushedStates["com.apple.Music"] = state
            if isPlaying {
                self.lastPlayingBundleID = "com.apple.Music"
            }
            if isPlaying || self.lastState.appBundleID == "com.apple.Music" || self.lastState.appBundleID == nil {
                self.lastState = state
                DispatchQueue.main.async {
                    self.onStateUpdated?(state)
                }
                // Refresh exact elapsed position & artwork via AppleScript
                if let exact = self.queryMusic() {
                    self.pushedStates["com.apple.Music"] = exact
                    self.lastState = exact
                    DispatchQueue.main.async {
                        self.onStateUpdated?(exact)
                    }
                }
            }
        }
    }

    // MARK: - App Lifecycle Cleanup (Eliminates Stale Info Immediately When Closing Any Player)
    func handleAppTerminated(bundleID: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pushedStates.removeValue(forKey: bundleID)
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

    // MARK: - Fetch Live Metadata (No Deadlocking AEDeterminePermission; Combines Direct NSAppleScript + Push Cache + Cross-Space Windows)
    func fetchNowPlaying(completion: @escaping (NowPlayingState) -> Void) {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningIDs = Set(runningApps.compactMap { $0.bundleIdentifier })
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBid = frontApp?.bundleIdentifier

        queue.async { [weak self] in
            guard let self = self else { return }

            // Purge any state belonging to terminated apps
            for bid in Array(self.pushedStates.keys) where !runningIDs.contains(bid) {
                self.pushedStates.removeValue(forKey: bid)
            }
            if let oldBid = self.lastState.appBundleID, !runningIDs.contains(oldBid) {
                self.lastState = NowPlayingState()
                self.cachedArtworkKey = ""
                self.cachedArtworkImage = nil
            }
            if let lpBid = self.lastPlayingBundleID, !runningIDs.contains(lpBid) {
                self.lastPlayingBundleID = nil
            }

            // Gather live state from running native players (Direct NSAppleScript -> falls back to DistributedNotification push cache -> falls back to cross-Space window title)
            var nativeStates: [String: NowPlayingState] = [:]

            if runningIDs.contains("com.spotify.client") {
                if let s = self.querySpotify() {
                    nativeStates["com.spotify.client"] = s
                    self.pushedStates["com.spotify.client"] = s
                } else if let pushed = self.pushedStates["com.spotify.client"] {
                    nativeStates["com.spotify.client"] = pushed
                } else if let winSpotify = self.fallbackSpotifyFromWindows(runningApps: runningApps) {
                    nativeStates["com.spotify.client"] = winSpotify
                }
            }

            if runningIDs.contains("com.apple.Music") {
                if let m = self.queryMusic() {
                    nativeStates["com.apple.Music"] = m
                    self.pushedStates["com.apple.Music"] = m
                } else if let pushed = self.pushedStates["com.apple.Music"] {
                    nativeStates["com.apple.Music"] = pushed
                }
            }

            if runningIDs.contains("org.videolan.vlc"), let v = self.queryVLC() {
                nativeStates["org.videolan.vlc"] = v
            }

            var detected: NowPlayingState? = nil

            // Priority 1: Any native player currently PLAYING
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

            // Priority 2: Frontmost native player (even if paused)
            if detected == nil, let fBid = frontBid, let st = nativeStates[fBid] {
                detected = st
            }

            // Priority 3: Frontmost browser / video player with a media tab (YouTube, IINA)
            if detected == nil,
               Self.isBrowserOrVideoBundle(frontBid),
               let browserMedia = self.detectBrowserOrPlayerWindowMedia(runningApps: runningApps, frontmost: frontApp) {
                detected = browserMedia
            }

            // Priority 4: Most recently playing native player still running
            if detected == nil, let lpBid = self.lastPlayingBundleID, let st = nativeStates[lpBid] {
                detected = st
            }

            // Priority 5: Any running native player with a loaded track
            if detected == nil {
                for bid in ["com.spotify.client", "com.apple.Music", "org.videolan.vlc"] {
                    if let st = nativeStates[bid] {
                        detected = st
                        break
                    }
                }
            }

            // Priority 6: Background browser media tab across any Space
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

    // MARK: - Transport Controls (Direct when native player active & permitted, universal HID fallback)
    func togglePlayPause(completion: ((NowPlayingState) -> Void)? = nil) {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        queue.async { [weak self] in
            guard let self = self else { return }
            var handled = false

            if let bid = self.lastState.appBundleID, runningIDs.contains(bid) {
                switch self.lastState.source {
                case .spotify:
                    handled = self.runAppleScriptCommand("tell application \"Spotify\" to playpause")
                case .music:
                    handled = self.runAppleScriptCommand("tell application \"Music\" to playpause")
                case .vlc:
                    handled = self.runAppleScriptCommand("tell application \"VLC\" to play")
                default:
                    break
                }
            }

            if !handled {
                TBPostAuxKey(16, false) // NX_KEYTYPE_PLAY
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
                case .spotify:
                    handled = self.runAppleScriptCommand("tell application \"Spotify\" to next track")
                case .music:
                    handled = self.runAppleScriptCommand("tell application \"Music\" to next track")
                case .vlc:
                    handled = self.runAppleScriptCommand("tell application \"VLC\" to next")
                default:
                    break
                }
            }

            if !handled {
                TBPostAuxKey(19, false)
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
                case .spotify:
                    handled = self.runAppleScriptCommand("tell application \"Spotify\" to previous track")
                case .music:
                    handled = self.runAppleScriptCommand("tell application \"Music\" to previous track")
                case .vlc:
                    handled = self.runAppleScriptCommand("tell application \"VLC\" to previous")
                default:
                    break
                }
            }

            if !handled {
                TBPostAuxKey(20, false)
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

    // MARK: - Cross-Space Window Title Detection (CGWindowList + AXUIElement)
    private func allWindowTitles(forPID pid: pid_t) -> [String] {
        var titles: [String] = []

        // 1. Current Space via AXUIElement
        if TBIsAccessibilityTrusted(false) {
            let appElem = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for win in windows {
                    var titleRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                       let title = titleRef as? String, !title.isEmpty {
                        titles.append(title)
                    }
                }
            }
        }

        // 2. All Spaces via CGWindowListCopyWindowInfo
        if let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                      let name = w[kCGWindowName as String] as? String, !name.isEmpty else { continue }
                if !titles.contains(name) {
                    titles.append(name)
                }
            }
        }

        return titles
    }

    private func fallbackSpotifyFromWindows(runningApps: [NSRunningApplication]) -> NowPlayingState? {
        guard let spotifyApp = runningApps.first(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            return nil
        }
        let icon = iconForApp(bundleID: "com.spotify.client")
        for t in allWindowTitles(forPID: spotifyApp.processIdentifier) {
            if t == "Spotify" || t == "Spotify Free" || t == "Spotify Premium" { continue }
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

    private func detectBrowserOrPlayerWindowMedia(runningApps: [NSRunningApplication], frontmost: NSRunningApplication?) -> NowPlayingState? {
        let mediaAppHints = ["iina", "zen", "chrome", "safari", "firefox", "arc", "brave"]
        var candidates = runningApps.filter { app in
            guard let bid = app.bundleIdentifier?.lowercased() else { return false }
            return mediaAppHints.contains(where: { bid.contains($0) })
        }
        if let frontPID = frontmost?.processIdentifier {
            candidates.sort { ($0.processIdentifier == frontPID ? 0 : 1) < ($1.processIdentifier == frontPID ? 0 : 1) }
        }

        for app in candidates {
            let rawBid = app.bundleIdentifier ?? ""
            let bid = rawBid.lowercased()
            let appIcon = !rawBid.isEmpty ? iconForApp(bundleID: rawBid) : nil

            for rawTitle in allWindowTitles(forPID: app.processIdentifier) {
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

                if let parsed = parseMediaBrowserTitle(rawTitle) {
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

    private func parseMediaBrowserTitle(_ raw: String) -> (title: String, subtitle: String)? {
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

    // MARK: - Direct In-Process NSAppleScript Queries (No AEDeterminePermission Deadlock!)
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

    private func fetchSpotifyArtworkAsync(cacheKey: String) {
        if let urlStr = runInProcessAppleScript("tell application \"Spotify\" to try\nreturn artwork url of current track\non error\nreturn \"\"\nend try"),
           !urlStr.isEmpty {
            _ = resolveArtwork(cacheKey: cacheKey, spotifyURL: urlStr, isMusic: false)
        }
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

    /// Executes a void AppleScript command (e.g. playpause / next track) where stringValue is nil on success.
    private func runAppleScriptCommand(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        return err == nil
    }
}

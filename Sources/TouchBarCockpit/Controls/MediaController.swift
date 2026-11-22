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
    var title: String = "Media Controls"
    var artist: String = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var isPlaying: Bool = false
    var canSeek: Bool = false
    var artwork: NSImage? = nil
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
    private var promptedBundles: Set<String> = []
    private var cachedArtworkKey: String = ""
    private var cachedArtworkImage: NSImage? = nil

    // MARK: - Fetch Live Metadata (Apple Music / Spotify / VLC via NSAppleScript + Zen/Chrome/IINA via AXUIElement)
    func fetchNowPlaying(completion: @escaping (NowPlayingState) -> Void) {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningIDs = Set(runningApps.compactMap { $0.bundleIdentifier })
        let frontApp = NSWorkspace.shared.frontmostApplication

        queue.async { [weak self] in
            guard let self = self else { return }
            var detected: NowPlayingState? = nil

            // 1. Check actively playing native players first (in-process NSAppleScript -> real track + duration + scrubber!)
            if runningIDs.contains("com.spotify.client"),
               self.ensureAutomationPermission(bundleID: "com.spotify.client"),
               let s = self.querySpotify(), s.isPlaying {
                detected = s
            } else if runningIDs.contains("com.apple.Music"),
                      self.ensureAutomationPermission(bundleID: "com.apple.Music"),
                      let m = self.queryMusic(), m.isPlaying {
                detected = m
            } else if runningIDs.contains("org.videolan.vlc"),
                      self.ensureAutomationPermission(bundleID: "org.videolan.vlc"),
                      let v = self.queryVLC(), v.isPlaying {
                detected = v
            }

            // 2. If none actively playing, check if a browser/video player has a media tab (YouTube, YouTube Music, IINA)
            if detected == nil, let browserMedia = self.detectBrowserOrPlayerWindowMedia(runningApps: runningApps, frontmost: frontApp) {
                detected = browserMedia
            }

            // 3. Otherwise check paused Spotify / Music / VLC with a loaded track
            if detected == nil {
                if runningIDs.contains("com.spotify.client"),
                   self.ensureAutomationPermission(bundleID: "com.spotify.client"),
                   let s = self.querySpotify(), s.duration > 0 {
                    detected = s
                } else if runningIDs.contains("com.apple.Music"),
                          self.ensureAutomationPermission(bundleID: "com.apple.Music"),
                          let m = self.queryMusic(), m.duration > 0 {
                    detected = m
                } else if runningIDs.contains("org.videolan.vlc"),
                          self.ensureAutomationPermission(bundleID: "org.videolan.vlc"),
                          let v = self.queryVLC(), v.duration > 0 {
                    detected = v
                }
            }

            let finalState: NowPlayingState
            if let d = detected {
                finalState = d
            } else {
                var fallback = self.lastState
                fallback.source = .universal
                fallback.title = frontApp?.localizedName ?? "Now Playing"
                fallback.artist = "Universal Media"
                fallback.duration = 0
                fallback.elapsed = 0
                fallback.canSeek = false
                finalState = fallback
            }

            self.lastState = finalState
            DispatchQueue.main.async {
                completion(finalState)
            }
        }
    }

    // MARK: - Universal Transport Controls (Works for Zen YouTube, Music, Spotify, Chrome, IINA!)
    func togglePlayPause(completion: ((NowPlayingState) -> Void)? = nil) {
        TBPostAuxKey(16, false) // NX_KEYTYPE_PLAY
        lastState.isPlaying.toggle()
        lastState.fetchedAt = Date()

        if let completion = completion {
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.fetchNowPlaying(completion: completion)
            }
        }
    }

    func nextTrack(completion: ((NowPlayingState) -> Void)? = nil) {
        TBPostAuxKey(19, false) // NX_KEYTYPE_FAST
        if let completion = completion {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.fetchNowPlaying(completion: completion)
            }
        }
    }

    func previousTrack(completion: ((NowPlayingState) -> Void)? = nil) {
        TBPostAuxKey(20, false) // NX_KEYTYPE_REWIND
        if let completion = completion {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.fetchNowPlaying(completion: completion)
            }
        }
    }

    // MARK: - Absolute & Relative Scrubbing
    func seek(to seconds: Double, completion: ((NowPlayingState) -> Void)? = nil) {
        let clamped = max(0, seconds)
        let src = lastState.source
        queue.async { [weak self] in
            switch src {
            case .spotify:
                _ = self?.runInProcessAppleScript(String(format: "tell application \"Spotify\" to set player position to %.2f", clamped))
            case .music:
                _ = self?.runInProcessAppleScript(String(format: "tell application \"Music\" to set player position to %.2f", clamped))
            case .vlc:
                _ = self?.runInProcessAppleScript(String(format: "tell application \"VLC\" to set current time to %d", Int(clamped)))
            case .universal:
                break
            }
            if let completion = completion {
                self?.fetchNowPlaying(completion: completion)
            }
        }
    }

    func seekRelative(deltaSeconds: Double, completion: ((NowPlayingState) -> Void)? = nil) {
        let src = lastState.source
        let frontIsVideoApp = Self.isBrowserOrVideoAppFrontmost()
        queue.async { [weak self] in
            switch src {
            case .spotify:
                let cur = self?.lastState.interpolatedElapsed() ?? 0
                let target = max(0, cur + deltaSeconds)
                _ = self?.runInProcessAppleScript(String(format: "tell application \"Spotify\" to set player position to %.2f", target))
            case .music:
                let cur = self?.lastState.interpolatedElapsed() ?? 0
                let target = max(0, cur + deltaSeconds)
                _ = self?.runInProcessAppleScript(String(format: "tell application \"Music\" to set player position to %.2f", target))
            case .vlc:
                let cur = self?.lastState.interpolatedElapsed() ?? 0
                let target = max(0, cur + deltaSeconds)
                _ = self?.runInProcessAppleScript(String(format: "tell application \"VLC\" to set current time to %d", Int(target)))
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
                self?.fetchNowPlaying(completion: completion)
            }
        }
    }

    // MARK: - Automation Permission Check (Prompts cleanly once per target app)
    private func ensureAutomationPermission(bundleID: String) -> Bool {
        var targetDesc = AEAddressDesc()
        guard let cStr = bundleID.cString(using: .utf8) else { return false }
        let createErr = AECreateDesc(DescType(typeApplicationBundleID), cStr, strlen(cStr), &targetDesc)
        guard createErr == noErr else { return false }
        defer { AEDisposeDesc(&targetDesc) }

        let shouldAsk = !promptedBundles.contains(bundleID)
        promptedBundles.insert(bundleID)

        let status = AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            shouldAsk
        )
        return status == noErr
    }

    // MARK: - Accessibility Window Title Detection for Zen / Chrome / Safari / IINA
    private func detectBrowserOrPlayerWindowMedia(runningApps: [NSRunningApplication], frontmost: NSRunningApplication?) -> NowPlayingState? {
        guard TBIsAccessibilityTrusted(false) else { return nil }

        // Check IINA first if running, then browsers (prefer frontmost browser)
        let mediaAppHints = ["iina", "zen", "chrome", "safari", "firefox", "arc", "brave"]
        var candidates = runningApps.filter { app in
            guard let bid = app.bundleIdentifier?.lowercased() else { return false }
            return mediaAppHints.contains(where: { bid.contains($0) })
        }
        // Put frontmost candidate first
        if let frontPID = frontmost?.processIdentifier {
            candidates.sort { ($0.processIdentifier == frontPID ? 0 : 1) < ($1.processIdentifier == frontPID ? 0 : 1) }
        }

        for app in candidates {
            let appName = app.localizedName ?? "Browser"
            let bid = app.bundleIdentifier?.lowercased() ?? ""
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
                        fetchedAt: Date()
                    )
                }

                // Match YouTube / YouTube Music / Spotify Web / SoundCloud / Netflix / Twitch tabs
                if let parsed = parseMediaBrowserTitle(rawTitle, appName: appName) {
                    return NowPlayingState(
                        source: .universal,
                        title: parsed.title,
                        artist: parsed.subtitle,
                        duration: 0,
                        elapsed: 0,
                        isPlaying: lastState.isPlaying,
                        canSeek: false,
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
        // Strip browser suffix (" — Zen Browser", " - Google Chrome", etc.)
        var cleaned = raw
        for suffix in [" — Zen Browser", " - Zen Browser", " — Mozilla Firefox", " - Google Chrome", " - Brave", " - Arc"] {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
            }
        }

        // Remove leading notification count like "(2) "
        if cleaned.hasPrefix("("), let closeParen = cleaned.firstIndex(of: ")") {
            let inside = cleaned[cleaned.index(after: cleaned.startIndex)..<closeParen]
            if inside.allSatisfy({ $0.isNumber }) {
                cleaned = String(cleaned[cleaned.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        let services: [(marker: String, label: String)] = [
            (" - YouTube Music", "YouTube Music · \(appName)"),
            (" - YouTube", "YouTube · \(appName)"),
            (" | Spotify", "Spotify Web · \(appName)"),
            (" - SoundCloud", "SoundCloud · \(appName)"),
            (" - Twitch", "Twitch · \(appName)"),
            (" - Netflix", "Netflix · \(appName)")
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

    private static func isBrowserOrVideoAppFrontmost() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else {
            return false
        }
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
        let art = resolveArtwork(cacheKey: "spotify|\(title)|\(artist)", spotifyURL: artURL, isMusic: false)
        return NowPlayingState(
            source: .spotify,
            title: title,
            artist: artist,
            duration: dur,
            elapsed: pos,
            isPlaying: parts[0].lowercased() == "playing",
            canSeek: dur > 0,
            artwork: art,
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
            fetchedAt: Date()
        )
    }

    /// Fetches & downsamples album cover to a crisp 52x52px Retina thumbnail, cached once per track.
    private func resolveArtwork(cacheKey: String, spotifyURL: String?, isMusic: Bool) -> NSImage? {
        if cacheKey == cachedArtworkKey {
            return cachedArtworkImage
        }

        var rawData: Data? = nil
        if isMusic {
            let artScript = """
            tell application "Music"
                try
                    return raw data of artwork 1 of current track
                end try
            end tell
            """
            if let script = NSAppleScript(source: artScript) {
                var err: NSDictionary?
                let desc = script.executeAndReturnError(&err)
                if err == nil && desc.data.count > 64 {
                    rawData = desc.data
                }
            }
        } else if let urlStr = spotifyURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
            rawData = try? Data(contentsOf: url)
        }

        let thumb = rawData.flatMap { Self.downsampleThumbnail(data: $0, pixelSize: 52) }
        cachedArtworkKey = cacheKey
        cachedArtworkImage = thumb
        return thumb
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
            fetchedAt: Date()
        )
    }

    private func runInProcessAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        guard err == nil else { return nil }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

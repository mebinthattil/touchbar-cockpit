import AppKit
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

    // MARK: - Fetch Live Metadata (Only binds to Spotify/Music/VLC when actually active!)
    func fetchNowPlaying(completion: @escaping (NowPlayingState) -> Void) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let frontName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Media"
        queue.async { [weak self] in
            var detected: NowPlayingState? = nil

            // Prefer an actively playing native player first
            if running.contains("com.spotify.client"), let s = self?.querySpotify(), s.isPlaying {
                detected = s
            } else if running.contains("com.apple.Music"), let m = self?.queryMusic(), m.isPlaying {
                detected = m
            } else if running.contains("org.videolan.vlc"), let v = self?.queryVLC(), v.isPlaying {
                detected = v
            } else if running.contains("com.spotify.client"), let s = self?.querySpotify(), s.duration > 0 {
                // Only use paused Spotify/Music if the user isn't currently in a browser (like Zen/Chrome)
                let isBrowserFront = Self.isBrowserOrVideoAppFrontmost()
                if !isBrowserFront { detected = s }
            } else if running.contains("com.apple.Music"), let m = self?.queryMusic(), m.duration > 0 {
                let isBrowserFront = Self.isBrowserOrVideoAppFrontmost()
                if !isBrowserFront { detected = m }
            }

            let finalState: NowPlayingState
            if let d = detected {
                finalState = d
            } else {
                var fallback = self?.lastState ?? NowPlayingState()
                fallback.source = .universal
                fallback.title = Self.isBrowserOrVideoAppFrontmost() ? frontName : "Now Playing"
                fallback.artist = "Universal Media"
                fallback.duration = 0
                fallback.elapsed = 0
                fallback.canSeek = false
                finalState = fallback
            }

            self?.lastState = finalState
            DispatchQueue.main.async {
                completion(finalState)
            }
        }
    }

    // MARK: - Universal Transport Controls (Works for Zen YouTube, Music, Spotify, Chrome, IINA!)
    func togglePlayPause(completion: ((NowPlayingState) -> Void)? = nil) {
        // Universal HID NX_KEYTYPE_PLAY (16) always targets whichever app macOS Now Playing is playing
        // (including Zen Browser YouTube, Chrome, IINA, Apple Music, and Spotify).
        TBPostAuxKey(16, false)
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
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.fetchNowPlaying(completion: completion)
            }
        }
    }

    func previousTrack(completion: ((NowPlayingState) -> Void)? = nil) {
        TBPostAuxKey(20, false) // NX_KEYTYPE_REWIND
        if let completion = completion {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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
                _ = self?.runAppleScript(String(format: "tell application \"Spotify\" to set player position to %.2f", clamped))
            case .music:
                _ = self?.runAppleScript(String(format: "tell application \"Music\" to set player position to %.2f", clamped))
            case .vlc:
                _ = self?.runAppleScript(String(format: "tell application \"VLC\" to set current time to %d", Int(clamped)))
            case .universal:
                break
            }
            if let completion = completion {
                self?.fetchNowPlaying(completion: completion)
            }
        }
    }

    /// Relative scrub (+/- seconds): works for Spotify/Music/VLC, Zen YouTube, Chrome, Safari, IINA!
    func seekRelative(deltaSeconds: Double, completion: ((NowPlayingState) -> Void)? = nil) {
        let src = lastState.source
        let frontIsVideoApp = Self.isBrowserOrVideoAppFrontmost()
        queue.async { [weak self] in
            switch src {
            case .spotify:
                let cur = self?.lastState.interpolatedElapsed() ?? 0
                let target = max(0, cur + deltaSeconds)
                _ = self?.runAppleScript(String(format: "tell application \"Spotify\" to set player position to %.2f", target))
            case .music:
                let cur = self?.lastState.interpolatedElapsed() ?? 0
                let target = max(0, cur + deltaSeconds)
                _ = self?.runAppleScript(String(format: "tell application \"Music\" to set player position to %.2f", target))
            case .vlc:
                let cur = self?.lastState.interpolatedElapsed() ?? 0
                let target = max(0, cur + deltaSeconds)
                _ = self?.runAppleScript(String(format: "tell application \"VLC\" to set current time to %d", Int(target)))
            case .universal:
                // 1) Try MediaRemote skip command (supported by MediaSession players)
                let ok = TBMediaRemoteSkip(deltaSeconds)
                // 2) For Zen Browser YouTube / Chrome / Safari / IINA when frontmost, also support native arrow/J/L seek
                if frontIsVideoApp {
                    // Left arrow = 123 (-5s on YouTube/IINA), Right arrow = 124 (+5s on YouTube/IINA)
                    let steps = max(1, Int(round(abs(deltaSeconds) / 5.0)))
                    let keyCode: UInt16 = deltaSeconds >= 0 ? 124 : 123
                    for _ in 0..<min(4, steps) {
                        TBPostKeyCode(keyCode)
                    }
                } else if !ok {
                    // Fallback: brief HID rewind/fast-forward
                    TBPostAuxKey(deltaSeconds >= 0 ? 19 : 20, false)
                }
            }
            if let completion = completion {
                self?.fetchNowPlaying(completion: completion)
            }
        }
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

    // MARK: - Player-Specific Queries (Wrapped in try/on error so idle apps never error)
    private func querySpotify() -> NowPlayingState? {
        let script = """
        tell application "Spotify"
            try
                set st to (player state as string)
                if st is "stopped" then return "NONE"
                set tName to name of current track
                set tArtist to artist of current track
                set tDur to (duration of current track) / 1000.0
                set tPos to player position
                return st & "|||" & tName & "|||" & tArtist & "|||" & (tDur as string) & "|||" & (tPos as string)
            on error
                return "NONE"
            end try
        end tell
        """
        guard let out = runAppleScript(script), out != "NONE" else { return nil }
        let parts = out.components(separatedBy: "|||")
        guard parts.count >= 5 else { return nil }
        let dur = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        let pos = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        return NowPlayingState(
            source: .spotify,
            title: parts[1].isEmpty ? "Spotify" : parts[1],
            artist: parts[2],
            duration: dur,
            elapsed: pos,
            isPlaying: parts[0].lowercased() == "playing",
            canSeek: dur > 0,
            fetchedAt: Date()
        )
    }

    private func queryMusic() -> NowPlayingState? {
        let script = """
        tell application "Music"
            try
                set st to (player state as string)
                if st is "stopped" then return "NONE"
                set tName to name of current track
                set tArtist to artist of current track
                set tDur to duration of current track
                set tPos to player position
                return st & "|||" & tName & "|||" & tArtist & "|||" & (tDur as string) & "|||" & (tPos as string)
            on error
                return "NONE"
            end try
        end tell
        """
        guard let out = runAppleScript(script), out != "NONE" else { return nil }
        let parts = out.components(separatedBy: "|||")
        guard parts.count >= 5 else { return nil }
        let dur = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        let pos = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        return NowPlayingState(
            source: .music,
            title: parts[1].isEmpty ? "Music" : parts[1],
            artist: parts[2],
            duration: dur,
            elapsed: pos,
            isPlaying: parts[0].lowercased() == "playing",
            canSeek: dur > 0,
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
        guard let out = runAppleScript(script), out != "NONE" else { return nil }
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

    private func runAppleScript(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

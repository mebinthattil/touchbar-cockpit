# TouchBarCockpit

A lightweight, native Swift (`DFRFoundation`) Touch Bar daemon for Apple Silicon MacBook Pro (M2). Turns the full 1004×30pt Retina OLED strip into an always-on, zero-`sudo` hardware telemetry cockpit with pure eyes-free multi-finger gestures, instant long-press media controls, and single-tap `Fn` native Touch Bar recall.

## Telemetry Cockpit
* **CPU** — 60s rolling area sparkline + 8 per-core E/P vertical load bars (tap for top 3 CPU processes)
* **RAM** — Active / Wired / Compressed segmented bar + live Swap alert (tap for top 3 RAM processes)
* **M2 Thermals & Fan** — Live SoC die temperature (`IOHIDEventSystemClient`) + SMC fan RPM (`AppleSMC`)
* **Dual Power** — Live system draw (`SYS`) + live charger pull (`⚡IN`) + battery % & bar (tap for full PD breakdown)
* **Network & Privacy** — Live `↓ / ↑` throughput sparkline + active Tailscale (`T`), VPN (`V`), and Proxy (`P`) badges
* **Clock** — Live time + tap to open the Media Overlay without pausing playback

## Controls
* **2-Finger Slide anywhere** → System Volume (native 1/64th HID fine steps + macOS HUD popup; drop to 1 finger anytime for finer control) · **2-Finger Tap** → Mute
* **3-Finger Slide anywhere** → Built-in Display Brightness (native 1/64th HID fine steps + macOS HUD popup; drop to 1 finger anytime for finer control)
* **Long-Press anywhere (~0.4s)** → Pauses media and opens the full-width Media Overlay (`Prev`, `Play/Pause`, `Next`, plus timeline scrubber for Spotify/Music/VLC or `-10s` / drag jog-scrubber / `+10s` for Zen Browser YouTube, Chrome, IINA, etc.)
* **Tap Clock** → Opens the Media Overlay immediately without pausing playback
* **Single-Tap `Fn`** → Pause cockpit and restore macOS's native Touch Bar; tap `Fn` again to resume

## Build & Run

```bash
./Scripts/build-app.sh
open build/TouchBarCockpit.app
```

> Uses your local `Apple Development` signing identity automatically (when available) so macOS Accessibility permissions persist across rebuilds.

### Auto-start at Login (Optional)

```bash
./Scripts/install-launchagent.sh
# To uninstall:
./Scripts/install-launchagent.sh --uninstall
```

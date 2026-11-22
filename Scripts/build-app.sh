#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TouchBarCockpit"
BUNDLE_ID="com.mebin.touchbarcockpit"
APP_DIR="$ROOT_DIR/build/${APP_NAME}.app"

cd "$ROOT_DIR"
echo "Building ${APP_NAME} (release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>TouchBarCockpit reads Now Playing track info and controls playback/scrubbing in Spotify, Music, and VLC.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>TouchBarCockpit analyzes system audio output to render a live minimal Dynamic Island-style waveform on your Touch Bar while media is playing.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Sign with a stable local Apple Development identity if available so macOS
# Accessibility (TCC) permissions persist across rebuilds instead of breaking on ad-hoc hash changes.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}')"
if [[ -n "$SIGN_ID" ]]; then
    echo "Signing with: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" "$APP_DIR"
else
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built app bundle at: $APP_DIR"

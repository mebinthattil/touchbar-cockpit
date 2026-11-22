#!/usr/bin/env bash
# Codex notify wrapper: preserves existing SkyComputerUseClient turn-ended hook
# while also flashing TouchBarCockpit gentle amber for 3s.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BIN="$ROOT_DIR/build/TouchBarCockpit.app/Contents/MacOS/TouchBarCockpit"
SKY_BIN="$HOME/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"

if [[ -x "$APP_BIN" ]]; then
    "$APP_BIN" --flash "Codex" >/dev/null 2>&1 &
fi

if [[ -x "$SKY_BIN" ]]; then
    exec "$SKY_BIN" "turn-ended" "$@"
fi
exit 0

#!/usr/bin/env bash
# Lightweight hook script for Antigravity (agy), Claude Code, and Codex.
# Flashes TouchBarCockpit gentle amber for 3s when the agent finishes and waits for user input.
set -u

AGENT="${1:-Agent}"
APP_BIN="/Users/mebin/Downloads/Work/Coding Projects/touchbar-cockpit/build/TouchBarCockpit.app/Contents/MacOS/TouchBarCockpit"

# Drain stdin (required by agy/claude hook contracts) and skip flash if user manually canceled
PAYLOAD=""
if [[ ! -t 0 ]]; then
    PAYLOAD="$(cat 2>/dev/null || true)"
fi

if [[ "$PAYLOAD" != *"USER_CANCELED"* ]]; then
    if [[ -x "$APP_BIN" ]]; then
        "$APP_BIN" --flash "$AGENT" >/dev/null 2>&1 &
    fi
fi

# Always return valid non-blocking JSON for agy/claude hooks
printf '{"decision":"allow"}\n'
exit 0

#!/usr/bin/env bash
set -euo pipefail

# Runs twintape against the vercel-labs/native fork's `native` CLI
# (built locally from source) instead of the globally installed 0.8.0,
# because global_hotkeys (app.zon's `.global_hotkeys`, Event.global_hotkey)
# AND audio capture (fx.audioCapture, Event.audio_capture) only exist on
# the fork's recorder-sdk branch and have not shipped to @native-sdk/cli
# yet. The default points at the recorder-sdk worktree, where both
# features live merged together - the old native-hotkeys worktree has
# the hotkey half only, so twintape no longer builds against it.

FORK_ROOT="${NATIVE_FORK_ROOT:-/Users/raillyhugo/Programming/vercel-labs/native-recorder-sdk}"
FORK_BIN="$FORK_ROOT/zig-out/bin/native"

if [ ! -x "$FORK_BIN" ]; then
  echo "Building the fork's native CLI (zig build cli)..." >&2
  (cd "$FORK_ROOT" && zig build cli)
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -eq 0 ]; then
  set -- dev "$REPO_ROOT"
fi

# The SDK has no screen-bounds query (see src/main.zig), so we measure
# the real main-display size in POINTS here (AppleScript's Finder
# desktop bounds, not system_profiler's pixel resolution) and hand it
# to the app via env vars. Falls through silently if osascript fails
# (e.g. headless CI) and the app keeps its hardcoded oversized default.
SCREEN_BOUNDS="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null || true)"
if [ -n "$SCREEN_BOUNDS" ]; then
  IFS=', ' read -r _x0 _y0 SCREEN_W SCREEN_H <<< "$SCREEN_BOUNDS"
  export TWINTAPE_SCREEN_W="$SCREEN_W"
  export TWINTAPE_SCREEN_H="$SCREEN_H"
fi

# Transcripts go to the vault inbox, WAVs never leave Application Support.
export TWINTAPE_TRX_OUTPUT_DIR="${TWINTAPE_TRX_OUTPUT_DIR:-$HOME/hunter-brain/01_Inbox/recordings}"

export NATIVE_SDK_PATH="$FORK_ROOT"
exec "$FORK_BIN" "$@"

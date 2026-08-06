#!/usr/bin/env bash
set -euo pipefail

# Runs twintape against the vercel-labs/native fork's `native` CLI
# (built locally from source) instead of the globally installed 0.8.0,
# because global_hotkeys (app.zon's `.global_hotkeys`, Event.global_hotkey)
# only exists on the fork's recorder-sdk branch and has not shipped to
# @native-sdk/cli yet.

FORK_ROOT="${NATIVE_FORK_ROOT:-/Users/raillyhugo/Programming/vercel-labs/native-hotkeys}"
FORK_BIN="$FORK_ROOT/zig-out/bin/native"

if [ ! -x "$FORK_BIN" ]; then
  echo "Building the fork's native CLI (zig build cli)..." >&2
  (cd "$FORK_ROOT" && zig build cli)
fi

export NATIVE_SDK_PATH="$FORK_ROOT"
exec "$FORK_BIN" "$@"

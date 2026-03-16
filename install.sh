#!/usr/bin/env bash
# OpenClaw outer-directory redirect
# Placed at the clone root to catch `bash install.sh` run from the wrong folder
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INNER="$SCRIPT_DIR/openclaw-main"

if [ -f "$INNER/package.json" ]; then
  echo ""
  echo "[openclaw] Redirecting to project root: $INNER"
  echo ""
  exec bash "$INNER/install.sh" "$@"
else
  echo "[openclaw] ERROR: openclaw-main/ subfolder not found." >&2
  echo "[openclaw] Expected: $INNER/package.json" >&2
  echo "" >&2
  echo "[openclaw] Try: cd openclaw-main && bash install.sh" >&2
  exit 1
fi

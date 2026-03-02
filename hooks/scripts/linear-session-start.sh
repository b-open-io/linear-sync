#!/usr/bin/env bash
# linear-session-start.sh — SessionStart hook for Linear Sync
# Thin wrapper: delegates all logic to the companion Python script.
# Event: SessionStart (matcher: startup|clear|compact)
# Timeout: 15s
set -euo pipefail
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.claude/linear-sync"
exec python3 "$_DIR/linear-session-start.py" "$_DIR"

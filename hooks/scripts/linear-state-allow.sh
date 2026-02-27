#!/usr/bin/env bash
# linear-state-allow.sh — PreToolUse hook to auto-approve Read/Write on linear-sync paths
# Auto-approves:
#   Read/Write on ~/.claude/linear-sync/ (state file)
#   Read-only on ~/.claude/plugins/cache/crystal-peak/linear-sync/ (plugin scripts for debugging)
# Event: PreToolUse (matcher: Read|Write)
# Timeout: 5s
set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

HOME_DIR="$HOME"

# Read/Write: auto-approve state file operations
if [[ "$FILE_PATH" == "$HOME_DIR/.claude/linear-sync/"* ]] || [[ "$FILE_PATH" == "~/.claude/linear-sync/"* ]]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
fi

# Read only: auto-approve reading plugin scripts (for self-debugging)
if [[ "$TOOL_NAME" == "Read" ]]; then
  if [[ "$FILE_PATH" == "$HOME_DIR/.claude/plugins/cache/crystal-peak/linear-sync/"* ]] || [[ "$FILE_PATH" == "~/.claude/plugins/cache/crystal-peak/linear-sync/"* ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
    exit 0
  fi
fi

exit 0

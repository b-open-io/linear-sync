#!/usr/bin/env bash
# linear-state-allow.sh — PreToolUse hook to auto-approve Read/Write on linear-sync paths
# Auto-approves:
#   Read/Write on ~/.claude/linear-sync/ (state file)
#   Read-only on ~/.claude/plugins/cache/b-open-io/linear-sync/ (plugin scripts for debugging)
# Event: PreToolUse (matcher: Read|Write)
# Timeout: 5s
set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

HOME_DIR="$HOME"
ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

# Read/Write/Edit: auto-approve state file operations (~/.claude/linear-sync/*)
if [[ "$FILE_PATH" == "$HOME_DIR/.claude/linear-sync/"* ]] || [[ "$FILE_PATH" == "~/.claude/linear-sync/"* ]]; then
  printf '%s\n' "$ALLOW"
  exit 0
fi

# Read/Write/Edit: auto-approve repo config (.claude/linear-sync.json)
if [[ "$FILE_PATH" == *"/.claude/linear-sync.json" ]]; then
  printf '%s\n' "$ALLOW"
  exit 0
fi

# Read only: auto-approve reading plugin scripts (for self-debugging)
if [[ "$TOOL_NAME" == "Read" ]]; then
  if [[ "$FILE_PATH" == "$HOME_DIR/.claude/plugins/cache/b-open-io/linear-sync/"* ]] || [[ "$FILE_PATH" == "~/.claude/plugins/cache/b-open-io/linear-sync/"* ]]; then
    printf '%s\n' "$ALLOW"
    exit 0
  fi
fi

# Read only: auto-approve reading MCP config (for workspace resolution)
if [[ "$TOOL_NAME" == "Read" ]] && [[ "$FILE_PATH" == "$HOME_DIR/.claude/mcp.json" ]]; then
  printf '%s\n' "$ALLOW"
  exit 0
fi

exit 0

#!/usr/bin/env bash
# linear-api-allow.sh — PreToolUse hook to auto-approve linear-api.sh commands
# Approves bash commands calling our trusted API wrapper.
# Supports single-line calls, multiline with variable assignments, and heredocs.
# Rejects commands with shell injection patterns.
# Event: PreToolUse (matcher: Bash)
# Timeout: 5s
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

[[ -z "$COMMAND" ]] && exit 0

# Check every line: each must be either a variable assignment, a bash linear-api.sh call,
# a heredoc body, or a safe shell builtin.
# Anything else (chained commands, pipes, subshells) fails the check.
ALL_SAFE=true
HAS_API_CALL=false
HEREDOC_DELIM=""
IN_API_MULTILINE=false

while IFS= read -r line; do
  # Skip empty lines
  [[ -z "$line" ]] && continue

  # If inside a heredoc, skip lines until we hit the closing delimiter
  if [[ -n "$HEREDOC_DELIM" ]]; then
    if [[ "$line" =~ ^[[:space:]]*"$HEREDOC_DELIM"[[:space:]]*$ ]]; then
      HEREDOC_DELIM=""
    fi
    continue
  fi

  # If inside a multiline single-quoted string from a bash linear-api.sh call,
  # skip lines until the closing single quote (e.g., the end of a GraphQL query)
  if $IN_API_MULTILINE; then
    if [[ "$line" == *"'"* ]]; then
      IN_API_MULTILINE=false
    fi
    continue
  fi

  # bash linear-api.sh call (with or without quoted path, with or without env-var prefix)
  # Must check BEFORE variable assignment since VAR=val bash ... looks like an assignment
  # Reject if the line contains chaining operators (&&, ||, ;, |) AFTER the bash call
  if echo "$line" | grep -qE '^\s*(([A-Za-z_][A-Za-z_0-9]*="?[^"]*"?\s+)*)?bash\s+"?[^"]*linear-api\.sh"?(\s|$)'; then
    if ! echo "$line" | grep -qE '&&|\|\||;|\|'; then
      HAS_API_CALL=true
      # Check for multiline single-quoted argument (odd number of single quotes = unclosed)
      QUOTE_COUNT=$(echo "$line" | tr -cd "'" | wc -c)
      if (( QUOTE_COUNT % 2 != 0 )); then
        IN_API_MULTILINE=true
      fi
      continue
    fi
  fi
  # Variable assignment: VAR='...' or VAR="..." or VAR=$(...)
  # Must NOT contain && or || or ; (use separate lines for chaining)
  if echo "$line" | grep -qE '^\s*[A-Za-z_][A-Za-z_0-9]*=' && ! echo "$line" | grep -qE '&&|\|\||;'; then
    # Check if this assignment opens a heredoc: VAR=$(cat <<'DELIM') or VAR=$(cat <<DELIM)
    if echo "$line" | grep -qE "<<-?'?([A-Za-z_]+)'?"; then
      HEREDOC_DELIM=$(echo "$line" | sed -nE "s/.*<<-?'?([A-Za-z_]+)'?.*/\1/p")
    fi
    continue
  fi
  # Closing paren from $(...) subshell (e.g., after heredoc in VAR=$(cat <<'EOF' ... EOF\n) )
  if echo "$line" | grep -qE '^\s*\)\s*$'; then
    continue
  fi
  # Safe shell builtins: set +H (disable history expansion), export, shopt
  if echo "$line" | grep -qE '^\s*(set\s+[+-][A-Za-z]|set\s+[+-]o\s+\w+|export\s+[A-Za-z_]|shopt\s)'; then
    continue
  fi
  # cd /path as a safe standalone line
  if echo "$line" | grep -qE '^\s*cd\s+'; then
    # Check if it's cd && bash linear-api.sh (API call pattern)
    if echo "$line" | grep -qE '^\s*cd\s+\S+\s*&&\s*bash\s+"?[^"]*linear-api\.sh"?(\s|$)'; then
      HAS_API_CALL=true
      # Check for multiline single-quoted argument
      QUOTE_COUNT=$(echo "$line" | tr -cd "'" | wc -c)
      if (( QUOTE_COUNT % 2 != 0 )); then
        IN_API_MULTILINE=true
      fi
      continue
    fi
    # Plain cd (no chaining) is safe
    if ! echo "$line" | grep -qE '&&|\|\||;|\|'; then
      continue
    fi
  fi
  # find in .claude/linear paths is safe
  if echo "$line" | grep -qE '^\s*find\s+' && echo "$line" | grep -qE '\.claude|linear-sync|linear_sync'; then
    if ! echo "$line" | grep -qE '&&|\|\||;|\|'; then
      continue
    fi
  fi
  # Unknown line — not safe
  ALL_SAFE=false
  break
done <<< "$COMMAND"

# Fail if we ended inside an unclosed heredoc (malformed command)
if [[ -n "$HEREDOC_DELIM" ]]; then
  ALL_SAFE=false
fi

if $ALL_SAFE && $HAS_API_CALL; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
fi

exit 0

#!/usr/bin/env bash
# install.sh — Idempotent installer for Linear Sync
# Copies all linear-sync files into ~/.claude/
# Safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "Linear Sync Installer"
echo "====================="
echo ""

# ---------- 0. Check prerequisites ----------
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not found in PATH."
  echo "All linear-sync hooks depend on python3 for JSON parsing."
  echo "Please install Python 3 and ensure 'python3' is available, then re-run this installer."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but not found in PATH."
  echo "The linear-api.sh wrapper uses curl for Linear API calls."
  echo "Please install curl and re-run this installer."
  exit 1
fi

# ---------- 1. Create directories ----------
echo "[1/8] Creating directories..."
mkdir -p "$CLAUDE_DIR/agents"
mkdir -p "$CLAUDE_DIR/hooks"
mkdir -p "$CLAUDE_DIR/scripts"

# ---------- 2. Copy subagent ----------
echo "[2/8] Installing subagent definition..."
cp "$SCRIPT_DIR/agents/linear-sync.md" "$CLAUDE_DIR/agents/linear-sync.md"
echo "  -> ~/.claude/agents/linear-sync.md"

# ---------- 3. Copy hook scripts and API wrapper ----------
echo "[3/8] Installing hook scripts..."
for hook in linear-session-start.sh linear-prompt-check.sh linear-commit-guard.sh; do
  cp "$SCRIPT_DIR/hooks/$hook" "$CLAUDE_DIR/hooks/$hook"
  chmod +x "$CLAUDE_DIR/hooks/$hook"
  echo "  -> ~/.claude/hooks/$hook"
done
cp "$SCRIPT_DIR/scripts/linear-api.sh" "$CLAUDE_DIR/scripts/linear-api.sh"
chmod +x "$CLAUDE_DIR/scripts/linear-api.sh"
echo "  -> ~/.claude/scripts/linear-api.sh"
cp "$SCRIPT_DIR/scripts/sync-github-issues.sh" "$CLAUDE_DIR/scripts/sync-github-issues.sh"
chmod +x "$CLAUDE_DIR/scripts/sync-github-issues.sh"
echo "  -> ~/.claude/scripts/sync-github-issues.sh"

# ---------- 4. Initialize state file (only if missing) ----------
echo "[4/8] Checking state file..."
if [ ! -f "$CLAUDE_DIR/scripts/linear-repo-links.json" ]; then
  cp "$SCRIPT_DIR/scripts/linear-repo-links.json" "$CLAUDE_DIR/scripts/linear-repo-links.json"
  echo "  -> Created ~/.claude/scripts/linear-repo-links.json"
else
  echo "  -> ~/.claude/scripts/linear-repo-links.json already exists (preserved)"
fi

# ---------- 5. Handle settings.json ----------
echo "[5/8] Checking settings.json..."
if [ ! -f "$CLAUDE_DIR/settings.json" ]; then
  cp "$SCRIPT_DIR/settings.json" "$CLAUDE_DIR/settings.json"
  echo "  -> Created ~/.claude/settings.json"
elif grep -q "linear-session-start" "$CLAUDE_DIR/settings.json" 2>/dev/null; then
  echo "  -> ~/.claude/settings.json already has linear-sync hooks (skipped)"
else
  # Merge our hooks into the existing settings.json using python3
  HOOKS_FILE="$SCRIPT_DIR/settings.json" TARGET_FILE="$CLAUDE_DIR/settings.json" python3 -c "
import json, os

hooks_file = os.environ['HOOKS_FILE']
target_file = os.environ['TARGET_FILE']

with open(target_file) as f:
    existing = json.load(f)

with open(hooks_file) as f:
    new_hooks = json.load(f)['hooks']

if 'hooks' not in existing:
    existing['hooks'] = {}

# Merge each hook event, appending our entries to any existing ones
for event, entries in new_hooks.items():
    if event not in existing['hooks']:
        existing['hooks'][event] = entries
    else:
        existing['hooks'][event].extend(entries)

with open(target_file, 'w') as f:
    json.dump(existing, f, indent=2)
    f.write('\n')
" 2>/dev/null

  if grep -q "linear-session-start" "$CLAUDE_DIR/settings.json" 2>/dev/null; then
    echo "  -> Merged linear-sync hooks into ~/.claude/settings.json"
  else
    echo "  ERROR: Failed to merge hooks into ~/.claude/settings.json"
    echo "  Please merge manually from: $SCRIPT_DIR/settings.json"
    exit 1
  fi
fi

# ---------- 6. Handle CLAUDE.md ----------
echo "[6/8] Checking CLAUDE.md..."
if [ ! -f "$CLAUDE_DIR/CLAUDE.md" ]; then
  cp "$SCRIPT_DIR/CLAUDE-snippet.md" "$CLAUDE_DIR/CLAUDE.md"
  echo "  -> Created ~/.claude/CLAUDE.md"
elif grep -q "Linear Sync (Auto-Managed)" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
  # Replace existing section with latest version
  SNIPPET_FILE="$SCRIPT_DIR/CLAUDE-snippet.md" python3 -c "
import os
claude_md = os.path.expanduser('~/.claude/CLAUDE.md')
with open(claude_md) as f:
    content = f.read()
start_marker = '<!-- ===== Linear Sync (Auto-Managed) ===== -->'
end_marker = '<!-- ===== End Linear Sync ===== -->'
start_idx = content.find(start_marker)
end_idx = content.find(end_marker)
if start_idx >= 0 and end_idx >= 0:
    end_idx += len(end_marker)
    if end_idx < len(content) and content[end_idx] == '\n':
        end_idx += 1
    with open(os.environ['SNIPPET_FILE']) as f:
        snippet = f.read()
    new_content = content[:start_idx] + snippet + content[end_idx:]
    with open(claude_md, 'w') as f:
        f.write(new_content)
"
  echo "  -> Updated Linear Sync section in ~/.claude/CLAUDE.md"
else
  printf '\n' >> "$CLAUDE_DIR/CLAUDE.md"
  cat "$SCRIPT_DIR/CLAUDE-snippet.md" >> "$CLAUDE_DIR/CLAUDE.md"
  echo "  -> Appended Linear Sync section to ~/.claude/CLAUDE.md"
fi

# ---------- 7. Add permissions for linear-api.sh ----------
echo "[7/8] Checking permissions..."
PERMISSION_PATTERN='Bash(bash $HOME/.claude/scripts/linear-api.sh *)'
if grep -q "sync-github-issues.sh" "$CLAUDE_DIR/settings.json" 2>/dev/null; then
  echo "  -> Permissions already configured (skipped)"
else
  TARGET_FILE="$CLAUDE_DIR/settings.json" python3 -c "
import json, os

target_file = os.environ['TARGET_FILE']
home = os.path.expanduser('~')

with open(target_file) as f:
    settings = json.load(f)

if 'permissions' not in settings:
    settings['permissions'] = {}
if 'allow' not in settings['permissions']:
    settings['permissions']['allow'] = []

# Add patterns for both expanded path and tilde form
# Bash: linear-api.sh wrapper (both path forms)
# Read: state file + mcp.json (subagent reads these)
# Write: state file (subagent persists config)
patterns = [
    'Bash(bash ' + home + '/.claude/scripts/linear-api.sh *)',
    'Bash(' + home + '/.claude/scripts/linear-api.sh *)',
    'Bash(bash ~/.claude/scripts/linear-api.sh *)',
    'Bash(~/.claude/scripts/linear-api.sh *)',
    'Bash(bash ' + home + '/.claude/scripts/sync-github-issues.sh *)',
    'Bash(bash ~/.claude/scripts/sync-github-issues.sh *)',
    'Read(' + home + '/.claude/scripts/*)',
    'Read(~/.claude/scripts/*)',
    'Read(' + home + '/.claude/mcp.json)',
    'Read(~/.claude/mcp.json)',
    'Write(' + home + '/.claude/scripts/linear-repo-links.json)',
    'Write(~/.claude/scripts/linear-repo-links.json)',
]
for p in patterns:
    if p not in settings['permissions']['allow']:
        settings['permissions']['allow'].append(p)

with open(target_file, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" 2>/dev/null

  if grep -q "linear-api.sh" "$CLAUDE_DIR/settings.json" 2>/dev/null; then
    echo "  -> Added permission for linear-api.sh"
  else
    echo "  WARNING: Could not add permission automatically."
    echo "  Add this to ~/.claude/settings.json permissions.allow:"
    echo "    \"$PERMISSION_PATTERN\""
  fi
fi

# ---------- 8. Migrate state file schema (backward-compatible) ----------
echo "[8/8] Checking state file schema..."
if [ -f "$CLAUDE_DIR/scripts/linear-repo-links.json" ]; then
  # Ensure the state file has the expected top-level keys (backward-compatible migration)
  TARGET_FILE="$CLAUDE_DIR/scripts/linear-repo-links.json" python3 -c "
import json, os
target_file = os.environ['TARGET_FILE']
with open(target_file) as f:
    data = json.load(f)
changed = False
for key in ('workspaces', 'repos', 'github_org_defaults'):
    if key not in data:
        data[key] = {}
        changed = True
if changed:
    with open(target_file, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
" 2>/dev/null
  echo "  -> State file schema verified"
fi

# ---------- Done ----------
echo ""
echo "========================================"
echo "  Linear Sync installed successfully!"
echo "========================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Create a Linear API key:"
echo "     Linear > Settings > Security & Access > Personal API Keys > New API key"
echo "     - Name: \"Linear Sync\" (or whatever you like)"
echo "     - Permissions: Full access"
echo "     - Team access: All teams you have access to"
echo "     - Click Create, then copy the key"
echo ""
echo "  2. Add it to ~/.claude/mcp.json:"
echo ""
echo '     {'
echo '       "mcpServers": {'
echo '         "linear": {'
echo '           "type": "stdio",'
echo '           "command": "npx",'
echo '           "args": ["-y", "@anthropic/linear-mcp-server"],'
echo '           "env": {'
echo '             "LINEAR_API_KEY": "<your-linear-api-key>"'
echo '           }'
echo '         }'
echo '       }'
echo '     }'
echo ""
echo "  3. Open Claude Code in any git repo. The session-start hook will"
echo "     detect the repo and walk you through linking it to Linear."
echo ""
echo "  For multiple workspaces, add one MCP server entry per workspace"
echo "  with different API keys."
echo ""
echo "  Optional: Create a .linear-sync-template.json in any repo root"
echo "  to pre-fill setup wizard defaults for that repo:"
echo ""
echo '     {'
echo '       "workspace": "My Workspace",'
echo '       "project": "Project Name",'
echo '       "team": "ENG",'
echo '       "label": "repo:my-repo"'
echo '     }'
echo ""

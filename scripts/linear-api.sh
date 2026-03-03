#!/usr/bin/env bash
# linear-api.sh — Wrapper for Linear GraphQL API calls
# Reads API key from ~/.claude/mcp.json so it never appears in Claude transcripts.
#
# Usage:
#   linear-api.sh [server-name] 'query { ... }'
#   linear-api.sh [server-name] 'mutation { ... }'
#   linear-api.sh [server-name] 'mutation($input: IssueCreateInput!) { ... }' '{"input": {...}}'
#
# server-name: Name of the MCP server entry in mcp.json.
#              Auto-detected from .claude/linear-sync.json + state file if omitted.
#              Fails with error if auto-detection is impossible — no silent defaults.
#              For multi-workspace setups, use the workspace-specific server name
#              (e.g., "linear-opl", "linear-crystalpeak")
#
# When a variables JSON object is provided as the last argument, it is included
# in the request body alongside the query. This avoids inline string interpolation
# and handles escaping of special characters (quotes, newlines, backslashes)
# automatically. Use this for any mutation that includes user-provided text.
set -euo pipefail

MCP_CONFIG="$HOME/.claude/mcp.json"

# ---------- resolve workspace server (no fallback) ----------
resolve_server() {
  # Auto-detect MCP server from repo config + state file.
  # 1. git rev-parse --show-toplevel → repo root
  # 2. Read .claude/linear-sync.json → workspace field
  # 3. Read ~/.claude/linear-sync/state.json → workspaces.<ws>.mcp_server
  # Fails loudly if resolution is impossible — no silent defaults.
  # With set -e, failure here propagates to the caller and exits the script.
  python3 -c "
import json, os, subprocess, sys

# Find repo root
try:
    r = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                       capture_output=True, text=True, timeout=5)
    git_top = r.stdout.strip()
except Exception:
    git_top = ''

if not git_top:
    print(json.dumps({'error': 'Not in a git repo. Pass server name explicitly.'}), file=sys.stderr)
    sys.exit(1)

# Read repo config
repo_cfg_path = os.path.join(git_top, '.claude', 'linear-sync.json')
workspace = ''
try:
    with open(repo_cfg_path) as f:
        repo_cfg = json.load(f)
    workspace = repo_cfg.get('workspace', '')
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    pass

if not workspace:
    repo_name = os.path.basename(git_top)
    print(json.dumps({'error': f'No .claude/linear-sync.json in repo \"{repo_name}\". Pass server name explicitly or run setup.'}), file=sys.stderr)
    sys.exit(1)

# Read state file for mcp_server
state_path = os.path.expanduser('~/.claude/linear-sync/state.json')
try:
    with open(state_path) as f:
        state = json.load(f)
    ws_entry = state.get('workspaces', {}).get(workspace, {})
    mcp_server = ws_entry.get('mcp_server', '')
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    mcp_server = ''

if not mcp_server:
    print(json.dumps({'error': f'Workspace \"{workspace}\" has no mcp_server in state. Pass server name explicitly or run setup.'}), file=sys.stderr)
    sys.exit(1)

print(mcp_server)
"
}

# ---------- parse args ----------
VARIABLES=""
if [ $# -eq 1 ]; then
  SERVER=$(resolve_server)
  QUERY="$1"
elif [ $# -eq 2 ]; then
  if printf '%s' "$1" | python3 -c "
import sys
a = sys.stdin.read().strip()
sys.exit(0 if a.startswith('query') or a.startswith('mutation') or a.startswith('{') else 1)
" 2>/dev/null; then
    SERVER=$(resolve_server)
    QUERY="$1"
    VARIABLES="$2"
  else
    SERVER="$1"
    QUERY="$2"
  fi
elif [ $# -eq 3 ]; then
  SERVER="$1"
  QUERY="$2"
  VARIABLES="$3"
else
  echo '{"error": "Usage: linear-api.sh [server-name] query [variables]"}' >&2
  exit 1
fi

# ---------- read API key from mcp.json ----------
if [ ! -f "$MCP_CONFIG" ]; then
  echo '{"error": "MCP config not found at ~/.claude/mcp.json"}' >&2
  exit 1
fi

API_KEY=$(MCP_CONFIG="$MCP_CONFIG" SERVER="$SERVER" python3 -c '
import json, os
with open(os.environ["MCP_CONFIG"]) as f:
    config = json.load(f)
servers = config.get("mcpServers", {})
server = servers.get(os.environ["SERVER"], {})
env = server.get("env", {})
key = env.get("LINEAR_API_KEY", "")
if not key:
    for k, v in env.items():
        if "KEY" in k.upper() or "TOKEN" in k.upper():
            key = v
            break
# Resolve env var references
if key and key.startswith("$"):
    if key.startswith("${") and key.endswith("}"):
        var_name = key[2:-1]
    else:
        var_name = key[1:]
    key = os.environ.get(var_name, "")
print(key)
' 2>/dev/null)

if [ -z "$API_KEY" ]; then
  echo "{\"error\": \"No API key found for server '$SERVER' in mcp.json\"}" >&2
  exit 1
fi

# ---------- build JSON payload ----------
PAYLOAD=$(QUERY="$QUERY" VARIABLES="$VARIABLES" python3 -c "
import json, os
# Strip \! → ! (Bash tool escapes ! even in single quotes due to history expansion)
query = os.environ['QUERY'].replace(chr(92) + '!', '!')
payload = {'query': query}
variables = os.environ.get('VARIABLES', '')
if variables:
    payload['variables'] = json.loads(variables)
print(json.dumps(payload))
" 2>/dev/null)

# ---------- make the request ----------
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD"

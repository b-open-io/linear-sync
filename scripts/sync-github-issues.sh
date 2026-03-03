#!/usr/bin/env bash
# sync-github-issues.sh — Sync GitHub issues to/from Linear
# Usage: sync-github-issues.sh [repo-root]
#   repo-root: Path to the git repo root (default: current directory)
#
# Reads config from .claude/linear-sync.json in the repo root.
# Reads github_org from the config file or falls back to local state file.
# Creates Linear issues for unsynced GitHub issues.
# Closes GitHub issues when their linked Linear issue is completed/canceled.
set -euo pipefail

REPO_ROOT="${1:-.}"
CONFIG_FILE="$REPO_ROOT/.claude/linear-sync.json"
STATE_FILE="$HOME/.claude/linear-sync/state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_SCRIPT="$SCRIPT_DIR/linear-api.sh"

# ---------- read config ----------
if [ ! -f "$CONFIG_FILE" ]; then
  echo '{"error": "No .claude/linear-sync.json found in repo root"}'
  exit 1
fi

CONFIG=$(CONFIG_FILE="$CONFIG_FILE" python3 -c "
import json, os
with open(os.environ['CONFIG_FILE']) as f:
    cfg = json.load(f)
for key in ('workspace', 'project', 'team', 'label', 'github_org'):
    print(cfg.get(key, ''))
")

WORKSPACE=$(echo "$CONFIG" | sed -n '1p')
PROJECT=$(echo "$CONFIG" | sed -n '2p')
TEAM=$(echo "$CONFIG" | sed -n '3p')
LABEL=$(echo "$CONFIG" | sed -n '4p')
GITHUB_ORG=$(echo "$CONFIG" | sed -n '5p')
REPO_NAME=$(basename "$REPO_ROOT")

# Resolve MCP server name and github_org from state file
MCP_SERVER=""
if [ -f "$STATE_FILE" ] && [ -n "$WORKSPACE" ]; then
  RESOLVED=$(STATE_FILE="$STATE_FILE" WORKSPACE="$WORKSPACE" python3 -c "
import json, os
with open(os.environ['STATE_FILE']) as f:
    data = json.load(f)
ws = data.get('workspaces', {}).get(os.environ['WORKSPACE'], {})
print(ws.get('mcp_server', ''))
print(ws.get('github_org', ''))
" 2>/dev/null || echo "")
  MCP_SERVER=$(echo "$RESOLVED" | sed -n '1p')
  STATE_GITHUB_ORG=$(echo "$RESOLVED" | sed -n '2p')
  if [ -z "$GITHUB_ORG" ]; then
    GITHUB_ORG="$STATE_GITHUB_ORG"
  fi
fi

if [ -z "$MCP_SERVER" ]; then
  echo '{"error": "Could not resolve MCP server for workspace: '"$WORKSPACE"'"}'
  exit 1
fi

if [ -z "$GITHUB_ORG" ] || [ -z "$PROJECT" ] || [ -z "$TEAM" ] || [ -z "$LABEL" ]; then
  echo '{"error": "Missing required config: github_org, project, team, or label"}'
  exit 1
fi

FULL_REPO="$GITHUB_ORG/$REPO_NAME"

# ---------- Phase 1: Gather data (parallel) ----------

GH_TMP=$(mktemp)
LINEAR_TMP=$(mktemp)

# Fetch GitHub issues and Linear issues in parallel
gh issue list --repo "$FULL_REPO" --state open --json number,title,body,url --limit 500 >"$GH_TMP" 2>/dev/null &
PID_GH=$!

bash "$API_SCRIPT" "$MCP_SERVER" "query {
  issues(filter: {
    project: { name: { eq: \"$PROJECT\" } },
    labels: { some: { name: { eq: \"$LABEL\" } } }
  }, first: 250) {
    nodes { id identifier title description state { name type } }
  }
}" >"$LINEAR_TMP" &
PID_LINEAR=$!

wait "$PID_GH" || echo "[]" > "$GH_TMP"
wait "$PID_LINEAR"

GH_ISSUES=$(cat "$GH_TMP")
LINEAR_ISSUES=$(cat "$LINEAR_TMP")
rm -f "$GH_TMP" "$LINEAR_TMP"

[ -z "$GH_ISSUES" ] && GH_ISSUES="[]"
GH_COUNT=$(echo "$GH_ISSUES" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

# ---------- Phase 2: GitHub -> Linear (create missing) ----------

TEAM_ID=""
PROJECT_ID=""
LABEL_ID=""
CREATED=0

if [ "$GH_COUNT" != "0" ]; then
  UNSYNCED=$(GH_ISSUES="$GH_ISSUES" LINEAR_ISSUES="$LINEAR_ISSUES" FULL_REPO="$FULL_REPO" python3 -c "
import json, os, re

gh = json.loads(os.environ['GH_ISSUES'])
linear = json.loads(os.environ['LINEAR_ISSUES'])
full_repo = os.environ['FULL_REPO']

linear_nodes = linear.get('data', {}).get('issues', {}).get('nodes', [])

synced = set()
for li in linear_nodes:
    desc = li.get('description') or ''
    m = re.search(r'<!-- gh-sync:' + re.escape(full_repo) + r'#(\d+) -->', desc)
    if m:
        synced.add(int(m.group(1)))

unsynced = [i for i in gh if i['number'] not in synced]
print(json.dumps(unsynced))
")

  UNSYNCED_COUNT=$(echo "$UNSYNCED" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

  if [ "$UNSYNCED_COUNT" != "0" ]; then
    # Fetch team, project, and label IDs in parallel
    TEAM_TMP=$(mktemp); PROJECT_TMP=$(mktemp); LABEL_TMP=$(mktemp)

    bash "$API_SCRIPT" "$MCP_SERVER" "query { teams(filter: { key: { eq: \"$TEAM\" } }) { nodes { id } } }" >"$TEAM_TMP" &
    PID_TEAM=$!
    bash "$API_SCRIPT" "$MCP_SERVER" "query { projects(filter: { name: { eq: \"$PROJECT\" } }) { nodes { id } } }" >"$PROJECT_TMP" &
    PID_PROJECT=$!
    bash "$API_SCRIPT" "$MCP_SERVER" "query { issueLabels(filter: { name: { eq: \"$LABEL\" } }) { nodes { id } } }" >"$LABEL_TMP" &
    PID_LABEL=$!

    wait "$PID_TEAM" "$PID_PROJECT" "$PID_LABEL"

    TEAM_ID=$(python3 -c "import json; print(json.load(open('$TEAM_TMP'))['data']['teams']['nodes'][0]['id'])")
    PROJECT_ID=$(python3 -c "import json; print(json.load(open('$PROJECT_TMP'))['data']['projects']['nodes'][0]['id'])")
    LABEL_ID=$(python3 -c "
import json
nodes = json.load(open('$LABEL_TMP'))['data']['issueLabels']['nodes']
print(nodes[0]['id'] if nodes else '')
")
    rm -f "$TEAM_TMP" "$PROJECT_TMP" "$LABEL_TMP"

    if [ -z "$LABEL_ID" ]; then
      # Find or create "repo" group label on the team, then create child label under it
      REPO_GROUP_ID=$(bash "$API_SCRIPT" "$MCP_SERVER" "query { issueLabels(filter: { name: { eq: \"repo\" }, team: { id: { eq: \"$TEAM_ID\" } } }) { nodes { id isGroup } } }" | python3 -c "
import json, sys
nodes = json.load(sys.stdin)['data']['issueLabels']['nodes']
groups = [n for n in nodes if n.get('isGroup')]
print(groups[0]['id'] if groups else '')
")
      if [ -z "$REPO_GROUP_ID" ]; then
        REPO_GROUP_ID=$(bash "$API_SCRIPT" "$MCP_SERVER" "mutation { issueLabelCreate(input: { teamId: \"$TEAM_ID\", name: \"repo\", isGroup: true }) { issueLabel { id } } }" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['issueLabelCreate']['issueLabel']['id'])")
      fi
      LABEL_ID=$(bash "$API_SCRIPT" "$MCP_SERVER" "mutation { issueLabelCreate(input: { teamId: \"$TEAM_ID\", name: \"$LABEL\", parentId: \"$REPO_GROUP_ID\" }) { issueLabel { id } } }" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['issueLabelCreate']['issueLabel']['id'])")
    fi

    # Create Linear issues in parallel (up to 5 concurrent)
    MAX_CONCURRENT=5
    CREATED_DIR=$(mktemp -d)

    echo "$UNSYNCED" | python3 -c "
import json, sys
issues = json.load(sys.stdin)
for i in issues:
    print(json.dumps(i))
" | while IFS= read -r ISSUE_JSON; do
      (
        NUMBER=$(echo "$ISSUE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
        TITLE=$(echo "$ISSUE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
        BODY=$(echo "$ISSUE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('body') or '')")
        URL=$(echo "$ISSUE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")

        VARS=$(TEAM_ID="$TEAM_ID" PROJECT_ID="$PROJECT_ID" LABEL_ID="$LABEL_ID" \
               NUMBER="$NUMBER" TITLE="$TITLE" BODY="$BODY" URL="$URL" FULL_REPO="$FULL_REPO" \
               python3 -c "
import json, os
body = os.environ['BODY']
url = os.environ['URL']
full_repo = os.environ['FULL_REPO']
number = os.environ['NUMBER']

if body.strip():
    desc = body + '\n\n---\n[GitHub Issue](' + url + ')\n<!-- gh-sync:' + full_repo + '#' + number + ' -->'
else:
    desc = '---\n[GitHub Issue](' + url + ')\n<!-- gh-sync:' + full_repo + '#' + number + ' -->'

print(json.dumps({'input': {
    'teamId': os.environ['TEAM_ID'],
    'title': 'GH#' + number + ': ' + os.environ['TITLE'],
    'description': desc,
    'projectId': os.environ['PROJECT_ID'],
    'labelIds': [os.environ['LABEL_ID']]
}}))
")

        RESULT=$(bash "$API_SCRIPT" "$MCP_SERVER" \
          'mutation($input: IssueCreateInput!) { issueCreate(input: $input) { issue { identifier title } } }' \
          "$VARS" 2>&1)

        IDENTIFIER=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('issueCreate',{}).get('issue',{}).get('identifier','FAILED'))" 2>/dev/null || echo "FAILED")

        if [ "$IDENTIFIER" != "FAILED" ]; then
          touch "$CREATED_DIR/$NUMBER"
          echo "  Created $IDENTIFIER from GH#$NUMBER" >&2
        else
          echo "  Failed to create from GH#$NUMBER: $RESULT" >&2
        fi
      ) &

      # Throttle: wait if we have MAX_CONCURRENT background jobs
      while [ "$(jobs -rp | wc -l)" -ge "$MAX_CONCURRENT" ]; do
        wait -n 2>/dev/null || true
      done
    done

    # Wait for all remaining creation jobs
    wait

    CREATED=$(find "$CREATED_DIR" -type f | wc -l | tr -d ' ')
    rm -rf "$CREATED_DIR"
  fi
fi

# ---------- Phase 3: Linear -> GitHub (close resolved) ----------
CLOSED=0

CLOSABLE=$(LINEAR_ISSUES="$LINEAR_ISSUES" FULL_REPO="$FULL_REPO" python3 -c "
import json, os, re

linear = json.loads(os.environ['LINEAR_ISSUES'])
full_repo = os.environ['FULL_REPO']
nodes = linear.get('data', {}).get('issues', {}).get('nodes', [])

closable = []
for li in nodes:
    state_type = li.get('state', {}).get('type', '')
    if state_type not in ('completed', 'canceled'):
        continue
    desc = li.get('description') or ''
    m = re.search(r'<!-- gh-sync:' + re.escape(full_repo) + r'#(\d+) -->', desc)
    if m:
        closable.append({'number': int(m.group(1)), 'identifier': li['identifier']})

print(json.dumps(closable))
")

CLOSABLE_COUNT=$(echo "$CLOSABLE" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$CLOSABLE_COUNT" != "0" ]; then
  CLOSED_DIR=$(mktemp -d)

  echo "$CLOSABLE" | python3 -c "
import json, sys
for item in json.load(sys.stdin):
    print(json.dumps(item))
" | while IFS= read -r ITEM_JSON; do
    (
      NUMBER=$(echo "$ITEM_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
      IDENTIFIER=$(echo "$ITEM_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['identifier'])")

      GH_STATE=$(gh issue view "$NUMBER" --repo "$FULL_REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")

      if [ "$GH_STATE" = "OPEN" ]; then
        gh issue close "$NUMBER" --repo "$FULL_REPO" --comment "Closed via Linear ($IDENTIFIER)." 2>/dev/null && {
          touch "$CLOSED_DIR/$NUMBER"
          echo "  Closed GH#$NUMBER via $IDENTIFIER" >&2
        }
      fi
    ) &

    # Throttle: up to 5 concurrent close operations
    while [ "$(jobs -rp | wc -l)" -ge 5 ]; do
      wait -n 2>/dev/null || true
    done
  done

  wait

  CLOSED=$(find "$CLOSED_DIR" -type f | wc -l | tr -d ' ')
  rm -rf "$CLOSED_DIR"
fi

# ---------- Phase 4: Summary ----------
if [ "$CREATED" = "0" ] && [ "$CLOSED" = "0" ]; then
  echo "GitHub sync for $REPO_NAME: everything in sync."
else
  echo "GitHub sync for $REPO_NAME: created $CREATED Linear issues, closed $CLOSED GitHub issues."
fi

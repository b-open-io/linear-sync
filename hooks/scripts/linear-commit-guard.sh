#!/usr/bin/env bash
# linear-commit-guard.sh — PreToolUse hook for Linear Sync
# Enforces issue ID conventions on git commits, branch creation, and PR creation.
# Blocks non-compliant commands with exit 2 in linked repos.
# Event: PreToolUse (matcher: Bash)
# Timeout: 5s
set -euo pipefail

# ---------- helpers ----------
STATE_FILE="${STATE_FILE_OVERRIDE:-$HOME/.claude/linear-sync/state.json}"

has_issue_id() {
  printf '%s' "$1" | python3 -c "
import re, sys
text = sys.stdin.read()
if re.search(r'[A-Z]{2,5}-[0-9]+', text):
    sys.exit(0)
else:
    sys.exit(1)
" 2>/dev/null
}

# ---------- read stdin ----------
INPUT=$(cat)

COMMAND=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', d.get('toolInput', {}))
    print(ti.get('command', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ---------- auto-approve safe operations ----------
# Python-based check: auto-approve read-only git, safe non-git, and routine
# mutations in linked repos. Handles chained commands (&&/||/;/|) by validating
# each part independently. This runs BEFORE the issue-ID enforcement below.
AUTO_APPROVE_RESULT=$(COMMAND="$COMMAND" python3 -c "
import os, re, sys

cmd = os.environ['COMMAND'].strip()

# Commands that are ALWAYS safe (no repo check needed)
SAFE_GIT_READONLY = {
    'log', 'status', 'diff', 'show', 'rev-parse', 'remote', 'for-each-ref',
    'describe', 'reflog', 'shortlog', 'ls-files', 'cat-file', 'fetch',
}

# Branch listing flags (safe): bare 'branch', -v, -vv, -a, -r, --list, --show-current, --contains, --merged
BRANCH_LIST_FLAGS = {'-v', '-vv', '-a', '-r', '--list', '--show-current', '--contains', '--merged', '--no-merged', '--sort'}

# Destructive ops — never auto-approve
DESTRUCTIVE_PATTERNS = [
    r'\bgit\s+reset\s+--hard\b',
    r'\bgit\s+checkout\s+--\s',
    r'\bgit\s+clean\s+-[a-zA-Z]*f',
    r'\bgit\s+branch\s+-[a-zA-Z]*[dD]\b',
    r'\bgit\s+tag\s+-[a-zA-Z]*[dfa]\b',
]

def is_safe_universal(part):
    \"\"\"Check if a single command part is universally safe (no repo check needed).\"\"\"
    p = part.strip()
    if not p:
        return True

    # Safe non-git: ls, and read-only utilities (often piped together)
    if re.match(r'^(ls|sort|tail|head|wc|cat|basename|dirname|realpath|readlink|tr|cut|echo|printf|test|true)(\s|$)', p):
        return True

    # Safe non-git: find in .claude paths
    if re.match(r'^find\s', p):
        # Only safe if searching in .claude or linear-sync paths
        if re.search(r'\.claude|linear-sync|linear_sync', p):
            return True
        return False

    # Must be a git command for remaining checks
    m = re.match(r'^git\s+(\S+)', p)
    if not m:
        return False
    subcmd = m.group(1)

    # Check for destructive patterns first
    for pattern in DESTRUCTIVE_PATTERNS:
        if re.search(pattern, p):
            return False

    # Read-only git subcommands
    if subcmd in SAFE_GIT_READONLY:
        return True

    # git branch (listing only — no creation, no delete)
    if subcmd == 'branch':
        # Extract args after 'git branch'
        args_str = re.sub(r'^git\s+branch\s*', '', p).strip()
        if not args_str:
            return True  # bare 'git branch'
        # Split into tokens
        tokens = args_str.split()
        for tok in tokens:
            if tok.startswith('-'):
                # Check if it's a safe listing flag
                if tok in BRANCH_LIST_FLAGS:
                    continue
                # --sort=... is safe
                if tok.startswith('--sort='):
                    continue
                # -m/-M is NOT safe here (handled separately in repo check)
                return False
            # Non-flag argument after safe flags is OK (e.g., 'git branch -v main')
        return True

    # git tag (listing only)
    if subcmd == 'tag':
        args_str = re.sub(r'^git\s+tag\s*', '', p).strip()
        if not args_str:
            return True
        # tag -l/--list is safe
        tokens = args_str.split()
        for tok in tokens:
            if tok.startswith('-'):
                if tok in ('-l', '--list', '-n', '--sort'):
                    continue
                if tok.startswith('--sort=') or tok.startswith('-n'):
                    continue
                return False
        return True

    return False

def is_safe_linked_repo(part):
    \"\"\"Check if a single command part is safe in a linked repo (routine mutations).\"\"\"
    p = part.strip()
    if not p:
        return True

    m = re.match(r'^git\s+(\S+)', p)
    if not m:
        return False
    subcmd = m.group(1)

    # git add, git stash, git pull
    if subcmd in ('add', 'stash', 'pull'):
        return True

    return False

def is_branch_rename(part):
    \"\"\"Check if this is a git branch -m/-M rename.\"\"\"
    p = part.strip()
    return bool(re.search(r'\bgit\s+branch\s+-[mM]\b', p))

def get_branch_rename_target(part):
    \"\"\"Extract the new branch name from git branch -m/-M.\"\"\"
    p = part.strip()
    m = re.search(r'\bgit\s+branch\s+-[mM]\s+(?:\S+\s+)?(\S+)', p)
    return m.group(1) if m else ''

# Split chained commands
parts = re.split(r'\s*(?:&&|\|\||;|\|)\s*', cmd)

# Check if ANY part is destructive
for part in parts:
    for pattern in DESTRUCTIVE_PATTERNS:
        if re.search(pattern, part):
            print('PASS')  # let existing logic handle it
            sys.exit(0)

# Check if ALL parts are universally safe
all_universal = all(is_safe_universal(p) for p in parts)
if all_universal:
    print('APPROVE_UNIVERSAL')
    sys.exit(0)

# Check for branch rename (needs special handling)
has_rename = any(is_branch_rename(p) for p in parts)
if has_rename:
    # Extract target branch name and check for issue ID
    for p in parts:
        if is_branch_rename(p):
            target = get_branch_rename_target(p)
            if target and re.search(r'[A-Z]{2,5}-[0-9]+', target):
                print('APPROVE_RENAME')
            else:
                print('BLOCK_RENAME')
            sys.exit(0)

# Check if all parts are safe (universal OR linked-repo safe)
all_safe = all(is_safe_universal(p) or is_safe_linked_repo(p) for p in parts)
if all_safe:
    print('APPROVE_LINKED')
    sys.exit(0)

print('PASS')
" 2>/dev/null || echo "PASS")

case "$AUTO_APPROVE_RESULT" in
  APPROVE_UNIVERSAL)
    # Safe read-only operations — approve without repo check
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
    exit 0
    ;;
  APPROVE_RENAME|APPROVE_LINKED)
    # These need a linked repo — fall through to repo check, then approve
    ;;
  BLOCK_RENAME)
    # Branch rename without issue ID — need repo check first, then block
    ;;
  *)
    # PASS — fall through to existing CMD_TYPE logic
    ;;
esac

# For APPROVE_LINKED/APPROVE_RENAME/BLOCK_RENAME, we need the repo check.
# If the result is one of these, we'll handle it after the repo check below.

# ---------- determine command type ----------
CMD_TYPE=""
EXTRACTED=""

if GIT_CMD="$COMMAND" python3 -c '
import os, re
cmd = os.environ["GIT_CMD"]
DQ = chr(34)
SQ = chr(39)
if re.search(r"\bgit\s+commit\b", cmd) and (re.search(r"-[a-zA-Z]*m[\s" + DQ + SQ + "]", cmd) or re.search(r"-[a-zA-Z]*m$", cmd) or re.search(r"--message[\s=]", cmd)):
    exit(0)
exit(1)
' 2>/dev/null; then
  CMD_TYPE="commit"
  EXTRACTED=$(GIT_CMD="$COMMAND" python3 -c '
import os, re
cmd = os.environ["GIT_CMD"]
DQ = chr(34)
SQ = chr(39)
m = None
m = re.search("--message=" + DQ + r"((?:[^" + DQ + r"\\]|\\.)*)" + DQ, cmd)
if not m:
    m = re.search("--message=" + SQ + "([^" + SQ + "]*)" + SQ, cmd)
if not m:
    m = re.search(r"--message\s+" + DQ + r"((?:[^" + DQ + r"\\]|\\.)*)" + DQ, cmd)
if not m:
    m = re.search(r"--message\s+" + SQ + "([^" + SQ + "]*)" + SQ, cmd)
if not m:
    m = re.search(r"--message=(\S+)", cmd)
if not m:
    m = re.search(r"-[a-zA-Z]*m\s+" + DQ + r"((?:[^" + DQ + r"\\]|\\.)*)" + DQ, cmd)
if not m:
    m = re.search(r"-[a-zA-Z]*m\s+" + SQ + "([^" + SQ + "]*)" + SQ, cmd)
if not m:
    m = re.search(r"-[a-zA-Z]*m" + DQ + r"((?:[^" + DQ + r"\\]|\\.)*)" + DQ, cmd)
if not m:
    m = re.search(r"-[a-zA-Z]*m" + SQ + "([^" + SQ + "]*)" + SQ, cmd)
if not m:
    m = re.search(r"-[a-zA-Z]*m\s+(\S+)", cmd)
if not m:
    m = re.search(r"-[a-zA-Z]*m(\S+)", cmd)
if m:
    print(m.group(1))
else:
    print("")
' 2>/dev/null || echo "")

elif printf '%s' "$COMMAND" | python3 -c "
import sys, re
cmd = sys.stdin.read()
if re.search(r'\bgit\s+commit\b', cmd) and 'EOF' in cmd:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  CMD_TYPE="commit"
  EXTRACTED=$(printf '%s' "$COMMAND" | python3 -c "
import sys
cmd = sys.stdin.read()
print(cmd)
" 2>/dev/null || echo "$COMMAND")

elif GIT_CMD="$COMMAND" python3 -c '
import os, re
cmd = os.environ["GIT_CMD"]
DQ = chr(34)
SQ = chr(39)
if re.search(r"\bgit\s+commit\b", cmd):
    has_amend = bool(re.search(r"--amend\b", cmd))
    has_no_edit = bool(re.search(r"--no-edit\b", cmd))
    has_msg = bool(re.search(r"-[a-zA-Z]*m[\s" + DQ + SQ + "]", cmd)) or bool(re.search(r"--message[\s=]", cmd))
    if has_amend and has_no_edit and not has_msg:
        exit(0)
exit(1)
' 2>/dev/null; then
  CMD_TYPE="amend_no_edit"

elif GIT_CMD="$COMMAND" python3 -c '
import os, re
cmd = os.environ["GIT_CMD"]
DQ = chr(34)
SQ = chr(39)
if re.search(r"\bgit\s+commit\b", cmd):
    if not re.search(r"-[a-zA-Z]*m[\s" + DQ + SQ + "]", cmd) and not re.search(r"--message[\s=]", cmd) and "EOF" not in cmd:
        exit(0)
exit(1)
' 2>/dev/null; then
  CMD_TYPE="bare_commit"

elif printf '%s' "$COMMAND" | python3 -c "
import sys, re
cmd = sys.stdin.read()
if re.search(r'\bgit\s+checkout\s+-b\b', cmd):
    sys.exit(0)
if re.search(r'\bgit\s+switch\s+-c\b', cmd):
    sys.exit(0)
if re.search(r'\bgit\s+branch\s+(?!-)[^\s-]', cmd):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  CMD_TYPE="branch"
  EXTRACTED=$(printf '%s' "$COMMAND" | python3 -c "
import sys, re
cmd = sys.stdin.read().strip()
m = re.search(r'\bgit\s+checkout\s+-b\s+(\S+)', cmd)
if not m:
    m = re.search(r'\bgit\s+switch\s+-c\s+(\S+)', cmd)
if not m:
    m = re.search(r'\bgit\s+branch\s+([^\s-]\S*)', cmd)
if m:
    print(m.group(1))
else:
    print('')
" 2>/dev/null || echo "")

elif printf '%s' "$COMMAND" | python3 -c "
import sys, re
cmd = sys.stdin.read()
if re.search(r'\bgh\s+pr\s+create\b', cmd):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  CMD_TYPE="pr"
  EXTRACTED=$(GIT_CMD="$COMMAND" python3 -c '
import os, re
cmd = os.environ["GIT_CMD"]
DQ = chr(34)
SQ = chr(39)
m = None
m = re.search("--title=" + DQ + r"((?:[^" + DQ + r"\\]|\\.)*)" + DQ, cmd)
if not m:
    m = re.search("--title=" + SQ + "([^" + SQ + "]*)" + SQ, cmd)
if not m:
    m = re.search(r"--title\s+" + DQ + r"((?:[^" + DQ + r"\\]|\\.)*)" + DQ, cmd)
if not m:
    m = re.search(r"--title\s+" + SQ + "([^" + SQ + "]*)" + SQ, cmd)
if not m:
    m = re.search(r"--title=(\S+)", cmd)
if not m:
    m = re.search("-t=" + DQ + r"((?:[^" + DQ + r"\\]|\\.)*)" + DQ, cmd)
if not m:
    m = re.search("-t=" + SQ + "([^" + SQ + "]*)" + SQ, cmd)
if not m:
    m = re.search(r"-t\s+" + DQ + r"((?:[^" + DQ + r"\\]|\\.)*)" + DQ, cmd)
if not m:
    m = re.search(r"-t\s+" + SQ + "([^" + SQ + "]*)" + SQ, cmd)
if not m:
    m = re.search(r"-t=(\S+)", cmd)
if m:
    print(m.group(1))
else:
    print("")
' 2>/dev/null || echo "")

elif printf '%s' "$COMMAND" | python3 -c "
import sys, re
cmd = sys.stdin.read()
if re.search(r'\bgit\s+push\b', cmd):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  CMD_TYPE="push"
fi

if [ -z "$CMD_TYPE" ]; then
  # If auto-approve needs a repo check, don't exit yet — fall through
  case "$AUTO_APPROVE_RESULT" in
    APPROVE_LINKED|APPROVE_RENAME|BLOCK_RENAME)
      ;;
    *)
      exit 0
      ;;
  esac
fi

# ---------- check repo status ----------
CWD=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('cwd', d.get('sessionState', {}).get('cwd', '')))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [ -z "$CWD" ]; then
  exit 0
fi

GIT_TOP=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$GIT_TOP" ]; then
  exit 0
fi

REPO_NAME=$(basename "$GIT_TOP" 2>/dev/null || echo "")
if [ -z "$REPO_NAME" ]; then
  exit 0
fi

REPO_CONFIG_FILE="$GIT_TOP/.claude/linear-sync.json"

if [ ! -f "$STATE_FILE" ] && [ ! -f "$REPO_CONFIG_FILE" ]; then
  exit 0
fi
REPO_INFO=$(REPO_CONFIG_FILE="$REPO_CONFIG_FILE" STATE_FILE="$STATE_FILE" REPO_NAME="$REPO_NAME" python3 -c "
import json, os

repo_cfg_path = os.environ['REPO_CONFIG_FILE']
state_path = os.environ['STATE_FILE']
repo_name = os.environ['REPO_NAME']

try:
    with open(state_path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    data = {}

try:
    with open(repo_cfg_path) as f:
        repo_cfg = json.load(f)
    team = repo_cfg.get('team', '')
    ws_id = repo_cfg.get('workspace', '')
    if team and ws_id:
        ws = data.get('workspaces', {}).get(ws_id, None)
        if ws:
            print('LINKED:' + team)
        else:
            print('UNLINKED')
    elif team:
        print('LINKED:' + team)
    else:
        raise FileNotFoundError('no team in repo config')
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    repo = data.get('repos', {}).get(repo_name, None)
    if repo is None:
        print('UNLINKED')
    elif repo.get('workspace') == 'none':
        print('OPTED_OUT')
    else:
        ws_id = repo.get('workspace', '')
        ws = data.get('workspaces', {}).get(ws_id, None)
        if ws:
            team = repo.get('team', ws.get('default_team', 'XXX'))
            print('LINKED:' + team)
        else:
            print('UNLINKED')
" 2>/dev/null || echo "UNLINKED")

case "$REPO_INFO" in
  UNLINKED|OPTED_OUT)
    exit 0
    ;;
esac

TEAM_PREFIX="${REPO_INFO#LINKED:}"

# ---------- handle auto-approved operations that needed repo check ----------
case "$AUTO_APPROVE_RESULT" in
  APPROVE_LINKED|APPROVE_RENAME)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
    exit 0
    ;;
  BLOCK_RENAME)
    echo "BLOCKED: Branch rename must include an issue ID in the new name (e.g. ${TEAM_PREFIX}-123-my-feature)." >&2
    echo "Tip: Ask Claude to create a Linear ticket if you don't have one yet." >&2
    exit 2
    ;;
esac

# ---------- allow --amend --no-edit ----------
if [ "$CMD_TYPE" = "amend_no_edit" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
fi

# ---------- block bare commits ----------
if [ "$CMD_TYPE" = "bare_commit" ]; then
  echo "BLOCKED: Commits must include an issue ID via the -m flag." >&2
  echo "Editor-based commits (without -m or --message) cannot be verified by the hook." >&2
  echo "Use: git commit -m \"${TEAM_PREFIX}-123: your message\"" >&2
  echo "Tip: Ask Claude to create a Linear ticket if you don't have one yet." >&2
  exit 2
fi

# ---------- cross-issue commit validation on push ----------
if [ "$CMD_TYPE" = "push" ]; then
  CROSS_ISSUE=$(cd "$GIT_TOP" 2>/dev/null && python3 -c "
import subprocess, re
candidates = []
sym = subprocess.run(['git', 'symbolic-ref', 'refs/remotes/origin/HEAD'], capture_output=True, text=True)
if sym.returncode == 0 and sym.stdout.strip():
    candidates.append(sym.stdout.strip().replace('refs/remotes/origin/', ''))
candidates.extend(['main', 'master'])
for base in candidates:
    result = subprocess.run(['git', 'merge-base', base, 'HEAD'], capture_output=True, text=True)
    if result.returncode == 0:
        merge_base = result.stdout.strip()
        break
else:
    print('')
    exit()

log = subprocess.run(['git', 'log', '--oneline', f'{merge_base}..HEAD'], capture_output=True, text=True)
if log.returncode != 0 or not log.stdout.strip():
    print('')
    exit()

ids = set()
for line in log.stdout.strip().split('\n'):
    for m in re.findall(r'[A-Z]{2,5}-[0-9]+', line):
        ids.add(m)

if len(ids) > 1:
    print(', '.join(sorted(ids)))
else:
    print('')
" 2>/dev/null || echo "")

  if [ -n "$CROSS_ISSUE" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"[CROSS-ISSUE-COMMITS] This branch has commits referencing multiple issues: %s. This is usually fine for related work, but consider splitting into separate branches if the work is unrelated.","permissionDecision":"allow"}}\n' "$CROSS_ISSUE"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  fi
  exit 0
fi

# ---------- check for issue ID ----------

if [ "$CMD_TYPE" = "pr" ] && [ -z "$EXTRACTED" ]; then
  BRANCH=$(cd "$GIT_TOP" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if has_issue_id "$BRANCH"; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
    exit 0
  fi
  echo "BLOCKED: PR title must contain an issue ID (e.g. ${TEAM_PREFIX}-123)." >&2
  echo "Either provide --title with an issue ID, or rename your branch to include one." >&2
  echo "Tip: Ask Claude to create a Linear ticket if you don't have one yet." >&2
  exit 2
fi

CHECK_STRING="$EXTRACTED"

if [ "$CMD_TYPE" = "commit" ] && [ -z "$EXTRACTED" ]; then
  CHECK_STRING="$COMMAND"
fi

if [ -n "$CHECK_STRING" ] && has_issue_id "$CHECK_STRING"; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
fi

# ---------- block ----------
case "$CMD_TYPE" in
  bare_commit)
    echo "BLOCKED: Commits must include an issue ID via the -m flag." >&2
    echo "Use: git commit -m \"${TEAM_PREFIX}-123: your message\"" >&2
    ;;
  commit)
    echo "BLOCKED: Commit message must contain an issue ID (e.g. ${TEAM_PREFIX}-123: your message)." >&2
    echo "Expected format: \"${TEAM_PREFIX}-<number>: description\"" >&2
    echo "Tip: Ask Claude to create a Linear ticket if you don't have one yet." >&2
    ;;
  branch)
    echo "BLOCKED: Branch name must contain an issue ID (e.g. ${TEAM_PREFIX}-123-my-feature)." >&2
    echo "Expected format: ${TEAM_PREFIX}-<number>-slug" >&2
    echo "Tip: Ask Claude to create a Linear ticket if you don't have one yet." >&2
    ;;
  pr)
    echo "BLOCKED: PR title must contain an issue ID (e.g. ${TEAM_PREFIX}-123: your title)." >&2
    echo "Expected format: \"${TEAM_PREFIX}-<number>: description\"" >&2
    echo "Tip: Ask Claude to create a Linear ticket if you don't have one yet." >&2
    ;;
esac

exit 2

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

# ---------- parse actual invocations (command position + argv) ----------
# The guard used to substring-match trigger patterns (e.g. 'git branch -M')
# anywhere in the command string, which false-positived on non-git commands
# whose ARGUMENTS merely contained git-looking text (e.g. a curl JSON payload).
# Parse the command into simple commands (shlex, quote-aware, split on
# &&/||/;/|/newlines, leading env assignments stripped) and only classify
# git/gh invocations that are actually in command position.
# When parsing is ambiguous, err toward ALLOWING with a warning.
PARSED=$(COMMAND="$COMMAND" python3 -c '
import os, re, sys
import shlex

cmd = os.environ.get("COMMAND", "")
# Shell line continuations are just whitespace.
cmd = cmd.replace("\\\n", " ")

def newlines_to_semicolons(s):
    # Replace newlines that are OUTSIDE quotes with ";" so shlex splits
    # multi-line commands into separate simple commands. Newlines inside
    # quotes (heredoc-in-command-substitution, JSON payloads) are preserved.
    out = []
    q = None
    esc = False
    for ch in s:
        if esc:
            out.append(ch)
            esc = False
            continue
        if q is None:
            if ch == "\\":
                out.append(ch)
                esc = True
            elif ch == chr(39) or ch == chr(34):
                q = ch
                out.append(ch)
            elif ch == "\n":
                out.append(";")
            else:
                out.append(ch)
        elif q == chr(34):
            if ch == "\\":
                out.append(ch)
                esc = True
            else:
                if ch == chr(34):
                    q = None
                out.append(ch)
        else:
            if ch == chr(39):
                q = None
            out.append(ch)
    return "".join(out)

def emit_ambiguous():
    print("STATUS=AMBIGUOUS")
    sys.exit(0)

try:
    prepared = newlines_to_semicolons(cmd)
    lex = shlex.shlex(prepared, posix=True, punctuation_chars="();<>|&;")
    lex.whitespace_split = True
    tokens = list(lex)
except ValueError:
    emit_ambiguous()
except Exception:
    emit_ambiguous()

PUNCT = set("();<>|&;")
segments = []
current = []
for tok in tokens:
    if tok and all(c in PUNCT for c in tok):
        if current:
            segments.append(current)
            current = []
    else:
        current.append(tok)
if current:
    segments.append(current)

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
GIT_OPT_WITH_ARG = {"-C", "-c", "--exec-path", "--git-dir", "--work-tree", "--namespace", "--super-prefix"}

def strip_prefix(words):
    i = 0
    while i < len(words) and ASSIGN.match(words[i]):
        i += 1
    while i < len(words) and words[i] in ("command", "builtin", "nohup", "exec", "time", "do", "then", "else"):
        i += 1
        while i < len(words) and words[i].startswith("-"):
            i += 1
    if i < len(words) and words[i] == "env":
        i += 1
        while i < len(words) and (ASSIGN.match(words[i]) or words[i].startswith("-")):
            i += 1
    return words[i:]

def short_flag_has(flag, chars):
    if not flag.startswith("-") or flag.startswith("--"):
        return False
    return any(c in flag[1:] for c in chars)

out = {
    "HAS_COMMIT": 0,
    "HAS_PUSH": 0,
    "HAS_RENAME": 0,
    "RENAME_TARGET": "",
    "HAS_BRANCH_CREATE": 0,
    "BRANCH_NAME": "",
    "HAS_PR_CREATE": 0,
}

def classify(words):
    words = strip_prefix(words)
    if not words:
        return
    prog = words[0].rsplit("/", 1)[-1]
    args = words[1:]
    if prog == "gh":
        if len(args) >= 2 and args[0] == "pr" and args[1] == "create":
            out["HAS_PR_CREATE"] = 1
        return
    if prog != "git":
        return
    # Skip git global options to find the subcommand.
    i = 0
    sub = ""
    rest = []
    while i < len(args):
        a = args[i]
        if a in GIT_OPT_WITH_ARG:
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        sub = a
        rest = args[i + 1:]
        break
    if not sub:
        return
    if sub == "commit":
        out["HAS_COMMIT"] = 1
    elif sub == "push":
        out["HAS_PUSH"] = 1
    elif sub == "checkout":
        for j, a in enumerate(rest):
            if a in ("-b", "-B") or short_flag_has(a, "bB"):
                if j + 1 < len(rest):
                    out["HAS_BRANCH_CREATE"] = 1
                    out["BRANCH_NAME"] = rest[j + 1]
                break
    elif sub == "switch":
        for j, a in enumerate(rest):
            if a in ("-c", "-C", "--create", "--force-create") or short_flag_has(a, "cC"):
                if j + 1 < len(rest):
                    out["HAS_BRANCH_CREATE"] = 1
                    out["BRANCH_NAME"] = rest[j + 1]
                break
    elif sub == "branch":
        flags = [a for a in rest if a.startswith("-")]
        positionals = [a for a in rest if not a.startswith("-")]
        is_rename = any(f == "--move" or short_flag_has(f, "mM") for f in flags)
        is_delete = any(f == "--delete" or short_flag_has(f, "dD") for f in flags)
        if is_rename and not is_delete:
            if positionals:
                out["HAS_RENAME"] = 1
                out["RENAME_TARGET"] = positionals[-1]
        elif not is_delete and positionals and not flags:
            out["HAS_BRANCH_CREATE"] = 1
            out["BRANCH_NAME"] = positionals[0]

for seg in segments:
    classify(seg)

print("STATUS=OK")
for k, v in out.items():
    print(k + "=" + str(v).replace(chr(10), " "))
' 2>/dev/null || echo "STATUS=AMBIGUOUS")

parse_get() {
  printf '%s\n' "$PARSED" | sed -n "s/^$1=//p"
}

PARSE_STATUS=$(parse_get STATUS)
if [ "$PARSE_STATUS" != "OK" ]; then
  echo "linear-commit-guard: could not parse command; skipping guard checks (allowing)" >&2
  exit 0
fi
HAS_COMMIT=$(parse_get HAS_COMMIT)
HAS_PUSH=$(parse_get HAS_PUSH)
HAS_RENAME=$(parse_get HAS_RENAME)
RENAME_TARGET=$(parse_get RENAME_TARGET)
HAS_BRANCH_CREATE=$(parse_get HAS_BRANCH_CREATE)
BRANCH_NAME=$(parse_get BRANCH_NAME)
HAS_PR_CREATE=$(parse_get HAS_PR_CREATE)

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

# Check if all parts are safe (universal OR linked-repo safe)
all_safe = all(is_safe_universal(p) or is_safe_linked_repo(p) for p in parts)
if all_safe:
    print('APPROVE_LINKED')
    sys.exit(0)

print('PASS')
" 2>/dev/null || echo "PASS")

# ---------- branch rename handling (parsed, argv-aware) ----------
# Driven by the invocation parser above, NOT substring matching, so text like
# "git branch -M x" inside a non-git command argument never triggers this.
# Renaming TO a default branch name (master/main) is repo wiring during new
# repo setup, not a feature branch — exempt from the issue-ID rule.
if [ "$HAS_RENAME" = "1" ]; then
  if [ "$RENAME_TARGET" = "master" ] || [ "$RENAME_TARGET" = "main" ]; then
    AUTO_APPROVE_RESULT="APPROVE_RENAME"
  elif [ -n "$RENAME_TARGET" ] && has_issue_id "$RENAME_TARGET"; then
    AUTO_APPROVE_RESULT="APPROVE_RENAME"
  else
    AUTO_APPROVE_RESULT="BLOCK_RENAME"
  fi
fi

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
# Each branch is gated on the argv-aware parser (HAS_* vars) so the regex
# extraction below only runs when the command truly invokes git/gh with the
# relevant subcommand in command position.
CMD_TYPE=""
EXTRACTED=""

if [ "$HAS_COMMIT" = "1" ] && GIT_CMD="$COMMAND" python3 -c '
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

elif [ "$HAS_COMMIT" = "1" ] && printf '%s' "$COMMAND" | python3 -c "
import sys, re
cmd = sys.stdin.read()
if 'EOF' in cmd:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  CMD_TYPE="commit"
  EXTRACTED=$(printf '%s' "$COMMAND" | python3 -c "
import sys
cmd = sys.stdin.read()
print(cmd)
" 2>/dev/null || echo "$COMMAND")

elif [ "$HAS_COMMIT" = "1" ] && GIT_CMD="$COMMAND" python3 -c '
import os, re
cmd = os.environ["GIT_CMD"]
DQ = chr(34)
SQ = chr(39)
has_amend = bool(re.search(r"--amend\b", cmd))
has_no_edit = bool(re.search(r"--no-edit\b", cmd))
has_msg = bool(re.search(r"-[a-zA-Z]*m[\s" + DQ + SQ + "]", cmd)) or bool(re.search(r"--message[\s=]", cmd))
if has_amend and has_no_edit and not has_msg:
    exit(0)
exit(1)
' 2>/dev/null; then
  CMD_TYPE="amend_no_edit"

elif [ "$HAS_COMMIT" = "1" ] && GIT_CMD="$COMMAND" python3 -c '
import os, re
cmd = os.environ["GIT_CMD"]
DQ = chr(34)
SQ = chr(39)
if not re.search(r"-[a-zA-Z]*m[\s" + DQ + SQ + "]", cmd) and not re.search(r"--message[\s=]", cmd) and "EOF" not in cmd:
    exit(0)
exit(1)
' 2>/dev/null; then
  CMD_TYPE="bare_commit"

elif [ "$HAS_COMMIT" = "1" ]; then
  # git commit invoked but message style unrecognized — treat as commit and
  # let the issue-ID check run against the full command string.
  CMD_TYPE="commit"

elif [ "$HAS_BRANCH_CREATE" = "1" ]; then
  CMD_TYPE="branch"
  EXTRACTED="$BRANCH_NAME"

elif [ "$HAS_PR_CREATE" = "1" ]; then
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

elif [ "$HAS_PUSH" = "1" ]; then
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

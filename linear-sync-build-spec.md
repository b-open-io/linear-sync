# Linear-Sync: Build Specification for Claude Code

You are building a complete system called **linear-sync** that automatically keeps Linear and GitHub in sync for developers using Claude Code. The system must work across multiple orgs/companies (each with their own Linear workspace and GitHub org), handle repos that don't use Linear at all, and do all of this without eating the main Claude Code context window.

Read this entire spec before writing any code.

---

## Overview

The system has 5 components:

1. **4 bash hook scripts** — fire automatically at Claude Code lifecycle events
2. **1 subagent definition** — a background Haiku agent that handles all Linear API calls
3. **1 JSON state file** — persists repo↔workspace↔project mappings across sessions
4. **1 settings.json** — registers the hooks with Claude Code
5. **1 CLAUDE.md snippet** — global instructions appended to `~/.claude/CLAUDE.md`
6. **1 install.sh** — one-command installer

All files install under `~/.claude/`. The installer is idempotent (safe to run multiple times).

---

## File Structure

```
~/.claude/
├── agents/
│   └── linear-sync.md
├── hooks/
│   ├── linear-session-start.sh
│   ├── linear-prompt-check.sh
│   ├── linear-commit-guard.sh
│   └── linear-post-push.sh
├── scripts/
│   └── linear-repo-links.json
├── settings.json
└── CLAUDE.md  (appended to, not overwritten)
```

Build all files in a `linear-sync/` directory with the same structure, plus `install.sh` and `CLAUDE-snippet.md` at the root. The installer copies files into `~/.claude/`.

---

## Component 1: State File (`scripts/linear-repo-links.json`)

This is the single source of truth. Initial state is empty:

```json
{
  "workspaces": {},
  "repos": {},
  "github_org_defaults": {}
}
```

After setup it looks like:

```json
{
  "workspaces": {
    "opl": {
      "name": "OPL",
      "linear_api_key_env": "LINEAR_API_KEY_OPL",
      "github_org": "opl-org",
      "default_team": "ENG"
    },
    "crystal-peak": {
      "name": "Crystal Peak",
      "linear_api_key_env": "LINEAR_API_KEY_CRYSTALPEAK",
      "github_org": "crystal-peak",
      "default_team": "CP"
    }
  },
  "repos": {
    "opl-api": {
      "workspace": "opl",
      "project": "Project Atlas",
      "team": "ENG",
      "label": "repo:api"
    },
    "my-blog": {
      "workspace": "none"
    }
  },
  "github_org_defaults": {
    "opl-org": "opl",
    "crystal-peak": "crystal-peak"
  }
}
```

Key rules:

- `"workspace": "none"` means explicitly opted out. All hooks must go silent for this repo.
- `github_org_defaults` maps GitHub org names to workspace IDs for auto-detection of new repos.
- The subagent is the only thing that writes to this file.

---

## Component 2: SessionStart Hook (`hooks/linear-session-start.sh`)

**Event:** `SessionStart` (matcher: `startup|clear|compact`)
**Timeout:** 10 seconds
**Purpose:** Detect repo status and inject minimal context or trigger setup wizard.

### Logic:

1. Read JSON input from stdin. Extract `cwd`.
2. If not a git repo (`$CWD/.git` doesn't exist), `exit 0` silently.
3. Get repo name from `git rev-parse --show-toplevel`, fallback to `basename $CWD`.
4. Get GitHub org by parsing `git remote get-url origin` for `github.com[:/]ORG/`.
5. Read `linear-repo-links.json`.
6. Look up the repo:

**If repo is in the file with a valid workspace → LINKED:**

- Inject context via `additionalContext` that includes two parts:
  1. **Config context** (~1 line): repo name, workspace, project, team, label, branch format, commit format.
  2. **Session kickoff directive**: Tell Claude to ask the dev what they're working on this session using AskUserQuestion with these options:
     - "Work on an existing issue" → Claude should then ask for the issue ID or offer to search
     - "Start something new" → Claude should ask for a one-line description, then delegate to linear-sync subagent (background) to create a ticket in the correct project with the repo label, and return the new issue ID. Claude then proceeds with that issue.
     - "Just exploring / no ticket needed" → Claude proceeds normally with no enforcement. The commit guard hook will still catch untagged commits later if the dev starts making changes, at which point Claude can offer to create a ticket then.

  The kickoff question should be brief and non-blocking — something like: `"What are you working on today in <repo>?"` It should feel like a natural start to the session, not a form to fill out.

**If repo is in the file with `"workspace": "none"` → OPTED OUT:**

- `exit 0`. Total silence. Zero output.

**If repo is NOT in the file → SETUP REQUIRED:**

- Determine which setup scenario applies:
  - **Has workspaces configured AND GitHub org matches a known workspace**: Inject `[LINEAR-SETUP]` directive telling Claude to use AskUserQuestion to confirm the workspace match, then use the linear-sync subagent (foreground) to fetch projects/teams from Linear MCP, present them as AskUserQuestion choices, ask for a label (suggest `repo:<repo-name>`), and persist.
  - **Has workspaces configured BUT no org match**: Inject `[LINEAR-SETUP]` directive telling Claude to use AskUserQuestion to pick from known workspaces + "Set up new" + "No Linear". Also ask if this GitHub org should default to the chosen workspace.
  - **No workspaces configured at all (first-time)**: Inject `[LINEAR-SETUP]` directive telling Claude to use AskUserQuestion "Does this repo connect to Linear? Yes / No". If yes, use the linear-sync subagent (foreground) to discover workspaces/teams/projects from Linear MCP and walk through full setup via AskUserQuestion.
- In ALL setup scenarios, "This repo doesn't use Linear" must be an option. If chosen, the subagent writes `"workspace": "none"` and Claude confirms and moves on.
- After setup, Claude confirms in one line and proceeds with whatever the dev originally asked.

**If repo references a broken workspace** (ID not in workspaces):

- Inject `[LINEAR-SETUP]` directive asking dev to reconfigure or opt out.

### Output format:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<escaped context string>"
  }
}
```

Newlines and special chars in the context must be JSON-escaped (use python3 `json.dumps`).

---

## Component 3: UserPromptSubmit Hook (`hooks/linear-prompt-check.sh`)

**Event:** `UserPromptSubmit`
**Timeout:** 5 seconds
**Purpose:** Detect issue ID references (like ENG-123) in the dev's prompt and inject a hint to fetch context.

### Logic:

1. Read JSON input. Extract `cwd` and `prompt_content`.
2. Check repo status in `linear-repo-links.json`. If not linked or opted out, `exit 0`.
3. Scan prompt text for pattern `[A-Z]{2,5}-[0-9]+` (up to 3 matches).
4. If found, inject via `additionalContext`: `[Linear/<workspace>] Issue(s) referenced: ENG-123, ENG-456. Delegate to linear-sync subagent (background) to fetch summaries.`
5. If no matches, `exit 0`.

---

## Component 4: PreToolUse Hook (`hooks/linear-commit-guard.sh`)

**Event:** `PreToolUse` (matcher: `Bash`)
**Timeout:** 5 seconds
**Purpose:** Enforce issue ID conventions on git commits, branch creation, and PR creation. Only in linked repos.

### Logic:

1. Read JSON input. Extract `tool_input.command`.
2. Determine which command type:
   - `git commit` → extract message from `-m "..."` flag
   - `git checkout -b` / `git switch -c` / `git branch` → extract branch name
   - `gh pr create` → extract title from `--title "..."` or `-t "..."` flag
   - Anything else → `exit 0`
3. Check repo status. If not linked or opted out, `exit 0`.
4. Check if the extracted string contains `[A-Z]{2,5}-[0-9]+`.
5. If yes → return `permissionDecision: "allow"`.
6. If no → print helpful error to stderr with the team prefix and expected format, then `exit 2` to block.

The error message should suggest the correct format and tell the dev to ask Claude to create a ticket. When Claude sees a blocked commit, it should proactively offer to create a Linear ticket right then — ask for a one-line description via AskUserQuestion, delegate to the subagent to create it, then retry the commit with the new issue ID. This way, a dev who picked "Just exploring" at session start and then decides to commit is smoothly guided into creating a ticket without friction.

For `gh pr create` without an explicit `--title`, check the current branch name instead. If the branch has the issue ID, allow (the PR will inherit it).

---

## Component 5: PostToolUse Hook (`hooks/linear-post-push.sh`)

**Event:** `PostToolUse` (matcher: `Bash`)
**Timeout:** 10 seconds
**Purpose:** After a successful `git push`, trigger a background subagent to post a progress comment on the Linear issue.

### Logic:

1. Read JSON input. Check if command is `git push`.
2. Check repo status. If not linked or opted out, `exit 0`.
3. Check `tool_output` for error indicators. If push failed, `exit 0`.
4. Extract issue ID from current branch name.
5. If no issue ID in branch, `exit 0`.
6. Gather recent commits (`git log --oneline -5`) and files changed.
7. Inject via `additionalContext`: `[Linear/<workspace>] Push for ENG-123. Delegate to linear-sync subagent (background): Post progress comment.` Include commit and file summaries.

---

## Component 6: Subagent (`agents/linear-sync.md`)

**Model:** claude-haiku-4-5
**Tools:** mcp\_\_linear, Bash, Read, Write
**Permission mode:** default

This is the YAML-frontmatter markdown file that defines a Claude Code subagent. It runs in the background for ongoing work and foreground during one-time setup.

### Responsibilities:

1. **Fetch data from Linear MCP** — workspaces, teams, projects, labels, issues
2. **Persist state** — write to `~/.claude/scripts/linear-repo-links.json`
3. **Auto-provision labels** — before applying a label, check if it exists in Linear. If not, create it via MCP.
4. **Post comments** on issues with progress summaries
5. **Create issues** with auto-applied repo labels
6. **Return concise summaries** — the main agent only needs actionable one-liners, not raw API data

### Key tasks to document in the agent:

- **Link Repo to Project** (setup wizard): fetch projects/teams from MCP, return to main agent for AskUserQuestion presentation, after dev picks, verify/create label in Linear, persist to JSON.
- **Set Up New Workspace**: discover workspaces via MCP, persist config + org defaults.
- **Opt Repo Out**: write `"workspace": "none"` to JSON.
- **Fetch Issue Summary**: get title, state, assignee, labels, criteria. Return in ~3 lines.
- **Post Comment on Issue**: summarize changes in 2-3 bullets, post via MCP.
- **Create Issue**: create in correct workspace/team/project, auto-apply + auto-create repo label.
- **Verify/Create Label**: search for label in workspace, create if missing.

### Multi-workspace MCP:

For devs with multiple Linear workspaces, `~/.claude/mcp.json` needs one server entry per workspace (each with its own API key). The subagent should use the server matching the target workspace.

---

## Component 7: Settings (`settings.json`)

Register all four hooks:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/linear-session-start.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/linear-prompt-check.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/linear-commit-guard.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/linear-post-push.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

---

## Component 8: CLAUDE.md Snippet (`CLAUDE-snippet.md`)

Global instructions to append to `~/.claude/CLAUDE.md`. Must cover:

- **Session start behavior**: linked → session kickoff prompt, opted out → silent, not registered → run setup wizard.
- **Session kickoff (linked repos)**: At the start of every session in a linked repo, use AskUserQuestion to ask the dev what they're working on: "Work on an existing issue" / "Start something new" / "Just exploring". If "Start something new", ask for a one-line description and auto-create a Linear ticket via the subagent (with correct project + repo label). If "existing issue", ask for the ID or search. If "exploring", proceed normally — the commit guard will catch untagged commits later and offer to create a ticket at that point.
- **Setup wizard rules**: always use AskUserQuestion for choices, use linear-sync subagent (foreground) to fetch real data from Linear MCP, always offer "no Linear" option, persist to JSON, ask about org defaults, confirm in one line.
- **Enforcement table** (linked repos only):
  - `git commit` → issue ID required in message (hook blocks)
  - `git checkout -b` → issue ID required in branch name (hook blocks)
  - `gh pr create` → issue ID required in PR title (hook blocks)
  - Issue creation → repo label auto-applied + auto-created if missing
  - Push → background comment posted on issue
- **Unlinked/opted-out repos**: none of the above applies.
- **Blocked commit recovery**: When a commit is blocked by the hook for missing an issue ID, proactively offer to create a Linear ticket. Use AskUserQuestion to ask for a one-line description, delegate to the subagent to create the ticket (correct project + label), then retry the commit with the new issue ID. Don't make the dev start over.
- **Context conservation**: never call Linear MCP directly from main context. Always delegate to linear-sync subagent.

---

## Component 9: Installer (`install.sh`)

Bash script. Idempotent. Does:

1. Create directories: `~/.claude/{agents,hooks,scripts}`
2. Copy `agents/linear-sync.md` to `~/.claude/agents/`
3. Copy all 4 hook scripts to `~/.claude/hooks/`, `chmod +x` each
4. Initialize `scripts/linear-repo-links.json` ONLY if it doesn't exist (preserve existing config)
5. Handle `settings.json`:
   - If `~/.claude/settings.json` doesn't exist: copy ours
   - If it exists and already has our hooks (check for `linear-session-start`): skip
   - If it exists without our hooks: print instructions to merge manually
6. Handle `CLAUDE.md`:
   - If `~/.claude/CLAUDE.md` doesn't exist: copy our snippet as the file
   - If it exists and already has `Linear Sync (Auto-Managed)`: skip
   - If it exists without our section: append our snippet
7. Print success message with next steps (configure Linear API key in `~/.claude/mcp.json`, then open Claude Code in any repo)

---

## Design Principles (enforce these throughout)

1. **Every hook must check repo status early and bail with `exit 0` if the repo is not linked.** Opted-out and unlinked repos must have zero output, zero context cost.
2. **All hooks use `set -euo pipefail`.** All external calls (python3, git) must have `2>/dev/null || echo ""` fallbacks so hooks never crash.
3. **The main context window is sacred.** Hooks inject via `additionalContext` (tiny strings). The subagent runs in background for ongoing work. The only foreground subagent usage is during one-time setup.
4. **AskUserQuestion is the UI for setup.** The dev never types workspace names, project IDs, or labels manually. Everything is clickable choices populated from real Linear data.
5. **Labels are auto-provisioned.** The subagent always verifies a label exists in Linear before applying it, and creates it if missing. Zero Linear preconfiguration required.
6. **Conventions are mechanically enforced.** Commits, branches, and PRs are blocked by hooks (exit 2) if they lack issue IDs. This is not a suggestion — it's a gate.
7. **Multi-workspace is first-class.** A dev can work across multiple companies with different Linear workspaces and GitHub orgs. The state file, hooks, and subagent all handle this.
8. **Opt-out is permanent and one click.** `"workspace": "none"` silences everything forever for that repo.

---

## Build Instructions

Create all files listed above. Make sure:

- Hook scripts are valid bash that will work on macOS and Linux
- Python3 calls are self-contained (no imports beyond stdlib)
- JSON output from hooks is valid (escape properly)
- The subagent markdown has correct YAML frontmatter
- The installer handles all edge cases (existing files, missing directories, idempotent reruns)
- Every file has clear comments explaining what it does

After creating all files, create the `install.sh` at the root of the `linear-sync/` directory and test that `bash install.sh` would correctly deploy everything.

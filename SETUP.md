# Linear Sync — Setup Guide

## Prerequisites

- **Claude Code** CLI installed
- **Python 3** available as `python3`
- **curl**
- **Node.js / npx** (for the Linear MCP server)
- **GitHub CLI** (`gh`) — optional, required for GitHub Issue Sync
- A **Linear API key** — create one at Linear > Settings > Security & Access > Personal API Keys > **New API key**. Use "Linear Sync" as the name, **Full access** permissions, and **All teams you have access to**.

## Install

### Via Plugin (Recommended)

Add the Crystal Peak marketplace (one-time):

```bash
claude plugin marketplace add crystal-peak/claude-plugins
```

Install the plugin:

```bash
claude plugin install linear-sync@crystal-peak
```

Update to the latest version:

```bash
claude plugin marketplace update crystal-peak       # pull latest registry
claude plugin update linear-sync@crystal-peak        # update the plugin
```

Restart Claude Code after installing or updating for changes to take effect.

The plugin system handles hook registration, agent loading, and script paths automatically.

### Standalone (Alternative)

If you don't want to use the plugin system:

```bash
git clone https://github.com/crystal-peak/linear-sync.git
cd linear-sync
bash install.sh
```

The standalone installer is safe to re-run. Note: it does not include the PostToolUse hook (auto GitHub sync after push), auto-approve hooks, or the skill file — those are plugin-only.

## Configure Linear API Key

Export your Linear API key in `~/.zshrc` (or `~/.bashrc`):

```bash
export LINEAR_API_KEY="lin_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

Reload your shell (`source ~/.zshrc`) or open a new terminal.

Then add the MCP server to `~/.claude/mcp.json`, referencing the environment variable:

```json
{
  "mcpServers": {
    "linear": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@anthropic/linear-mcp-server"],
      "env": {
        "LINEAR_API_KEY": "$LINEAR_API_KEY"
      }
    }
  }
}
```

If you work across multiple Linear workspaces, export a separate variable per workspace and reference each one:

```bash
# ~/.zshrc
export LINEAR_API_KEY_OPL="lin_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export LINEAR_API_KEY_CRYSTALPEAK="lin_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

```json
{
  "mcpServers": {
    "linear-opl": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@anthropic/linear-mcp-server"],
      "env": { "LINEAR_API_KEY": "$LINEAR_API_KEY_OPL" }
    },
    "linear-crystalpeak": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@anthropic/linear-mcp-server"],
      "env": { "LINEAR_API_KEY": "$LINEAR_API_KEY_CRYSTALPEAK" }
    }
  }
}
```

## First Run

1. Open Claude Code in any git repo.
2. The session-start hook detects the repo and asks if it connects to Linear.
3. Pick your workspace, project, and team from the options presented — no typing IDs.
4. Choose "This repo doesn't use Linear" for repos that shouldn't be tracked.

Setup only happens once per repo. After that, sessions start with a quick "What are you working on?" prompt.

## Team Config Templates (Optional)

For teams that share repo conventions, create a `.linear-sync-template.json` in the repo root to pre-fill setup wizard defaults:

```json
{
  "workspace": "My Workspace",
  "project": "Project Atlas",
  "team": "ENG",
  "label": "repo:my-repo"
}
```

When a dev opens Claude Code in that repo for the first time, the setup wizard will offer to use these defaults instead of asking from scratch. The dev can still override any value. Commit this file to the repo so all team members benefit.

## What It Does

| Action | What happens |
|--------|-------------|
| **Session start** | Shows notification digest, stale branch warnings, then asks what you're working on (resume last issue, existing issue, new ticket, or just exploring) |
| **Resume last issue** | Remembers what you worked on last time and offers to resume |
| **Work on existing issue** | Shows your assigned in-progress issues as selectable options |
| **Start something new** | Checks for duplicate issues, infers priority from keywords, offers cycle/sprint assignment |
| **git commit** | Blocks if the message doesn't include an issue ID (e.g., `ENG-123`) |
| **git checkout -b** | Auto-generates branch name from issue ID + title (e.g., `alice/ENG-456-add-rate-limiter`) |
| **gh pr create** | Blocks if the PR title doesn't include an issue ID; auto-drafts PR body from issue context |
| **git push** | Runs GitHub issue sync automatically (plugin only), advisory warning if cross-issue commits |
| **gh pr create** (after success) | Offers to post a progress comment on the Linear issue (plugin only) |
| **Mention an issue in a prompt** | Fetches the issue summary from Linear in the background |
| **Pick an issue** | Warns if the issue is blocked by another; auto-assigns if unassigned |
| **Natural stopping points** | Drafts progress comment from commit history and offers to post (you approve first) |

## Repo-Level Config (`.claude/linear-sync.json`)

Linear Sync stores shared repo config in a committed file at `.claude/linear-sync.json` in your repo root. This file is the source of truth for which Linear project, team, and label the repo uses. It looks like:

```json
{
  "$schema": "https://raw.githubusercontent.com/crystal-peak/linear-sync/main/schema/linear-sync.json",
  "_warning": "AUTO-MANAGED by linear-sync. Manual edits may break issue sync, commit hooks, and branch naming. If you need to change the project or team, run the setup wizard again.",
  "workspace": "crystalpeak",
  "project": "My Project",
  "team": "PEAK",
  "label": "repo:my-repo"
}
```

The setup wizard creates this file automatically. Commit it so other developers on the repo get the same config without running the wizard again.

**Second-user experience:** When another developer clones a repo that already has this file, they only need to set up their API key for the workspace. No project/team/label questions.

## GitHub Issue Sync

Sync open GitHub issues into Linear and close GitHub issues when their Linear counterparts are resolved.

**Plugin:** Runs automatically after `git push` or `gh pr create` via the PostToolUse hook. Also injects a comment reminder after the sync.

**Standalone:** Run manually or via the session kickoff menu.

**What it does:**
- Creates Linear issues for any open GitHub issues that don't already exist in Linear (detected via a `<!-- gh-sync:org/repo#42 -->` marker in the description)
- Closes GitHub issues when their linked Linear issue has been completed or canceled
- Reports a one-line summary: "created N Linear issues, closed M GitHub issues"

**What it does NOT sync:** comments, labels, assignees, milestones.

**Title format:** Synced issues appear in Linear as `GH#42: <original title>` to distinguish them from issues created directly in Linear.

## Workspace Metadata Cache

Linear Sync caches workspace metadata (teams, projects, workflow states, labels) locally with a 24-hour TTL. This reduces API calls and speeds up the setup wizard and issue creation flows. The cache refreshes automatically when stale — no manual action needed.

## Opting Out a Repo

During setup, pick "This repo doesn't use Linear." All hooks go completely silent for that repo — zero overhead, zero output.

## Troubleshooting

**Hooks not firing?** Run `claude plugin marketplace update crystal-peak && claude plugin update linear-sync@crystal-peak` then restart Claude Code. For standalone installs, check that `~/.claude/settings.json` has the hook entries.

**"python3 not found"?** Install Python 3 and make sure `python3` is in your PATH.

**Want to re-link a repo?** If the repo has a `.claude/linear-sync.json` file, that is the primary config — delete or edit it first. Then delete the repo's entry from `~/.claude/linear-sync/state.json` (if one exists) and restart Claude Code in that repo to re-run the setup wizard.

**Want to uninstall?** Plugin: `claude plugin uninstall linear-sync@crystal-peak`. Standalone: remove the hook files from `~/.claude/hooks/`, the agent from `~/.claude/agents/api.md`, and the `Linear Sync (Auto-Managed)` section from `~/.claude/CLAUDE.md`.

**Stale branch warnings?** At session start, you'll see warnings for local branches with no commits in 5+ days. This is informational — you can clean them up or ignore. To delete a merged stale branch: `git branch -d <branch-name>`. To force-delete an unmerged branch: `git branch -D <branch-name>`.

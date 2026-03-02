# GitHub Issue Sync — Implementation Spec

## Overview

Add bidirectional issue sync between GitHub Issues and Linear for linked repos. GitHub issues flow into Linear as new issues. When a Linear issue is closed, its linked GitHub issue closes too.

**No local mapping files.** Linear is the source of truth for issue sync (duplicate detection uses a marker embedded in each Linear issue's description). Repo-to-project config is the source of truth at the **repo level** via a committed config file.

---

## Repo-Level Config (Shared Source of Truth)

### Problem

The current system stores repo-to-project mappings in a local file (`~/.claude/scripts/linear-repo-links.json`). This means two developers on the same repo could independently map it to different Linear projects, causing split issues, duplicate syncs, and general confusion.

### Solution

Store the shared repo config **in the repo itself** as a committed file. When User A sets up, the file gets committed. When User B clones or pulls, it's already there.

### File: `.claude/linear-sync.json`

Located in the repo root. Committed to git. This is the shared source of truth for which Linear project/team/label this repo uses.

```json
{
  "$schema": "https://raw.githubusercontent.com/crystal-peak/linear-sync/main/schema/linear-sync.json",
  "_warning": "AUTO-MANAGED by linear-sync. Manual edits may break issue sync, commit hooks, and branch naming. If you need to change the project or team, run the setup wizard again.",
  "workspace": "openprotocollabs",
  "project": "Linear Sync Test",
  "team": "OPL",
  "label": "repo:linear-sync-test",
  "github_org": "crystal-peak"
}

```

**The `_warning` field** exists so that anyone opening the file in an editor sees the warning immediately. It's ignored by the system.

### What stays local vs. what goes in the repo

| Setting | Where it lives | Why |
|---------|---------------|-----|
| Workspace name, project, team, label | **Repo** (`.claude/linear-sync.json`, committed) | Shared truth — all devs must agree |
| MCP server name / API key routing | **Local** (`~/.claude/scripts/linear-repo-links.json`) | Credentials are per-user |
| GitHub org defaults | **Local** | Per-user convenience |

### Changes to the local state file

The local state file (`~/.claude/scripts/linear-repo-links.json`) **no longer stores** `project`, `team`, or `label` for repos that have a committed config. It shrinks to credential routing only:

```json
{
  "workspaces": {
    "openprotocollabs": {
      "name": "Open Protocol Labs",
      "github_org": "crystal-peak"
    }
  },
  "repos": {
    "linear-sync-test": {
      "workspace": "openprotocollabs"
    }
  },
  "github_org_defaults": {
    "crystal-peak": "crystalpeak"
  }
}
```

The `repos` entry now only needs `workspace` (to know which API key to use). Everything else comes from the committed file.

**Backwards compatibility:** If `.claude/linear-sync.json` doesn't exist in a repo, fall back to reading from the local state file as before. This way existing linked repos keep working until they adopt the new format.

### Changes to the setup wizard

When the setup wizard completes:

1. Write `.claude/linear-sync.json` in the repo root (create `.claude/` dir if needed)
2. Write the minimal `workspace`-only entry to the local state file
3. **Do NOT auto-commit the file.** Let the dev include it in their next commit naturally, or offer: "Should I commit `.claude/linear-sync.json` now?"

### Changes to the session-start hook

The hook's config resolution order becomes:

1. Check for `.claude/linear-sync.json` in the repo root (preferred)
2. Fall back to `~/.claude/scripts/linear-repo-links.json` repo entry (legacy)
3. If neither exists, trigger setup wizard

When the repo file exists, the hook reads `workspace` from it, then looks up the workspace in the local state file to determine which MCP server/API key to use.

### Second-user experience

When User B clones a repo that already has `.claude/linear-sync.json`:

1. Session-start hook reads the file → knows project/team/label
2. Checks local state file for workspace credentials
3. If workspace exists locally → fully configured, no wizard needed
4. If workspace is missing locally → minimal wizard: "This repo uses the `openprotocollabs` workspace. Set up your API key?" Then just adds the workspace entry to the local state file. No project/team/label questions.

---

## GitHub Issue Sync Architecture

### Marker Format

When creating a Linear issue from a GitHub issue, embed this HTML comment at the end of the description:

```
<!-- gh-sync:org/repo#42 -->
```

This is the duplicate detection key. It's invisible in Linear's UI but queryable via the API.

### Sync Direction

| Direction | Trigger | What happens |
|-----------|---------|-------------|
| GitHub → Linear | On-demand or session start | New GH issues become Linear issues |
| Linear → GitHub | On-demand or session start | Closed Linear issues close their linked GH issues |

### Context Model

All sync work happens inside the **linear-sync subagent**. The main context never sees issue lists, API responses, or mapping data. It only gets a one-line summary like:

```
Synced 3 new issues from GitHub, closed 1 GitHub issue from Linear.
```

---

## Implementation Details

### 1. New Subagent Task: `sync-github-issues`

Add this task to `~/.claude/agents/api.md` under the `## Tasks` section.

#### Inputs (from main agent)

The main agent delegates with a message like:
> "Sync GitHub issues for repo `linear-sync-test`."

The subagent reads config from `.claude/linear-sync.json` in the repo (falling back to the local state file) to get workspace, project, team, and label. It gets `github_org` from the workspace entry in the local state file.

#### Step-by-step flow

**Phase 1: Gather data**

1. Read `.claude/linear-sync.json` from the repo root to get:
   - `project`, `team`, `label`
   - Then read `~/.claude/scripts/linear-repo-links.json` to get `github_org` from the workspace entry
2. Fetch all open GitHub issues:
   ```bash
   gh issue list --repo <org>/<repo> --state open --json number,title,body,labels,url --limit 500
   ```
3. Fetch all Linear issues in the project with the repo label:
   ```bash
   bash ~/.claude/scripts/linear-api.sh 'query {
     issues(filter: {
       project: { name: { eq: "<project>" } },
       labels: { some: { name: { eq: "<label>" } } }
     }, first: 500) {
       nodes { id identifier title description state { name type } }
     }
   }'
   ```
   *(Tested and confirmed — name-based equality filters work on both `project` and `labels`.)*

**Phase 2: GitHub → Linear (create missing)**

4. For each open GitHub issue, check if any Linear issue's `description` contains `<!-- gh-sync:<org>/<repo>#<number> -->`.
5. If no match found, create a Linear issue:
   ```bash
   bash ~/.claude/scripts/linear-api.sh 'mutation {
     issueCreate(input: {
       teamId: "<TEAM_ID>",
       title: "GH#<number>: <github_issue_title>",
       description: "<github_issue_body>\n\n---\n[GitHub Issue](<github_issue_url>)\n<!-- gh-sync:<org>/<repo>#<number> -->",
       projectId: "<PROJECT_ID>",
       labelIds: ["<LABEL_ID>"]
     }) { issue { id identifier title } }
   }'
   ```

   **Title format:** `GH#<number>: <original_title>` — the `GH#` prefix makes it clear this originated from GitHub. Do NOT put the Linear identifier in the GitHub issue (that would create circular confusion).

   **Description format:**
   ```markdown
   <original GitHub issue body>

   ---
   [GitHub Issue](https://github.com/org/repo/issues/42)
   <!-- gh-sync:org/repo#42 -->
   ```

   **Do NOT auto-assign a status.** Let it land in the default (Backlog/Triage) state. Unlike issues created when a dev says "start something new," these are inbound and haven't been triaged yet.

6. Track counts for the summary.

**Phase 3: Linear → GitHub (close resolved)**

7. From the Linear issues fetched in step 3, find any whose `state.type` is `"completed"` or `"canceled"` AND whose description contains a `<!-- gh-sync:... -->` marker.
8. For each, extract the GitHub issue number from the marker.
9. Check if that GitHub issue is still open:
   ```bash
   gh issue view <number> --repo <org>/<repo> --json state -q '.state'
   ```
10. If open, close it with a reference:
    ```bash
    gh issue close <number> --repo <org>/<repo> --comment "Closed via Linear (<LINEAR_IDENTIFIER>)."
    ```
11. Track counts for the summary.

**Phase 4: Return summary**

12. Return a single concise line to the main agent:
    ```
    GitHub sync for <repo>: created <N> Linear issues, closed <M> GitHub issues.
    ```
    If nothing changed: `GitHub sync for <repo>: everything in sync.`

---

### 2. Modify Session Start Hook

**File:** `~/.claude/hooks/linear-session-start.sh`

Two changes:

**A. Config resolution** — Update the hook to check for `.claude/linear-sync.json` in the repo root first, falling back to the local state file for project/team/label. The workspace entry in the local state file is still needed for API key routing.

**B. Sync hint** — In the **Case 2** block (linked repo with valid workspace), append a hint:

**Current output (Case 2):**
```
[Linear/<ws>] Repo: <name> | Workspace: <ws_name> | Project: <project> | Team: <team> | Label: <label> | Branch format: ...
Ask the dev what they're working on today...
```

**New output (Case 2) — add one line:**
```
[Linear/<ws>] Repo: <name> | Workspace: <ws_name> | Project: <project> | Team: <team> | Label: <label> | Branch format: ...
GitHub issue sync available. Delegate to linear-sync subagent with: "Sync GitHub issues for repo <name>."
Ask the dev what they're working on today...
```

---

### 3. Modify CLAUDE.md — Session Kickoff Options

**File:** `~/.claude/CLAUDE.md`

In the `### Session Kickoff (Linked Repos)` section, add a 4th option to the AskUserQuestion choices:

**Current options:**
1. "Work on an existing issue"
2. "Start something new"
3. "Just exploring / no ticket needed"

**New options:**
1. "Work on an existing issue"
2. "Start something new"
3. "Sync GitHub issues" — Delegate to `linear-sync` subagent (background) to run the `sync-github-issues` task. Report the summary back to the dev.
4. "Just exploring / no ticket needed"

---

### 4. Modify Setup Wizard in CLAUDE.md

**File:** `~/.claude/CLAUDE.md`

In the `### Setup Wizard Rules` section, update step 5 (after the dev has picked project/team/label):

**Add after current step 6:**

7. Write `.claude/linear-sync.json` to the repo root with the shared config (project, team, label, workspace name).
8. Write only the `workspace` reference to the local state file for the repo entry.
9. Offer to commit `.claude/linear-sync.json`: "Should I commit the Linear sync config now, or would you rather include it in your next commit?"

---

### 5. Modify Commit Guard Hook

**File:** `~/.claude/hooks/linear-commit-guard.sh`

Update the `REPO_INFO` resolution to check `.claude/linear-sync.json` first, falling back to the local state file. The hook currently reads the team prefix from the local state file — it should prefer the repo-level config.

---

### 6. GraphQL Queries — Getting IDs

The sync task needs team ID, project ID, and label ID to create issues. These aren't stored in config (only names are). The subagent resolves them at runtime:

**Get team ID from key:**
```graphql
query { teams(filter: { key: { eq: "OPL" } }) { nodes { id name key } } }
```

**Get project ID from name:**
```graphql
query { projects(filter: { name: { eq: "Linear Sync Test" } }) { nodes { id name } } }
```

**Get or create label:**
Already documented in the subagent's `### Verify/Create Label` task. Reuse that flow.

Cache these IDs for the duration of a single sync run (they're used repeatedly when creating multiple issues). No need to persist them — they're fetched fresh each sync.

---

### 7. Edge Cases

| Scenario | Handling |
|----------|---------|
| GitHub issue body is empty | Set Linear description to just the link + marker |
| GitHub issue body contains GraphQL-breaking characters (quotes, backslashes) | JSON-escape the body before embedding in the mutation. The `linear-api.sh` script expects a raw GraphQL string, so the subagent must escape properly. |
| GitHub issue was closed between fetch and sync | Skip it — only sync open issues |
| Linear issue was reopened after closing a GH issue | No action needed on the GH side. If the dev reopens the GH issue manually, next sync won't re-create it (marker still exists in Linear). |
| GitHub issue title changes after sync | Don't update. The Linear issue is now its own thing. The GH link in the description is the canonical reference. |
| Multiple repos share a project | Repo label distinguishes them. The sync query filters by both project name AND repo label. |
| Rate limits | The `gh` CLI and Linear API both have generous limits. For repos with 500+ issues, may need pagination. Start without it; add if needed. |
| GH issue is a pull request | `gh issue list` excludes PRs by default. No special handling needed. |
| Marker accidentally deleted from Linear description | That issue becomes "unlinked." Next sync would create a duplicate. Acceptable risk — manual edit of Linear descriptions is rare and the dev would notice. |
| `.claude/linear-sync.json` missing but local state file has config | Use local state file (backwards compatible). Offer to migrate by writing the repo-level file. |
| `.claude/linear-sync.json` exists but user has no local workspace entry | Minimal setup: just ask for API key routing for the workspace. Skip project/team/label questions. |
| `.claude/linear-sync.json` conflicts on merge | Extremely rare (file changes only during setup). Standard git conflict resolution applies. |
| Dev manually edits `.claude/linear-sync.json` incorrectly | The `_warning` field discourages this. If values don't match Linear (e.g., team key doesn't exist), the subagent will error and report it clearly. |

---

### 8. What NOT to Sync

- **Comments** — Different audiences (GH: external contributors, Linear: internal team). Don't cross the streams.
- **Labels** — GitHub labels and Linear labels serve different purposes. The repo label is applied automatically; GH labels stay on GH.
- **Assignees** — No reliable mapping between GitHub usernames and Linear users.
- **Milestones/Cycles** — Different planning models.

---

## Files to Modify

| File | Change |
|------|--------|
| `~/.claude/agents/api.md` | Add `### Sync GitHub Issues` task under `## Tasks` |
| `~/.claude/hooks/linear-session-start.sh` | Add config resolution from repo file + sync-available hint |
| `~/.claude/hooks/linear-commit-guard.sh` | Add config resolution from repo file (for team prefix) |
| `~/.claude/CLAUDE.md` | Add "Sync GitHub issues" kickoff option + update setup wizard to write repo-level config |

**One new file per repo** (created during setup): `.claude/linear-sync.json`

No new hooks. No new scripts. No new local state files.

---

## Testing Plan

### GitHub Issue Sync
1. **Manually create 2-3 GitHub issues** in a test repo linked to Linear
2. Run sync — verify Linear issues are created with correct title, description, link, marker, label
3. Run sync again — verify no duplicates
4. Close one of the Linear issues in Linear
5. Run sync again — verify the corresponding GitHub issue is closed with a comment
6. Create a GitHub issue that already has a matching Linear issue (manually add marker) — verify it's skipped
7. Test with empty issue body
8. Test with issue body containing quotes, backticks, special characters

### Repo-Level Config
9. Run setup wizard on a fresh repo — verify `.claude/linear-sync.json` is created with correct values
10. Clone the repo as a different user (or simulate by deleting local state) — verify second-user setup only asks for API key, not project/team/label
11. Verify existing repos without `.claude/linear-sync.json` still work via local state file fallback
12. Verify hooks (commit guard, session start) read from repo file when it exists
13. Verify hooks fall back to local state file when repo file is missing


<!-- ===== Linear Sync (Auto-Managed) ===== -->
<!-- Do not edit this section manually. It is managed by linear-sync. -->

## Linear Sync

This system keeps Linear and GitHub in sync automatically. All Linear API calls go through the `linear-sync` subagent — never call Linear MCP directly from the main context.

### Session Start Behavior

At the start of every session, the `linear-session-start` hook fires and checks the repo:

- **Linked repo**: The hook injects config context (workspace, project, team, label, formats, last_issue if any, stale branch warnings, digest trigger). Follow the session kickoff directive below.
- **Opted-out repo** (`workspace: "none"`): The hook is silent. Do nothing related to Linear.
- **Unregistered repo**: The hook injects a `[LINEAR-SETUP]` directive. Follow the setup wizard rules below. If a `.linear-sync-template.json` is found, the hook also injects `[LINEAR-TEMPLATE]` with defaults to pre-fill.
- **Broken workspace reference**: The hook injects a `[LINEAR-SETUP]` directive to reconfigure or opt out.

### Session Kickoff (Linked Repos)

When the hook injects config context for a linked repo:

**Step 1: Notification digest and GitHub sync (if available)**

Do two things in parallel:
- **Notification digest** (if `[LINEAR-DIGEST]` is present): Delegate to `linear-sync` subagent (background): "Fetch notification digest for project '<project>' with label '<label>'."
- **GitHub issue sync** (always): Run the sync script directly: `bash ~/.claude/scripts/sync-github-issues.sh <repo-root>`. This is a shell script, not a subagent task — run it via Bash in the background.

Briefly surface both results before asking what to work on. Keep each to 1 line.

**Step 2: Stale branch warning (if present)**

If the hook context includes `[STALE-BRANCHES]`, show a brief warning before the main prompt. Example: "Heads up: branch `dan/ENG-100-old-feature` has had no commits in 7 days."

**Step 3: Resume or ask**

If the hook context includes `last_issue: <ISSUE_ID>`, offer to resume that issue first:

Use AskUserQuestion: "What are you working on today in <repo>?"
1. **"Resume <ISSUE_ID>"** — Delegate to `linear-sync` subagent (background) to fetch the issue summary. After fetching, also delegate to save `last_issue` for this repo. Check for blockers in the response and warn if any.
2. **"Work on a different issue"** — Delegate to `linear-sync` subagent (background) to fetch the dev's assigned in-progress issues ("Fetch My Issues" task). Present the returned list as AskUserQuestion choices, plus an option to "Enter an issue ID manually". After selection, delegate to save `last_issue` for this repo. Check for blockers in the response and warn if any.
3. **"Start something new"** — Ask for a one-line description via AskUserQuestion. Check for duplicates first (see Duplicate Detection below). Then delegate to `linear-sync` subagent (background) to create a ticket in the correct project with the repo label. After creation, offer to assign to current cycle (see Cycle Assignment below). Use the returned issue ID going forward.
4. **"Just exploring / no ticket needed"** — Proceed normally. The commit guard hook will catch untagged commits later and you can offer to create a ticket at that point.

If no `last_issue` is present, skip option 1 and start with options 2-5 (renumber accordingly).

**When the dev picks any issue (resume, existing, or new):** If the issue is unassigned, automatically delegate to `linear-sync` subagent (background) to assign it to the dev ("Assign Issue to Viewer" task). No need to ask — if they're working on it, they should own it.

Keep the kickoff brief and natural: "What are you working on today in <repo>?"

### Setup Wizard Rules

When a `[LINEAR-SETUP]` directive is injected:

1. **Always use AskUserQuestion** for every choice. The dev never types workspace names, project IDs, or labels manually.
2. **Always offer "This repo doesn't use Linear"** as an option. If chosen, delegate to `linear-sync` subagent to write `workspace: "none"` and move on.
3. Use the `linear-sync` subagent in **foreground** mode to fetch real data from Linear MCP (workspaces, teams, projects, labels).
4. Present fetched data as AskUserQuestion choices.
5. For labels, suggest `repo:<repo-name>` as the default.
6. Detect the GitHub org from the repo's remote URL (e.g., `git remote get-url origin`). Include it as `github_org` in the committed config.
7. Write `.claude/linear-sync.json` to the repo root with the shared config (`workspace`, `project`, `team`, `label`, `github_org`, plus the `$schema` and `_warning` fields). Create the `.claude/` directory if it doesn't exist.
8. Write only the `workspace` reference to the local state file for the repo entry (credential routing only). Project, team, and label live in the repo-level config. Also write the `github_org` → workspace mapping to `github_org_defaults` in the local state file (so other repos in the same org auto-suggest this workspace).
9. The subagent will commit and push `.claude/linear-sync.json` as part of the Link Repo task. You do not need to do this yourself.
10. After setup, confirm in one line and proceed with the session kickoff (ask what they're working on).

### Project Rules

- Multiple repos can share the same project. This is common — e.g., `opl-api` and `opl-frontend` both under "Project Atlas".
- During the setup wizard, when presenting projects via AskUserQuestion, always include "Create a new project" as the last option.
- If the dev picks "Create a new project", ask for a project name, then delegate to the `linear-sync` subagent to create it in Linear via MCP before linking the repo.
- If the dev picks an existing project that other repos already use, that's fine — just link this repo to it. The repo label (e.g., `repo:api` vs `repo:frontend`) is what distinguishes issues within a shared project.

### Enforcement Rules (Linked Repos Only)

These conventions are mechanically enforced by hooks. They apply ONLY to repos with a valid workspace link. Opted-out and unregistered repos are not affected.

| Action | Requirement | Enforcement |
|--------|------------|-------------|
| `git commit -m "..."` | Issue ID in message (e.g., `ENG-123: fix bug`) | Hook blocks with exit 2 |
| `git checkout -b` / `git switch -c` | Issue ID in branch name (e.g., `ENG-123-fix-bug`) | Hook blocks with exit 2 |
| `gh pr create --title "..."` | Issue ID in PR title (e.g., `ENG-123: Fix the bug`) | Hook blocks with exit 2 |
| `git push` | Cross-issue commit check (multiple issue IDs on one branch) | Hook allows with advisory context |
| Issue creation | Repo label auto-applied and auto-created if missing | Subagent handles |
| Issue creation | Check for duplicates first | Subagent search + AskUserQuestion |
| Issue creation | Infer priority from keywords | AskUserQuestion if detected |
| Issue creation | Offer cycle/sprint assignment | AskUserQuestion if active cycle |
| Issue picked / resumed | Auto-assign if unassigned | Subagent handles silently |
| `gh pr create` (after success) | **Offer** a progress comment on the Linear issue | AskUserQuestion |
| `git push` (final push before wrapping up) | **Offer** a progress comment on the Linear issue | AskUserQuestion |
| Session ending / major milestone | **Offer** a progress comment on the Linear issue | AskUserQuestion |

### Linear Comments

**IMPORTANT: You MUST offer a comment at every natural stopping point.** Never post automatically, but always ask.

Natural stopping points (offer every time):
- **After creating a PR** — this is the most important one
- **After a significant push** when wrapping up a chunk of work
- **When the dev says they're done** or is ending the session

**Smart comment drafts:** Before drafting a comment, run `git log main..HEAD --oneline` (or the appropriate base branch) to gather the commit history for this branch. Use the commit messages to auto-draft a concise progress summary. This produces much better drafts than guessing.

Use AskUserQuestion with a draft comment:

    I can add a quick update to ENG-423:

    "Added sliding window rate limiter (3 commits):
     - Redis-backed per-user rate limiting
     - Configurable window size and limits
     - 94% test coverage
     PR: #142"

    1. Post this comment
    2. Let me edit it
    3. Skip

If they pick "edit", ask them what they'd like it to say. Never post without showing
them exactly what will be posted first. If they skip, don't ask again until the next stopping point.

### Issue Status

**If the dev explicitly asks to change a status, do it.** No pushback, no warnings. Just delegate to the linear-sync subagent and confirm.

For **automatic** status changes (no explicit request), only act at these moments:

- **"Start something new"** — Set the new issue to **In Progress** on creation. The dev just said they're starting work.
- **Blocked commit recovery** (ticket created at commit time) — Set to **In Progress** on creation. Same reason.

Don't automatically change status beyond those two cases. The Linear <-> GitHub integration handles the rest:
- Branch linked to issue -> In Progress (if not already)
- PR opened -> In Review
- PR merged -> Done

### Commit Message Formatting

Commits in linked repos must include an issue ID (e.g., `ENG-123: description`). Do NOT append `Co-Authored-By` lines to commit messages. Keep commit messages clean: just the issue ID prefix and a concise description.

### Branch Naming

Auto-generate branch names from the issue ID and title. Slugify and truncate
the description portion to keep the total branch name under 50 characters.

Examples:
- Issue: "ENG-456: Add sliding window rate limiter for premium tier users"
  Branch: `alice/ENG-456-add-sliding-window-rate`
- Issue: "CP-89: Fix authentication timeout on mobile when using SSO"
  Branch: `alice/CP-89-fix-auth-timeout-mobile`

Keep the meaningful words, drop filler. The issue ID is what matters —
the description is just for human readability at a glance. The dev never
manually names branches in a linked repo.

### Blocked Commit Recovery

When a commit, branch, or PR is blocked by the hook for missing an issue ID:

1. **Proactively offer to create a Linear ticket.** Do not just report the error.
2. Use AskUserQuestion to ask for a one-line description of the work.
3. Delegate to `linear-sync` subagent to create the ticket in the correct project with the repo label.
4. Retry the original command with the new issue ID inserted.
5. Do not make the dev start over or re-type their commit message.

### Duplicate Issue Detection

Before creating any new issue (via "Start something new" or blocked commit recovery):

1. Delegate to `linear-sync` subagent (background) with the "Search Issues" task, passing the proposed title.
2. If the subagent returns potential duplicates, present them to the dev via AskUserQuestion:
   ```
   I found similar open issues before creating a new one:
   1. ENG-100: Fix login timeout [In Progress] — assigned to Alice
   2. ENG-200: Login error handling [Todo] — unassigned

   Options:
   1. Work on ENG-100 instead
   2. Work on ENG-200 instead
   3. Create a new issue anyway (not a duplicate)
   ```
3. If the dev picks an existing issue, use that instead of creating a new one.
4. If no duplicates found, proceed with creation normally.

### Blocking Issue Warnings

When an issue is fetched (at session start, resume, or when picked), check the response from the subagent for blocker warnings (lines starting with "⚠ BLOCKED BY:"). If blockers are present:

1. Show the warning to the dev: "Heads up: this issue is blocked by ENG-100 (Database migration — not started yet)."
2. Do NOT prevent the dev from working on it. It's an advisory, not a block.
3. Use AskUserQuestion to ask: "Work on it anyway? / Switch to the blocking issue instead? / Pick a different issue?"

### PR Auto-Description

When `gh pr create` is about to run and you have issue context from the current session:

1. Use the issue title, description, and acceptance criteria (from the session-start fetch) to draft the PR body.
2. Structure the PR body as:
   ```
   ## Summary
   <1-2 sentence summary from issue context>

   ## Linear Issue
   <ISSUE_ID>: <title>

   ## Changes
   <bullet points summarizing commits from `git log main..HEAD --oneline`>

   ## Acceptance Criteria
   <from issue description, or "See Linear issue" if none specified>
   ```
3. Pass this as the `--body` argument to `gh pr create`. The dev can still edit it.
4. The issue ID must still appear in the `--title` (enforced by the commit guard hook).

### Cycle/Sprint Auto-Assignment

When creating a new issue (via "Start something new" or blocked commit recovery):

1. After the issue is created, delegate to `linear-sync` subagent (background) with the "Fetch Active Cycle" task for the team.
2. If an active cycle exists, use AskUserQuestion:
   ```
   Team TEAM has an active sprint: Sprint 14 (Jan 13 - Jan 27).
   Add ENG-456 to this sprint?
   1. Yes
   2. No
   ```
3. If the dev says yes, delegate to the subagent to add the issue to the cycle.
4. If no active cycle, skip silently.

### Priority Inference

When creating a new issue, scan the dev's description for urgency signals and suggest a priority:

| Keywords | Suggested Priority |
|----------|-------------------|
| `urgent`, `asap`, `critical`, `emergency`, `p0`, `hotfix`, `production down`, `outage` | 1 (Urgent) |
| `important`, `high priority`, `p1`, `blocker`, `blocking`, `regression` | 2 (High) |
| `bug`, `fix`, `broken`, `error`, `p2` | 3 (Medium) |
| `nice to have`, `low priority`, `p3`, `p4`, `when possible`, `minor`, `cleanup`, `chore`, `refactor` | 4 (Low) |

If urgency keywords are detected, use AskUserQuestion:
```
Based on your description, this sounds like it might be urgent.
Suggested priority: Urgent (P1)
1. Set to Urgent (P1)
2. Set to High (P2)
3. Set to Medium (P3)
4. Set to Low (P4)
5. No priority
```

If no keywords match, don't ask — just create without a priority (default).

Pass the chosen priority number (1-4) to the subagent when creating the issue.

### Stale Branch Handling

If the session-start hook injects a `[STALE-BRANCHES]` warning, show it to the dev briefly. This is informational only — do not take action automatically. The dev can choose to clean up branches or ignore the warning.

### Cross-Issue Commit Warning

If the commit guard hook injects a `[CROSS-ISSUE-COMMITS]` advisory, show it to the dev:

"Advisory: This branch has commits referencing different issues (ENG-123, ENG-456). This is usually fine for related work, but you may want to split into separate branches if the work is unrelated."

This is a warning, not a block. Do not prevent the push.

### Closed Issues Without PRs

If the session-start digest mentions closed issues without linked PRs, surface it briefly: "Note: ENG-123 was marked Done but has no linked PR." This is informational — the dev may have closed it manually or the PR was in a different repo.

### Team Config Templates

If a `.linear-sync-template.json` file exists in the repo root, use its values as defaults during the setup wizard. The template format:

```json
{
  "workspace": "workspace-name",
  "project": "Project Name",
  "team": "TEAM",
  "label": "repo:my-repo"
}
```

When the setup wizard runs and a template is found, pre-fill the choices from the template and ask the dev to confirm: "Found a team config template. Use these defaults? Workspace: X, Project: Y, Team: Z, Label: W". The dev can still override any value.

### Context Conservation

- **Never call Linear MCP directly** from the main context window. Always delegate to the `linear-sync` subagent.
- Use **background** mode for ongoing work (fetching summaries, posting comments, creating issues during normal flow).
- Use **foreground** mode only during one-time setup wizard flows.
- The hooks inject minimal `additionalContext` strings — they do not dump API data into the context.

<!-- ===== End Linear Sync ===== -->

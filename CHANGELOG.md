# Changelog

All notable changes to linear-sync are documented here.

## [0.0.21-alpha] - 2026-04-23

### Added
- New subagent task **Fetch Open Project Work**: single-query GraphQL that pulls every open issue in the project (including sub-issues at any depth) plus all Linear Project Milestones, then groups the output by milestone with parent/child hierarchy. Returns a tree so nothing gets swallowed.
- Skill and CLAUDE-snippet enforcement rule routing "what's open / what needs to be done / project status / milestones / what's left" questions to the new task. Previously these went through `Fetch My Issues`, which is assignee-gated and hid sub-issues.
- `parent { identifier title }` added to the session-start digest query; issues that are sub-issues now render with ` — under PARENT-ID` inline so you see hierarchy without a second round trip.
- `parent { identifier title }` added to the `Fetch My Issues` selection so sub-issues in the personal queue list show their parent.

### Fixed
- Sub-issues and project milestones were invisible whenever the user asked "what are the open issues for this project?" — caused missed deadlines because the real work often lives under parent epics. Root cause: every issue-fetching code path used `viewer.assignedIssues` with no `parent` or `projectMilestone` selection. Now the dedicated on-ask query uses `issues(filter: { project })`, which Linear flattens across hierarchy.

## [0.0.19-alpha] - 2026-03-13

### Added
- Auto-approve standalone `linear-api.sh` path resolution (`VAR=$(ls ...linear-api.sh...)`)
- Auto-approve indirect variable API calls (`bash "$VAR"` where VAR was assigned from a `linear-api.sh` path)
- `echo` added as safe shell builtin in API allow hook
- `STATE_FILE_OVERRIDE` env var support in commit guard for test isolation
- 11 new hook tests covering path resolution and indirect variable patterns

### Fixed
- Commit guard tests now use isolated temp fixtures instead of depending on host state file — all 96 tests pass regardless of local Linear workspace config
- Use POSIX character classes in sed for macOS compatibility

## [0.0.18-alpha] - 2026-03-09

### Changed
- Rebrand from crystal-peak to b-open-io across all references

## [0.0.17-alpha] - 2026-03-04

### Changed
- Setup docs updated to use env var for Linear API key

## [0.0.16-alpha] - 2026-03-02

### Added
- Nest repo labels under group label in Linear UI
- Auto-approve curl to Linear API and multiline GraphQL queries
- Auto-approve multiline single-quoted GraphQL queries
- Auto-approve read-only shell utilities in commit guard
- Sonnet subagent (switched from haiku)
- Skill trigger expanded to match setup directives
- Plugin update workflow documented in README and SETUP

### Fixed
- Always fetch fresh digest, fix subagent MCP assumption
- Drop label filter from session digest query
- Workspace isolation and auto-approve gaps
- Subagent defaulting to wrong workspace

## [0.0.10-alpha] - 2026-03-02

### Added
- Subagent type resolution and auto-approve hook
- Session-start hook rewritten as single Python script
- Parallelized sequential API calls in sync-github-issues.sh
- Marketplace moved to dedicated claude-plugins repo

### Fixed
- Self-heal missing issue titles in session-start hook
- Show issue title in session kickoff resume option

## [0.0.1-alpha] - 2026-02-27

### Added
- Initial release
- Linear MCP tool integration for native issue management
- Commit guard hook enforcing issue IDs on commits, branches, and PRs
- API allow hook for auto-approving trusted linear-api.sh calls
- State allow hook for auto-approving state file access
- Session-start hook with issue digest and workspace detection
- GitHub issue sync script
- Comprehensive test suite

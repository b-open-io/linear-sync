---
name: codex-agent-setup
description: >-
  Explicit-only installer for the Linear Sync API Codex custom agent. Use ONLY
  when the user explicitly asks to install, update, check, uninstall, or set up
  the Linear Sync Codex agent, including "install Linear Sync API in Codex",
  "update the Linear Codex agent", or "check linear_sync_api". Never auto-invoke
  for ordinary Linear, issue, project, team, commit, branch, or sync requests.
disable-model-invocation: false
user-invocable: true
metadata:
  author: b-open-io
  version: "1.0.0"
  codex:
    disable-model-invocation: true
    explicit_invocation_only: true
    never_modify_global_config: true
---

# Linear Sync Codex Agent Setup

Install the generated Linear Sync API adapter as a regular file. Run this skill
only after an explicit request to install, update, check, or uninstall it.

## Safety contract

- Default to the current project's `.codex/agents/` directory.
- Use `--user` only when the user explicitly requests a user-wide install.
- Never edit `~/.codex/config.toml` or any global Codex configuration.
- Never create plugin-cache symlinks or delete unrelated custom agents.
- Run `--check` when the user asks what would change.

## Commands

```bash
bash "${SKILL_DIR}/scripts/setup.sh" [--check|--uninstall|--force]
bash "${SKILL_DIR}/scripts/setup.sh" --user [--check|--uninstall|--force]
bash "${SKILL_DIR}/scripts/setup.sh" --target /custom/agents/directory
```

The installer manages only `linear-sync-api.toml` and records ownership in
`.linear-sync-agents.json`. An unmanaged collision is refused unless the user
explicitly authorizes `--force`.

After a successful install or update, tell the user to start a **new Codex
session**, then invoke the agent using runtime name `linear_sync_api`.

## Maintainer generation

```bash
bash "${SKILL_DIR}/scripts/generate.sh"
bash "${SKILL_DIR}/scripts/generate.sh" --check
```

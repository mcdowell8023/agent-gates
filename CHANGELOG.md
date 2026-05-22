# Changelog

All notable changes to agent-gates will be documented in this file.

## [1.2.1] - 2026-05-22

### Fixed (critical)
- **`memory-reminder.mjs`**: emitted JSON now includes the required `hookSpecificOutput.hookEventName: "PostToolUse"` field. Without it, Claude Code's hook-output validator rejects the response, writes a `hook_non_blocking_error` attachment to the session transcript (visible in `~/.claude/projects/<repo>/<session>.jsonl`), and **silently drops the reminder**. Net effect: `[AGENT-GATES: Memory Persistence Reminder]` never reached the agent on Claude Code since the hook's introduction.
- End-to-end verified by spawning a fresh Paseo `claude/sonnet` agent in `cwd=~/Projects/agent-gates`, having it call `TaskCreate` + `TaskUpdate(status=completed)`, then reading back the injected reminder verbatim. Pre-fix run reported `NO`; post-fix run reported `YES` with the first three lines of the reminder body matching.

### Discovery context
- v1.1.2 fixed where the hook is registered (`settings.json` not `hooks.json`) and the matcher (`TaskUpdate`/`TaskCreate` added). That made Claude Code attempt to invoke our hook for the first time — at which point the schema mismatch surfaced. v1.0.0–v1.2.0 all had this defect; it was latent because earlier sessions never reached the validator code path.

## [1.2.0] - 2025-05-21

### Added
- **agent-workflow-rules SKILL.md §8 Memory Persistence (⛔ Hard Constraint)** — new section detailing when to save (each completed todo, each phase delivery, session end), how to act on the `[AGENT-GATES: Memory Persistence Reminder]` system-reminder injected by `memory-reminder.mjs`, what to record, what NOT to save, loading prior memory on session start, and the no-Memory-skill fallback flow using `.agent/PROGRESS.md` + `.agent/memory/`.
- §0 Precedence note updated to describe the new §8 in relation to global rules.

### Changed
- Renumbered subsequent SKILL.md sections: Progress Tracking → §9, Anti-Pattern Self-Check → §10, Completion Definition → §11.

## [1.1.2] - 2025-05-21

### Fixed (critical)
- **install.sh**: hook registration now writes to `~/.claude/settings.json` `.hooks.PostToolUse[]` for OMC and `~/.codex/hooks.json` `.hooks.PostToolUse[]` for OMX. Previously wrote to `~/.claude/hooks.json` and root-level `.PostToolUse`, which **Claude Code does not read** — meaning the memory-reminder hook never actually fired on Claude Code since v1.0.0.
- **install.sh**: PostToolUse matcher expanded from `TodoWrite|todowrite` to `TodoWrite|todowrite|TaskUpdate|TaskCreate` to cover Claude Code's current todo tool names. The old matcher never matched on Claude Code installations.
- **install.sh**: `register_hook` now uses the nested `.hooks.PostToolUse` schema for both OMC and OMX, idempotent merge via `jq` that preserves all unrelated top-level settings.json keys (model, permissions, theme, etc.).
- **uninstall.sh**: removes hook entries from `~/.claude/settings.json` and `~/.codex/hooks.json` using the nested schema; preserves all other settings.json keys; also sweeps the legacy `~/.claude/hooks.json` path so users on prior versions get cleaned up.

### Changed
- README "Supported Platforms" table now shows the actual config file path and schema per platform; OMO marked as manual until v1.2.0.
- OMO automated registration deferred — added warning + manual instructions in installer output.

### Known limitations
- Claude Code does NOT hot-reload `settings.json`. Hook activation requires a new Claude Code session after install.

## [1.1.1] - 2025-05-21

### Added
- `install.sh`: hard `check_dependencies` for Node.js ≥18 (fails with install hint when missing)
- `install.sh`: `check_optional_deps` — detects `jq` and Memory skill, prints platform-specific install commands when missing (does not auto-mutate system)
- `install.sh`: backs up user-modified `SKILL.md` as `SKILL.md.bak.<timestamp>` before overwriting on upgrade; final summary lists all backups
- `install.sh`: `--upgrade` alias for `--force`; `--help` flag with usage
- `uninstall.sh`: `--purge-backups` to remove generated `SKILL.md.bak.*` files; `--help` flag
- README: Prerequisites entry for Memory skill; new `Upgrade` section with limitations; new `Troubleshooting` table

### Changed
- Installer "Done" summary now lists backed-up skill files and a per-project hook upgrade reminder
- `register_hook_json` fallback message now includes the platform-specific `jq` install command

## [1.1.0] - 2025-05-21

### Fixed
- **memory-reminder.mjs**: False-positive detection when todo content contains "completed"/"done" — now checks `todos[].status` field specifically
- **install.sh**: Can now merge into existing `hooks.json` via `jq` (previously required manual merge)
- **install.sh**: Detects OMO (OpenCode) override path `~/.config/opencode/hooks.json`

### Added
- `uninstall.sh` for clean removal of hooks, skills, and platform registrations
- `.version` file for version pinning and upgrade detection
- `tests/` directory with hook test fixtures and runner
- Code readability improvements (stdin fd, exit code, fallback regex documentation)

## [1.0.0] - 2025-05-20

### Added
- Initial monorepo structure with 3 skills: `init-project-gates`, `agent-workflow-rules`, `agent-review-protocol`
- `hooks/git/agent-quality-gate.sh` v1.3 — test correspondence + cross-review enforcement
- `hooks/platform/memory-reminder.mjs` — PostToolUse hook for Memory persistence reminders
- `install.sh` — multi-platform installer with auto-detection
- `templates/.agent/` — project-level PROGRESS.md, GATES.md, .gitignore
- `docs/platform-hooks.md` — hook registration documentation
- `README.md` — architecture overview and quick-start guide

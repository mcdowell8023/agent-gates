# Agent Gates

Runtime quality gates for AI coding agents. One install gives your team TDD enforcement, cross-review evidence checks, memory persistence reminders, and progress tracking — across Claude Code, OpenCode, and Codex.

## Architecture

```
agent-gates/
├── skills/                          # Agent skills (auto-loaded by platforms)
│   ├── agent-workflow-rules/        # TDD, plan review, verification, anti-loop
│   ├── agent-review-protocol/       # Three-Agent Review, cross-check pipeline
│   └── init-project-gates/          # Project initializer (one-time setup)
├── hooks/
│   ├── git/
│   │   └── agent-quality-gate.sh    # Pre-commit: test correspondence + review evidence
│   └── platform/
│       └── memory-reminder.mjs      # PostToolUse: Memory persistence enforcement
├── templates/
│   └── .agent/                      # Project directory template
└── install.sh                       # Multi-platform installer
```

## Prerequisites

| Dependency | Required | Purpose |
|------------|----------|---------|
| Node.js ≥18 | Yes | Runs `memory-reminder.mjs` (ES modules + `node:fs`) |
| `git` or `curl` | Yes | Installer uses one to fetch this repo |
| `jq` | Recommended | Merges agent-gates entry into existing `hooks.json`; without it the installer falls back to printing manual instructions |
| Memory-management skill (e.g. `memory`, `writer-memory`) | Recommended | `memory-reminder.mjs` injects a system-reminder to save state; without a Memory skill the reminder is informational only. Installer prints candidate skills dirs when missing. |
| One agent platform (Claude Code / OpenCode / Codex / cc-switch) | Recommended | Installer auto-detects; falls back to `~/.claude/skills/` if none present |

The install path must be space-free (`$HOME` must not contain spaces) — shell hooks cannot reliably escape such paths.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/mcdowell8023/agent-gates.git
cd agent-gates
./install.sh
```

## What's Included

### Skills

| Skill | Purpose | Activation |
|-------|---------|------------|
| `init-project-gates` | Project setup: hook + `.agent/` dir + AGENTS.md | Manual: "init project" |
| `agent-workflow-rules` | TDD, plan review, verification, debugging | Auto-loads on code tasks |
| `agent-review-protocol` | Three-Agent Review pipeline, cross-check | During review phases |

### Hooks

| Hook | Type | Trigger | Enforcement |
|------|------|---------|-------------|
| `agent-quality-gate.sh` | Git pre-commit | Agent commits (`AGENT_MODE=1`) | Test files + review evidence |
| `memory-reminder.mjs` | Platform PostToolUse | Todo marked completed | Memory skill save reminder |

### Convention: `.agent/` Directory

```
.agent/
├── PROGRESS.md      # Sprint tracking, decisions, blockers (git tracked)
├── GATES.md         # Quality gates checklist (git tracked)
├── reviews/         # Cross-review evidence files (git tracked)
├── plans/           # Implementation plans (git tracked)
└── memory/          # Session memory (.gitignored)
```

## Supported Platforms

| Platform | Skills Location | Hook Registration |
|----------|----------------|-------------------|
| Claude Code (OMC) | `~/.claude/skills/` | `~/.claude/hooks.json` |
| OpenCode (OMO) | `~/.config/opencode/skills/` | `~/.claude/settings.json` |
| Codex (OMX) | `~/.codex/skills/` | `~/.codex/hooks.json` |
| cc-switch | `~/.cc-switch/skills/` + symlinks | All of above |

## How It Works

### Git Quality Gate (agent-only)

The pre-commit hook ONLY fires for agent sessions (`AGENT_MODE=1`). Human developers pass through freely.

**Gate 1 — Test Correspondence**: Every new source file must have a corresponding test file.

**Gate 2 — Cross-Review Evidence**: When commits exceed threshold (`LOGIC_FILES > 1 AND DIFF > 50` OR `SINGLE_FILE > 150 lines`), requires a review file in `.agent/reviews/` with `VERDICT: PASS`.

### Memory Persistence Reminder

When an agent marks a todo as completed, the platform hook injects a system reminder to save key outputs via Memory skill — preventing session knowledge loss (红线 #12 enforcement).

### Workflow Rules (Runtime)

- TDD-first: write failing test → implement → verify
- Plan review gates: get review before large implementations
- Anti-loop: max 2 fix attempts before escalation
- Verification-before-completion: evidence before claims

## Usage

After installation, in any project:

```
初始化项目
```

The agent will:
1. Create `.agent/` directory with templates
2. Install pre-commit quality gate hook
3. Generate AGENTS.md hierarchy (via deepinit)
4. Inject tracking rules into project CLAUDE.md

## Upgrade

Re-run the installer; the same command handles first install and upgrade:

```bash
curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash
```

What the installer does on upgrade:

- Compares the installed `.version` against the repo's; **skips when they match** (use `--force` or `--upgrade` to re-install anyway).
- **Backs up locally-modified `SKILL.md` files** as `SKILL.md.bak.<timestamp>` before overwriting, and lists them in the final summary.
- **Idempotent hook registration**: existing `hooks.json` is merged via `jq` without duplicates. If `jq` is missing, the installer prints the command to install it and the manual JSON entry to add.

### Upgrade limitations to know about

- **Per-project hook is NOT auto-upgraded.** Each project's `.git/hooks/agent-quality-gate` is a one-time copy made by `init-project-gates`. After upgrading agent-gates globally, re-run `init project gates` in each initialized repo to sync the latest hook.
- **Backups accumulate.** Each upgrade that detects user changes leaves a new `SKILL.md.bak.*` file. Run `./uninstall.sh --purge-backups` (combined with `--keep-skills` if you only want to clean backups) to remove them after merging your edits.
- **OpenCode override mode.** If `~/.config/opencode/hooks.json` exists, the installer treats it as an override and merges there too. Without it, OMO falls back to `~/.claude/hooks.json`.
- **No automatic skill migration.** If a future version renames or restructures a skill directory, you may need to manually clean up the old layout — the installer only updates known skill names.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `node not found` | Node.js missing or not in PATH | Install Node.js ≥18: https://nodejs.org/ |
| `node ≥18 required (found vXX)` | Old Node version | Upgrade Node (e.g. `nvm install 20`, or your package manager) |
| `jq not found for safe merge` | `jq` missing while `hooks.json` already exists | Run the install command the installer prints (`brew install jq` / `apt-get install jq` / etc.) and re-run |
| `Install path contains spaces` | `$HOME` contains a space | Use a space-free home path; shell hooks cannot reliably escape it |
| `No memory* skill found` warning | No Memory skill installed | Install a memory skill in any of the printed candidate dirs; without one the reminders fire but have no target skill to call |
| Hook fires but nothing seems to happen | Memory skill missing, or agent ignored reminder | Verify Memory skill is installed; check agent platform actually executes `PostToolUse` hooks |
| Skill behavior unchanged after upgrade | Per-project hook was not refreshed | In the affected repo: re-run `init project gates` |
| `hooks.json` has duplicate entries | Manual edits combined with installer re-runs | `./uninstall.sh` then re-install for a clean state |
| Need to roll back a skill change | Looking for the previous SKILL.md | Check `SKILL.md.bak.<timestamp>` in the same skill directory |

## Relationship Between Components

```
init-project-gates          ─── sets up project ───►  .agent/ + hook
       │
       │ runtime companion
       ▼
agent-workflow-rules        ─── governs how agent works ───►  TDD / verification
       │
       │ review enforcement
       ▼
agent-review-protocol       ─── cross-check pipeline ───►  .agent/reviews/
       │
       │ persistence enforcement
       ▼
memory-reminder.mjs         ─── platform hook ───►  Memory skill save
```

## License

MIT

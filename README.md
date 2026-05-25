# Agent Gates

Runtime quality gates for AI coding agents. One install gives your team TDD enforcement, cross-review evidence checks, memory persistence reminders, and progress tracking — across Claude Code, OpenCode, and Codex.

> 📖 **中文整体说明**（问题、架构、与 agent-superpowers / OpenSpec 的关系、使用方式、含 mermaid 图）：[docs/explainer.zh.md](./docs/explainer.zh.md)

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
| `agent-superpowers` skill suite | Recommended (Path B); required when `agent-workflow-rules` Skill Gate triggers fire | Provides `test-driven-development`, `brainstorming`, `verification-before-completion`, `opsx:explore`; see Upstream skill dependencies below |
| OpenSpec CLI | Required for Path A (team project) | Drives `opsx:explore` / `opsx:propose` / `opsx:apply` / `opsx:archive`; `doctor.sh check_openspec_install` reports whether Path A applies |

The install path must be space-free (`$HOME` must not contain spaces) — shell hooks cannot reliably escape such paths.

### Upstream skill dependencies (not auto-installed)

`agent-gates` deliberately does **not** auto-install upstream skills or the OpenSpec CLI — per the project's destructive-command red line, third-party tooling must be installed by the user after review:

| Dependency | Install command | Source |
|---|---|---|
| `agent-superpowers` skill suite | follow the upstream README to copy `test-driven-development`, `brainstorming`, `verification-before-completion`, `opsx:explore` into your agent skills dir | <https://github.com/obra/superpowers> |
| OpenSpec CLI | `npm install -g @openspec/cli` | <https://github.com/Fission-AI/OpenSpec> |

If none of these are installed, agent-gates still runs — Path B (TDD only, no OpenSpec / no BDD) is the default. `doctor.sh` reports their absence as informational `note`, not `FAIL`.

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

| Platform | Skills Location | Hook Registration | Schema |
|----------|----------------|-------------------|--------|
| Claude Code (OMC) | `~/.claude/skills/` | `~/.claude/settings.json` → `.hooks.PostToolUse[]` | requires existing `settings.json` (start Claude Code once first) |
| OpenCode (OMO) | `~/.config/opencode/skills/` | manual — installer prints the entry to add to `~/.config/opencode/hooks.json` `.hooks.PostToolUse[]`; auto-registration tracked | nested schema (same shape as OMC/OMX) |
| Codex (OMX) | `~/.codex/skills/` | `~/.codex/hooks.json` → `.hooks.PostToolUse[]` | nested schema, installer creates file if missing |
| cc-switch | `~/.cc-switch/skills/` + symlinks | combines OMC + OMX above | — |

The PostToolUse matcher used by the installer is `TodoWrite|todowrite|TaskUpdate|TaskCreate` to cover both the legacy `TodoWrite` tool name and Claude Code's current `TaskUpdate` / `TaskCreate` tools.

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

### Workflow Paths: A (OpenSpec) vs B (no OpenSpec)

Agent Gates supports two workflow paths, auto-detected per project:

| | Path A (team project) | Path B (individual / no OpenSpec) |
|---|---|---|
| Trigger | `.opencode/skills/openspec-propose/` or `.claude/skills/openspec-propose/` or `openspec/changes/` present | Otherwise |
| Planning | `opsx:explore` → `opsx:propose` (generates `proposal.md` + `specs.md` + `tasks.md`) | `brainstorming` skill → `writing-plans` skill |
| Acceptance | `features/*.feature` (Gherkin) referenced from `specs.md`; each `tasks.md` step links a scenario | Plan steps tagged RED / GREEN / REFACTOR |
| Implementation | `opsx:apply` (BDD-TDD: step-defs first) | `test-driven-development` skill |
| Pre-commit gate | 4-CHECK (OpenSpec change + `.feature` + test correspondence + test pass) under `AGENT_MODE=1` | Test correspondence + cross-review evidence under `AGENT_MODE=1` |
| Review | Spec Reviewer → Quality Reviewer → CLI gate → `opsx:archive` | Cross-review evidence in `.agent/reviews/` |

Both paths share the same `agent-workflow-rules` skill as the canonical source of TDD, plan-review, verification, and anti-loop rules. Path A layers OpenSpec (L1 requirements) and BDD (L2 acceptance) on top; Path B uses TDD alone.

`doctor.sh` reports which path applies for the current working directory (`check_openspec_install` + `check_bdd_features_dir`).

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

- **Per-project hook is NOT auto-upgraded.** Each project's `.githooks/agent-quality-gate.sh` (with `pre-commit` symlinked to it) is a one-time copy made by `init-project-gates`. After upgrading agent-gates globally, re-run `init project gates` in each initialized repo to sync the latest hook.
- **Backups accumulate.** Each upgrade that detects user changes leaves a new `SKILL.md.bak.*` file. Run `./uninstall.sh --purge-backups` (combined with `--keep-skills` if you only want to clean backups) to remove them after merging your edits.
- **OMO hook registration is manual.** When the installer detects `~/.config/opencode/`, it prints the JSON entry to add under `~/.config/opencode/hooks.json` `.hooks.PostToolUse[]`. `doctor.sh` checks the same path/schema; if it reports the OMO hook as missing, add the entry by hand (see `docs/platform-hooks.md` → OMO for the full JSON shape).
- **No automatic skill migration.** If a future version renames or restructures a skill directory, you may need to manually clean up the old layout — the installer only updates known skill names.

## Doctor

After install, run `~/.agent-gates/doctor.sh` (or `./doctor.sh` from the repo) to verify deployment health:

```bash
~/.agent-gates/doctor.sh
```

Sample output (ideal Path A: OpenSpec installed + ≥1 `.feature` + clean transcripts):

```
✓ node v26.0.0
✓ jq jq-1.8.1
✓ Memory skill detected: ~/.cc-switch/skills/memory-1.0.2
✓ installed version: 1.4.0
✓ up to date with remote (1.4.0)
✓ memory-reminder.mjs present
✓ agent-quality-gate.sh present (executable)
✓ OMC settings.json hook registered (matcher contains TaskUpdate)
✓ OMO hooks.json hook registered
✓ OMX hooks.json hook registered
✓ hook output schema valid (hookEventName=PostToolUse, reminder included)
✓ no memory-reminder hook errors in last-7d transcripts
✓ OpenSpec installed in current project (Path A applies)
✓ BDD features/ has 3 .feature file(s)

13 pass · 0 warn · 0 fail
```

In a default Path B project (no OpenSpec, no `features/`) the last two lines become informational `note`s instead of PASS, so the typical output is **11 PASS + 2 note** (not 13 PASS). `note` means "not applicable / not configured", not "broken".

Exit code is **0 if no FAIL** (WARN allowed), **1 if any FAIL**, so the script is CI-friendly:

```bash
~/.agent-gates/doctor.sh --quiet --no-network && echo "deployment OK"
```

| Flag | Effect |
|---|---|
| `--quiet` | Suppress dim/info notes; show only the PASS/WARN/FAIL table |
| `--no-network` | Skip the remote `.version` check (offline mode) |
| `--help` | Usage |

Doctor checks the same surface as the install/uninstall scripts (paths, registrations, schema). If a check FAILs, the message includes a one-line fix hint pointing back to `install.sh` or this README's Troubleshooting section.

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

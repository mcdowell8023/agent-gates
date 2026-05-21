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

## Update

Re-run installer to get latest skills + hooks:

```bash
curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash
```

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

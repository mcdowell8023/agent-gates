# Agent Toolkit

Runtime discipline skills for AI coding agents. Install once, get TDD enforcement, plan review gates, progress tracking, and quality hooks across all your projects.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-toolkit/main/install.sh | bash
```

Or clone and run manually:

```bash
git clone https://github.com/mcdowell8023/agent-toolkit.git
cd agent-toolkit
./install.sh
```

## What's Included

| Skill | Purpose | When |
|-------|---------|------|
| `init-project-gates` | One-time project setup: pre-commit hook, `.agent/` directory, AGENTS.md | Run once per project |
| `agent-workflow-rules` | TDD, plan review, verification, anti-over-engineering, debugging | Auto-loads when writing code |
| `agent-review-protocol` | Three-Agent Review, cross-check, Superpowers | During code review phases |

## Supported Platforms

- Claude Code (`~/.claude/skills/`)
- OpenCode (`~/.config/opencode/skills/`)
- Codex (`~/.codex/skills/`)
- cc-switch (`~/.cc-switch/skills/` + auto-symlinks)

## Usage

After installation, tell your agent:

```
初始化项目
```

or

```
init project gates
```

The agent will:
1. Create `.agent/` directory (PROGRESS.md, memory/, plans/)
2. Install pre-commit quality gate hook (agent-only, humans pass through)
3. Generate AGENTS.md hierarchy
4. Inject rules into project CLAUDE.md

## Project Convention

All agent working artifacts live in `.agent/` at project root:

```
.agent/
├── PROGRESS.md    # Progress tracking (git tracked)
├── GATES.md       # Quality gates checklist (git tracked)
├── memory/        # Cross-session memory (.gitignore)
└── plans/         # Implementation plans (git tracked)
```

## Update

Re-run the install script to update all skills to latest:

```bash
curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-toolkit/main/install.sh | bash
```

## License

MIT

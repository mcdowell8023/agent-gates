---
name: init-project-gates
description: "One-command project initialization for agent-assisted development. Installs quality gate pre-commit hook, generates AGENTS.md, creates PROGRESS.md for multi-day tracking. Supports batch mode. Use when setting up projects for agents, or when user says 'init project', 'install gates', 'setup quality gate', 'init gates', '装门控', '初始化门控', '初始化项目', 'init for agents', '批量初始化', 'init all projects'."
---

# Init Project Gates

## Overview

One-command setup for agent-assisted development in any project:

1. **Quality Gate Hook** — pre-commit hook enforcing test file correspondence + cross-review evidence (agent-only)
2. **AGENTS.md Hierarchy** — AI-readable documentation for codebase understanding (via deepinit)
3. **PROGRESS.md** — cross-session progress tracking for multi-day work (work log / standup / handoff)

### Quality Gate Details

- Only fires for agent sessions (`AGENT_MODE=1`) — humans pass through freely
- CHECK 1 (Path A): OpenSpec active change directory must exist
- CHECK 2 (Path A): New source files require `features/*.feature` scenarios
- Gate 1: Checks that every new/modified source file has a corresponding test file
- Gate 2: Checks for cross-review evidence (`.agent/reviews/*.md` within 4h) on multi-file logic commits
- Skips trivial changes (no new source files + ≤15 added lines + ≤2 files)
- Composes with existing husky/lefthook if present

### AGENTS.md Details

- Hierarchical documentation with parent references across directories
- Helps agents understand project structure, patterns, and testing requirements
- Preserves manual annotations on re-run (idempotent)

## Workflow

### Step 1: Confirm Target Directory (supports batch mode)

Ask the user which project(s) to initialize:

```
要在哪些项目安装 Agent Quality Gate？（支持多个项目）

默认：[current working directory or detected project path]

可输入多个路径（每行一个），或输入一个目录。
示例：
  ~/Projects/frontend-app
  ~/Projects/backend-api
  ~/Projects/algo-service
```

**Single project mode**: User provides one path → proceed with Steps 2–6 for that project.

**Batch mode**: User provides multiple paths → run Steps 2–6 for each project sequentially:
- Validate each path independently
- Skip already-initialized projects (detect `.githooks/agent-quality-gate.sh` marker)
- Report per-project results, then a combined summary at the end
- If one project fails validation, skip it and continue with the rest (don't abort all)

**Batch summary format:**
```
📋 批量初始化完成 (3/3 成功)

  ✅ ~/Projects/frontend-app — hook + AGENTS.md
  ✅ ~/Projects/backend-api — hook + AGENTS.md  
  ✅ ~/Projects/algo-service — hook (AGENTS.md 已存在，已跳过)
```

Or with partial failure:
```
📋 批量初始化完成 (2/3 成功)

  ✅ ~/Projects/frontend-app — hook + AGENTS.md
  ❌ ~/Projects/legacy-tool — 不是 git 仓库，已跳过
  ✅ ~/Projects/algo-service — hook + AGENTS.md
```

Wait for user confirmation before proceeding. NEVER proceed without explicit confirmation.

### Step 2: Validate Prerequisites

For each target project, verify:

1. Target is a git repository (`[ -d .git ]`)
2. Target has at least one commit (`git rev-parse HEAD`)

If validation fails for a project:
- **Single mode**: Report the issue and stop.
- **Batch mode**: Log the failure, skip this project, continue with the next.

### Step 3: Install Hook

Create `.githooks/agent-quality-gate.sh` with the content from the [Hook Script](#hook-script) section below.

Then integrate based on existing setup:

**If `lefthook.yml` exists:**
```yaml
# Append to lefthook.yml under pre-commit.commands:
  agent-quality-gate:
    run: .githooks/agent-quality-gate.sh
```

**If `.husky/` exists:**
```bash
# Append to .husky/pre-commit:
# AGENT_QUALITY_GATE
.githooks/agent-quality-gate.sh
```

**If neither exists (bare git):**
```bash
ln -sf agent-quality-gate.sh .githooks/pre-commit
git config core.hooksPath .githooks
```

### Step 4: Inject CLAUDE.md Instructions

Append to the project's `CLAUDE.md` (create if not exists):

```markdown
<!-- AGENT_FILES_INDEX -->
## Agent Files

All agent working artifacts live in `.agent/` directory:

| File | Purpose |
|------|---------|
| `.agent/PROGRESS.md` | 开发进度跟踪（跨会话/汇报/工时） |
| `.agent/GATES.md` | 门禁检查清单 |
| `.agent/reviews/` | 交叉审查证据文件（git tracked） |
| `.agent/memory/` | 跨会话记忆（.gitignore） |
| `.agent/plans/` | 实现计划文档 |
| `AGENTS.md` | AI 可读项目文档（项目根） |
| `.githooks/` | Agent pre-commit hook |

New session start: read `.agent/PROGRESS.md` first to restore context.

<!-- AGENT_QUALITY_GATE -->
## Agent Quality Gates

- Before any `git commit`, run: `export AGENT_MODE=1`
- NEVER use `--no-verify` flag unless user explicitly authorizes emergency bypass
- New source files MUST have corresponding test files before commit
- Multi-file logic changes (>1 file, excluding .lock/.md/.json) MUST have cross-review evidence in `.agent/reviews/`
- Run `.githooks/agent-quality-gate.sh` with `AGENT_MODE=1` to preview gate results

<!-- AGENT_PROGRESS_TRACKING -->
## Progress Tracking (Multi-Day Work)

- After completing each todo/task, update `.agent/PROGRESS.md`:
  - Add item to today's "完成" section
  - Update "当前状态" table (phase, test count, build status, latest commit)
  - Move completed items from "待完成" to "完成"
- After each commit, add to "Commit 日志" table
- At end of each work session, update "工时参考" with hours and description
- "排期 vs 实际" table: fill in "实际" column for completed days
- "关键信息" section: keep paths and commands current (especially after branch changes)
- `.agent/PROGRESS.md` is the SINGLE SOURCE OF TRUTH for project status — if in doubt, read it first
```

Skip injection if the marker `AGENT_FILES_INDEX` already exists in the file.
Skip quality gate section if `AGENT_QUALITY_GATE` already exists.
Skip progress section if `AGENT_PROGRESS_TRACKING` already exists.

### Step 5: Create .agent/ Directory & PROGRESS.md

Create the `.agent/` directory structure:

```bash
mkdir -p .agent/memory .agent/plans .agent/reviews
```

Add `.agent/memory/` to `.gitignore` (create if not exists):
```
# Agent session memory (personal, not shared)
.agent/memory/
```

Check if `.agent/PROGRESS.md` already exists:

**If `.agent/PROGRESS.md` does NOT exist:**

Ask the user for project context:
```
为了生成进度跟踪文件，请提供以下信息（可选，留空跳过）：

- 项目名称：[auto-detect from package.json/pom.xml/go.mod or ask]
- 分支名称：[auto-detect from current branch]
- 排期（起止日期）：
- 工作日数：
- 需求/设计文档路径：
```

Then generate `.agent/PROGRESS.md` from the bundled template (`templates/PROGRESS.md`):
- Replace all `{{PLACEHOLDER}}` with actual values
- Auto-fill: branch (from git), worktree path (from pwd), today's date, test/build commands (from package.json scripts or Makefile)
- Leave unfilled placeholders as `TBD` (agent fills during first session)
- Set "当前阶段" to "Phase 0 环境搭建（进行中）"

**If `.agent/PROGRESS.md` already exists:**
- **Single mode**: Note ".agent/PROGRESS.md 已存在，已跳过"
- **Batch mode**: Auto-skip

### Step 5b: BDD Scaffolding (Path A projects)

Detect OpenSpec presence:

```
if [ -d .opencode/skills/openspec-propose ] || \
   [ -d .claude/skills/openspec-propose ] || \
   [ -d openspec/changes ]; then
  # Path A — scaffold BDD
fi
```

**If Path A detected AND `features/` does NOT exist:**

```
检测到 OpenSpec（Path A 项目），正在创建 BDD 脚手架...
```

1. Copy `templates/features/` from agent-gates repo to project root:
   ```
   features/
   ├── example.feature
   └── step_definitions/
       ├── example.steps.ts    (Node.js/TypeScript)
       ├── example_steps.py    (Python)
       └── ExampleSteps.java   (Java)
   ```
2. Keep only the template matching the project's stack (detect from `package.json` → `.ts`, `requirements.txt` / `pyproject.toml` → `.py`, `pom.xml` / `build.gradle` → `.java`). Remove others.
3. If stack is ambiguous, keep all templates and note "请删除不需要的模板".

**If `features/` already exists:** skip, note "features/ 已存在，已跳过".

**If NOT Path A:** skip silently (Path B does not require BDD scaffolding).

### Step 6: Generate AGENTS.md

根据当前 session 所在 platform 选择 hierarchy 生成方式（降级路径）：

**Platform 决策树（5 层降级，越靠前功能越完整）**：

1. **Claude Code session + 装了 OMC plugin**（检测 `~/.claude/plugins/cache/omc/oh-my-claudecode/`）
   → 调用 OMC `deepinit` skill 生成 hierarchical AGENTS.md（多目录嵌套 + parent 引用）

2. **OpenCode session + 装了 OMO 包**（检测 `~/.config/opencode/node_modules/oh-my-openagent-darwin-arm64/` 或类似）
   → 在 session 内执行 `/init-deep`（OMO 提供）生成 hierarchical AGENTS.md

3. **agent-gates 自带的 `init-deep-fallback` skill（跨平台兜底，v1.5.2+）**
   → 任意 platform 上都可用（install.sh 默认安装）
   → 生成 hierarchy 简化版（root + meaningful subdirs + parent 引用）
   → 功能不如 OMC deepinit 完整，但够小到中型项目用

4. **平台原生 `/init`**（Claude Code / OpenCode 都有 builtin）
   → 生成单根 AGENTS.md / CLAUDE.md（无 hierarchy）
   → 当 init-deep-fallback 不可用时（如 skill 没装好）的最后兜底

5. **agent 手写最小根 AGENTS.md**
   → 平台无 /init（如部分 Codex 版本）的最终 fallback
   → 含项目目的 + 主要目录列表 + Agent Workflow 提示

**已存在 AGENTS.md 时**：
- Single mode: 询问 "检测到已有 AGENTS.md。要刷新/更新吗？(y/N)"
  - yes → 走上面决策树（hierarchy 工具会保留 `<!-- MANUAL -->` 段）
  - no → 跳过此步
- Batch mode: 自动跳过，summary 标 "已跳过"

**功能等价说明**：
- v1.5.2 起：agent-gates 自带 `init-deep-fallback` skill，跨平台用户都有 hierarchy 能力
- 装了 OMC/OMO plugin 的用户优先用 plugin 版（功能更全）
- 完整跨平台统一接口未来由 Rampart 基座 `rampart init-deep` 提供（自动路由 OMC / OMO / fallback）

### Step 7 (Optional): CodeGraph Auto-Init Hook

If `codegraph` is installed globally (`command -v codegraph` succeeds), offer the user a one-time shell hook that automatically initializes CodeGraph indexes when entering new git repos:

```
检测到 CodeGraph 已安装。要启用 cd 自动初始化 CodeGraph 索引吗？

开启后，cd 进入项目目录（如 ~/Projects/ 下的 git 仓库）时，
会自动后台运行 `codegraph init -i`（静默、不阻塞 shell）。

已有 .codegraph/ 的项目会跳过。可随时关闭。

启用？(y/N)
```

If user says yes:

1. Check that the hook script exists at `~/.agent-gates/hooks/shell/codegraph-chpwd.zsh` (deployed by `install.sh`). If not, print the manual install command and skip.

2. Add source line to `~/.zshrc` (idempotent — check for marker `# agent-gates: codegraph auto-init` before appending):
```bash
# agent-gates: codegraph auto-init
[[ -f "$HOME/.agent-gates/hooks/shell/codegraph-chpwd.zsh" ]] && source "$HOME/.agent-gates/hooks/shell/codegraph-chpwd.zsh"
```

3. Add the opt-in env var to `~/.zshrc` if not already present:
```bash
export AGENT_GATES_CODEGRAPH_AUTO_INIT=1
export AGENT_GATES_CODEGRAPH_DIRS="$HOME/Projects:$HOME/wb/projects"
```

4. Report:
```
CodeGraph auto-init hook:
  Script: ~/.agent-gates/hooks/shell/codegraph-chpwd.zsh
  Registered in: ~/.zshrc
  Allowed dirs: ~/Projects:~/wb/projects
  To disable: unset AGENT_GATES_CODEGRAPH_AUTO_INIT (or remove from ~/.zshrc)
  To change dirs: export AGENT_GATES_CODEGRAPH_DIRS="dir1:dir2"
```

If `codegraph` is not installed, or user says no — skip silently.

The hook script (`codegraph-chpwd.zsh`) implements these safety guards:
- **Opt-in**: only runs when `AGENT_GATES_CODEGRAPH_AUTO_INIT=1`
- **Directory allowlist**: only triggers under `AGENT_GATES_CODEGRAPH_DIRS` (colon-separated, default `~/Projects:~/wb/projects`)
- **Git repo check**: `[[ -d .git || -f .git ]]` (supports worktrees)
- **Skip if indexed**: `.codegraph/` already exists → no-op
- **Lock file**: prevents duplicate `codegraph init` if already in progress
- **Background**: runs `codegraph init -i` with `& disown`, never blocks the shell

### Step 8: Report Results

**Single project report:**
```
✅ 项目 Agent 初始化完成。

.agent/ 目录:
  .agent/PROGRESS.md: [已创建 / 已存在]
  .agent/memory/: 已创建 (.gitignore)
  .agent/plans/: 已创建

Quality Gate:
  Hook: .githooks/agent-quality-gate.sh (Phase 1: 测试文件对应检查)
  集成方式: [lefthook / husky / core.hooksPath]
  CLAUDE.md: [已注入 / 已存在]

AGENTS.md:
  状态: [已生成 N 个文件 / 已更新 / 已跳过]
  根文件: ./AGENTS.md

CodeGraph:
  状态: [已启用 auto-init / 已跳过 / codegraph 未安装]

使用方式：
  - Agent 正常 commit 即可，hook 自动检查
  - 每完成一个 todo 后更新 .agent/PROGRESS.md
  - 新会话启动先读 .agent/PROGRESS.md 恢复上下文
  - 人类开发者不受影响
```

**Batch report (after all projects processed):**
```
📋 批量初始化完成 (N/M 成功)

  ✅ ~/Projects/frontend-app — .agent/ + hook + AGENTS.md (12 files)
  ✅ ~/Projects/backend-api — .agent/ + hook + AGENTS.md (8 files)
  ✅ ~/Projects/algo-service — hook (.agent/ + AGENTS.md 已存在，已跳过)
  ❌ ~/Projects/legacy — 不是 git 仓库，已跳过

使用方式：Agent 在各项目中正常 commit 即可，hook 自动检查。
人类开发者不受影响。
```

## Hook Script

The following is the complete hook script to write to `.githooks/agent-quality-gate.sh`:

The hook script is maintained in `hooks/git/agent-quality-gate.sh` (v1.5). Copy the latest version from the installed agent-gates repo at `~/.agent-gates/hooks/git/agent-quality-gate.sh`, or from the repo source at `hooks/git/agent-quality-gate.sh`.

The v1.5 gate includes:
- **Path detection**: auto-detects Path A (OpenSpec) vs Path B
- **CHECK 1** (Path A): `openspec/changes/` must have an active change directory
- **CHECK 2** (Path A): new source files require `features/*.feature` scenarios
- **Gate 1**: test file correspondence (all paths)
- **Gate 2**: cross-review evidence (all paths, threshold-triggered)

## Idempotency

This skill is safe to run multiple times on the same project:

- `.agent/` directory: `mkdir -p` is idempotent
- `.agent/PROGRESS.md`: only created if not exists (never overwritten)
- Hook file: overwritten (always gets latest version)
- lefthook/husky injection: checked for existing marker before appending
- CLAUDE.md injection: checked for `AGENT_FILES_INDEX`, `AGENT_QUALITY_GATE`, and `AGENT_PROGRESS_TRACKING` markers before appending
- `.gitignore` entry: checked before appending
- `core.hooksPath`: set is idempotent

## Upgrade Path

When the hook script evolves (Phase 2/3), re-run this skill to update the hook file.
The version number in the script header tracks which phase is installed.

## Relationship to Other Skills

- **deepinit**: This skill invokes `deepinit` for AGENTS.md generation. If `deepinit` skill is not available, falls back to creating a minimal root AGENTS.md only.
- **agent-workflow-rules**: Runtime companion — provides TDD/plan-review/verification discipline during development. `init-project-gates` sets up the project; `agent-workflow-rules` governs how the agent works within it.
- **agent-review-protocol**: Review companion — provides Three-Agent Review, cross-check, and Superpowers enforcement for code review phases.
- **test-driven-development**: The hook enforces TDD by requiring test files to exist before commit.

---
name: init-project-gates
description: "One-command project initialization for agent-assisted development. Installs quality gate pre-commit hook, generates AGENTS.md, creates PROGRESS.md for multi-day tracking. Supports batch mode. Use when setting up projects for agents, or when user says 'init project', 'install gates', 'setup quality gate', 'init gates', '装门控', '初始化门控', '初始化项目', 'init for agents', '批量初始化', 'init all projects'."
---

# Init Project Gates

## Overview

One-command setup for agent-assisted development in any project:

1. **Quality Gate Hook** — pre-commit hook enforcing test file correspondence (agent-only)
2. **AGENTS.md Hierarchy** — AI-readable documentation for codebase understanding (via deepinit)
3. **PROGRESS.md** — cross-session progress tracking for multi-day work (PingCode / standup / handoff)

### Quality Gate Details

- Only fires for agent sessions (`AGENT_MODE=1`) — humans pass through freely
- Checks that every new/modified source file has a corresponding test file
- Skips trivial changes (no new source files + ≤15 added lines + ≤2 files)
- Composes with existing husky/lefthook if present

**Phase 1** (current): Test file correspondence only.
Future phases add BDD `.feature` checks and OpenSpec change record checks.

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
| `.agent/PROGRESS.md` | 开发进度跟踪（跨会话/汇报/PingCode） |
| `.agent/GATES.md` | 门禁检查清单 |
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
- Run `.githooks/agent-quality-gate.sh` with `AGENT_MODE=1` to preview gate results

<!-- AGENT_PROGRESS_TRACKING -->
## Progress Tracking (Multi-Day Work)

- After completing each todo/task, update `.agent/PROGRESS.md`:
  - Add item to today's "完成" section
  - Update "当前状态" table (phase, test count, build status, latest commit)
  - Move completed items from "待完成" to "完成"
- After each commit, add to "Commit 日志" table
- At end of each work session, update "PingCode 工时参考" with hours and description
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
mkdir -p .agent/memory .agent/plans
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

### Step 6: Generate AGENTS.md Hierarchy (deepinit)

Check if root `AGENTS.md` already exists in the project:

**If AGENTS.md does NOT exist:**
```
正在生成 AGENTS.md 层级文档...
```
Invoke the `deepinit` skill workflow:
1. Map directory structure (exclude node_modules, .git, dist, build, etc.)
2. Create AGENTS.md files level-by-level (parent before children)
3. Include: purpose, key files, subdirectories, AI agent instructions, testing requirements
4. Add parent references (`<!-- Parent: ../AGENTS.md -->`) for hierarchy navigation

**If AGENTS.md already exists:**
- **Single mode**: Ask "检测到已有 AGENTS.md。要刷新/更新吗？(y/N)"
  - If user says yes → run deepinit in update mode (preserves `<!-- MANUAL -->` sections)
  - If user says no → skip this step
- **Batch mode**: Auto-skip (don't prompt for each project, just note "已跳过" in summary)

### Step 7: Report Results

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

```bash
#!/usr/bin/env bash
# Agent Quality Gate v1 (Phase 1 — test correspondence only)
# Only fires when AGENT_MODE=1; human developers pass through.
# Version: 1.0.0

set -euo pipefail

[[ "${AGENT_MODE:-0}" != "1" ]] && exit 0

FAILED=0
fail() { echo "❌ GATE: $1"; FAILED=1; }

NEW_SOURCE=$(git diff --cached --diff-filter=A --name-only | grep -E '\.(ts|tsx|js|jsx|py|java|kt|go)$' | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.)' || true)
DIFF_LINES=$(git diff --cached --stat | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
CHANGED_COUNT=$(git diff --cached --name-only --diff-filter=ACMR | wc -l | tr -d ' ')

if [[ -z "$NEW_SOURCE" && "$DIFF_LINES" -le 15 && "$CHANGED_COUNT" -le 2 ]]; then
  exit 0
fi

echo "🔍 Agent Quality Gate ($CHANGED_COUNT files, +${DIFF_LINES} lines)"

for f in $(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(ts|tsx|js|jsx|py|java|kt|go)$' | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.|\.d\.ts$|config)'); do
  case "$f" in
    *.ts|*.tsx|*.js|*.jsx)
      t1="${f%.*}.test.${f##*.}"; t2="${f%.*}.spec.${f##*.}" ;;
    *.py)
      dir=$(dirname "$f"); base=$(basename "$f" .py)
      t1="${dir}/test_${base}.py"; t2="${dir}/${base}_test.py" ;;
    *.java|*.kt)
      t1=$(echo "$f" | sed 's|/main/|/test/|;s|\.\(java\|kt\)$|Test.\1|'); t2="" ;;
    *.go)
      t1="${f%.go}_test.go"; t2="" ;;
    *) continue ;;
  esac

  if [[ ! -f "$t1" ]] && [[ -z "$t2" || ! -f "$t2" ]]; then
    fail "No test for: $f → expected: $t1"
  fi
done

if [[ "$FAILED" -eq 1 ]]; then
  echo ""
  echo "❌ Agent Quality Gate FAILED."
  echo "   Fix: write corresponding test files before committing."
  exit 1
fi

echo "✅ Agent Quality Gate PASSED"
```

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
- **waza-check**: The quality gate hook works alongside waza-check for pre-merge review.
- **test-driven-development**: The hook enforces TDD by requiring test files to exist before commit.
- **pingcode-log**: PROGRESS.md "PingCode 工时参考" section feeds directly into daily work logging.

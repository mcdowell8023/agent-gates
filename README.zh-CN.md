# Agent Gates

[English](./README.md) | **中文**

为 AI 编码 agent 提供运行时质量门控。一次安装即可让团队获得 TDD 强制、交叉审查证据检查、记忆持久化提醒、进度跟踪 —— 覆盖 Claude Code、OpenCode、Codex。

> 📖 **中文整体说明**（问题、架构、与 agent-superpowers / OpenSpec 的关系、使用方式、含 mermaid 图）：[docs/explainer.zh.md](./docs/explainer.zh.md)

## 架构

```
agent-gates/
├── skills/                          # Agent skills（被各平台自动加载）
│   ├── agent-workflow-rules/        # TDD、计划审查、验证、防环
│   ├── agent-review-protocol/       # 三 Agent 评审、交叉检查流水线
│   └── init-project-gates/          # 项目初始化器（一次性设置）
├── hooks/
│   ├── git/
│   │   └── agent-quality-gate.sh    # Pre-commit：测试对应 + 审查证据
│   └── platform/
│       └── memory-reminder.mjs      # PostToolUse：Memory 持久化强制
├── templates/
│   └── .agent/                      # 项目目录模板
└── install.sh                       # 多平台安装器
```

## Prerequisites（用户需要预先安装）

运行 `./install.sh` **之前**你必须自己安装：

| 工具 | 必须 / 可选 | 用途 |
|------|-----------|------|
| Node.js ≥ 18 | **必须** | 运行 `memory-reminder.mjs`（ES modules + `node:fs`） |
| `git` 或 `curl` | **必须** | 安装器拉取本仓库；上游 skill 自动安装走 `git clone` |
| `jq` | 强烈推荐 | 把 agent-gates 条目合并进平台的 `hooks.json`；没有时安装器降级为打印手动 JSON 指令 |
| 至少一个 agent 平台 | 推荐 | Claude Code / OpenCode / Codex / cc-switch —— 安装器自动检测，都不存在时回退到 `~/.claude/skills/` |
| `npm`（随 Node.js 一起装） | 可选 | 仅当你想让安装器自动装 OpenSpec CLI 时需要 |

**安装路径约束**：`$HOME` 不能含空格 —— shell hook 转义不可靠。

## Auto-Installed Dependencies（agent-gates 默认帮你装，v1.5.2+）

跑 `./install.sh` 后自动完成下列步骤（已装的会 skip）：

| 依赖 | 默认行为 | 来源 | 影响 |
|---|---|---|---|
| **agent-gates 自带 4 个 skill**<br>`agent-workflow-rules` / `init-project-gates` / `agent-review-protocol` / `init-deep-fallback`（v1.5.2 新） | 复制到检测到的 platform skills 目录 | 本仓库 | 核心工作流规则 |
| **Memory skill** | sparse-clone `clawic/skills` 的 `skills/memory/` 子目录 | [clawic/skills](https://github.com/clawic/skills)（MIT） | `memory-reminder.mjs` hook 提醒 agent 调用此 skill 持久化会话 |
| **agent-superpowers 14-skill 套件**<br>(test-driven-development / brainstorming / verification-before-completion / writing-plans / executing-plans + 9 个支撑 skill) | 全量 clone 上游仓库到 platform skills 目录 | [obra/superpowers](https://github.com/obra/superpowers) | `agent-workflow-rules` 的 TDD / 计划 / 审查 / 调试规则依赖这些上游 skill |
| **OpenSpec CLI**（可选） | **交互式 y/N 提示，默认 N**；只有显式同意才会 `npm install -g @openspec/cli` | [@openspec/cli](https://www.npmjs.com/package/@openspec/cli) | Path A（OpenSpec 驱动的团队项目）需要 |
| **平台 hook 注册** | 把 PostToolUse 条目写入 `~/.claude/settings.json` / `~/.config/opencode/hooks.json` / `~/.codex/hooks.json` 中**已检测到**的平台 | install.sh 自动 | `memory-reminder.mjs` 在 todo 完成时触发 |

**opt-out**：`./install.sh --skip-deps` 跳过所有外部依赖 —— agent-gates 自身的 skill 和平台 hook 仍会安装。即使缺这些依赖，agent-gates 依然能跑 —— Path B（只用 TDD，没有 OpenSpec / 没有 BDD）是默认形态，`doctor.sh` 把缺的部分报为信息性 `note` 而不是 `FAIL`。

## Installation

**一键安装**（推荐）：

```bash
curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash
```

**或从仓库安装**：

```bash
git clone https://github.com/mcdowell8023/agent-gates.git
cd agent-gates
./install.sh
```

**可选 flag**：

- `--skip-deps` —— 不安装外部 skill 依赖（Memory / Superpowers / OpenSpec）
- `--with-openspec` —— 仅检测 OpenSpec CLI 是否存在（不自动安装），与默认 y/N 询问互斥
- `--codegraph-hook` —— 额外注册 zsh `chpwd` hook，cd 进 git 仓时自动跑 `codegraph init -i`
- `--skip-hooks` —— 跳过平台 hook 注册
- `--upgrade` / `--force` —— 版本相同也强制重装

**升级**：

```bash
./install.sh --upgrade
```

**卸载**：

```bash
./uninstall.sh
```

## Usage

### 初始化一个项目

在你的项目目录里，在 agent platform 的 session 中说：

```
初始化项目
```

或英文：

```
init project gates
```

`init-project-gates` skill 会自动执行：

1. 检测项目类型（Path A：含 OpenSpec / Path B：无 OpenSpec）
2. 把 `agent-quality-gate.sh` 装到 `.githooks/`
3. 跑 `git config core.hooksPath .githooks`
4. 生成 `.agent/PROGRESS.md`
5. 生成 `AGENTS.md`（hierarchy 取决于可用工具，详见 Step 6 决策树）
6. 注入项目级规则到 `CLAUDE.md`

### 日常使用

agent 在 session 内开发时，agent-gates 自动：

- **每完成一个 todo**：`memory-reminder.mjs` 提示 agent 通过 Memory skill 存档
- **每次 commit 前**：`agent-quality-gate.sh` 检查测试对应 / 交叉审查证据 / OpenSpec change / `.feature` 文件
- **Skill 加载**：`agent-workflow-rules` / `agent-review-protocol` / `init-deep-fallback` 按需触发

### 健康检查

```bash
~/.agent-gates/doctor.sh           # 完整检查
~/.agent-gates/doctor.sh --quiet   # 只显示 PASS/WARN/FAIL 摘要
~/.agent-gates/doctor.sh --no-network  # 离线模式，跳过远端版本比对
```

## What's Included（装好的内容）

### Skills

| Skill | 用途 | 激活方式 |
|-------|------|--------|
| `init-project-gates` | 项目设置：hook + `.agent/` 目录 + AGENTS.md | 手动："init project" |
| `agent-workflow-rules` | TDD、计划审查、验证、调试 | 代码任务自动加载 |
| `agent-review-protocol` | 三 Agent 评审流水线、交叉检查 | 审查阶段触发 |

### Hooks

| Hook | 类型 | 触发时机 | 强制内容 |
|------|------|--------|--------|
| `agent-quality-gate.sh` | Git pre-commit | Agent commit（`AGENT_MODE=1`） | 测试文件 + 审查证据 |
| `memory-reminder.mjs` | 平台 PostToolUse | todo 标记 completed | Memory skill 存档提醒 |

### 约定：`.agent/` 目录

```
.agent/
├── PROGRESS.md      # Sprint 跟踪、决策、阻塞（git 跟踪）
├── GATES.md         # 质量门控清单（git 跟踪）
├── reviews/         # 交叉审查证据文件（git 跟踪）
├── plans/           # 实现计划（git 跟踪）
└── memory/          # 会话记忆（.gitignored）
```

## Supported Platforms（支持平台）

| 平台 | Skills 位置 | Hook 注册 | Schema |
|------|------------|----------|--------|
| Claude Code (OMC) | `~/.claude/skills/` | `~/.claude/settings.json` → `.hooks.PostToolUse[]` | 需要已存在的 `settings.json`（先启动 Claude Code 一次） |
| Claude Code + OMO | `~/.config/opencode/skills/`（优先），`~/.claude/skills/`（回退） | 由上面 OMC 注册覆盖 —— OMO 在 Claude Code 上运行时读取 `~/.claude/settings.json` 的 PostToolUse hooks | 同 OMC |
| OpenCode（OMO native） | `~/.config/opencode/skills/` | **v1.5.2 自动注册**到 `~/.config/opencode/hooks.json` `.hooks.PostToolUse[]`（复用 OMC/OMX 的 `register_hook` jq 逻辑） | 嵌套 schema（与 OMC/OMX 同形） |
| Codex (OMX) | `~/.codex/skills/` | `~/.codex/hooks.json` → `.hooks.PostToolUse[]` | 嵌套 schema，文件不存在时安装器创建 |
| cc-switch | `~/.cc-switch/skills/` + 软链 | 合并上面 OMC + OMX | — |

安装器使用的 PostToolUse matcher 是 `TodoWrite|todowrite|TaskUpdate|TaskCreate`，覆盖 legacy 的 `TodoWrite` 工具名以及 Claude Code 当前的 `TaskUpdate` / `TaskCreate` 工具。

> **OMO 在 Claude Code 上运行**：[oh-my-openagent](https://github.com/Yeachan-Heo/oh-my-claudecode)（OMO）是跨平台的 —— 可以跑在 Claude Code、OpenCode、Codex 等之上。当 OMO 跑在 Claude Code 上时，它读取 `~/.claude/settings.json` 的 PostToolUse hooks，所以 agent-gates 已有的 OMC 注册自动覆盖这种场景。OMO 自身的生命周期 hook 与 Claude Code 原生 hook 共存。Skill 双源解析：先 `~/.config/opencode/skills/`，再 `~/.claude/skills/`。

## How It Works（工作原理）

### Git 质量门控（仅 agent）

pre-commit hook 只对 agent session（`AGENT_MODE=1`）生效。人类开发者畅通无阻。

**CHECK 1 — OpenSpec Change**（仅 Path A）：`openspec/changes/` 必须包含一个活跃的 change 目录。

**CHECK 2 — BDD Scenarios**（仅 Path A）：新增源码文件要求至少存在一个 `features/*.feature` 文件。

**Gate 1 — Test Correspondence**：每个新源码文件必须有对应的测试文件。

**Gate 2 — Cross-Review Evidence**：当 commit 超过阈值（`LOGIC_FILES > 1 AND DIFF > 50` 或 `SINGLE_FILE > 150 行`），要求 `.agent/reviews/` 内存在 `VERDICT: PASS` 的审查文件。

### Memory 持久化提醒

当 agent 把一个 todo 标为 completed 时，平台 hook 注入一条 system reminder 提示通过 Memory skill 保存关键产出 —— 防止会话知识丢失（红线 #12 强制）。

### 工作流规则（运行时）

- TDD 优先：写失败测试 → 实现 → 验证
- 计划审查门控：大型实现前必须经过审查
- 防环：修复尝试最多 2 次后升级
- Verification-before-completion：声称完成前必须有证据

### 工作流路径：A（OpenSpec）vs B（无 OpenSpec）

Agent Gates 支持两种工作流路径，按项目自动检测：

| | Path A（团队项目） | Path B（个人 / 无 OpenSpec） |
|---|---|---|
| 触发条件 | 存在 `.opencode/skills/openspec-propose/` 或 `.claude/skills/openspec-propose/` 或 `openspec/changes/` | 否则 |
| 计划 | `opsx:explore` → `opsx:propose`（生成 `proposal.md` + `specs.md` + `tasks.md`） | `brainstorming` skill → `writing-plans` skill |
| 验收 | `features/*.feature`（Gherkin）从 `specs.md` 引用；每个 `tasks.md` 步骤关联一个 scenario | 计划步骤打 RED / GREEN / REFACTOR 标签 |
| 实现 | `opsx:apply`（BDD-TDD：step-defs 先行） | `test-driven-development` skill |
| Pre-commit 门控 | `AGENT_MODE=1` 下 4-CHECK（OpenSpec change + `.feature` + 测试对应 + 测试通过） | `AGENT_MODE=1` 下测试对应 + 交叉审查证据 |
| Review | Spec Reviewer → Quality Reviewer → CLI gate → `opsx:archive` | `.agent/reviews/` 内的交叉审查证据 |

两条路径都共享 `agent-workflow-rules` skill 作为 TDD、计划审查、验证、防环规则的唯一权威源。Path A 在其上叠加 OpenSpec（L1 需求）和 BDD（L2 验收）；Path B 只用 TDD。

`doctor.sh` 报告当前工作目录适用哪条路径（`check_openspec_install` + `check_bdd_features_dir`）。

## BDD Quick Start（Path A 快速上手）

如果你的项目使用 OpenSpec（存在 `openspec/changes/`），质量门控会强制要求 BDD scenarios：

1. **在 `features/` 创建 `.feature` 文件**：
   ```gherkin
   Feature: User registration

     Scenario: Register with valid email
       Given an unregistered email "new@example.com"
       When the user submits a registration request
       Then the system returns 201
       And the response contains a user ID
   ```

2. **在 `features/step_definitions/` 写 step definitions**：
   ```typescript
   // features/step_definitions/user-registration.steps.ts
   import { Given, When, Then } from "@cucumber/cucumber";

   Given("an unregistered email {string}", function (email: string) {
     this.email = email;
   });

   When("the user submits a registration request", async function () {
     this.response = await register(this.email);
   });

   Then("the system returns {int}", function (status: number) {
     expect(this.response.status).toBe(status);
   });
   ```

3. **用 `AGENT_MODE=1` commit** —— 门控会校验：
   - CHECK 1：存在活跃的 `openspec/changes/<name>/` 目录
   - CHECK 2：新增源码文件时至少有一个 `features/*.feature` 文件
   - Gate 1：测试文件对应（不变）
   - Gate 2：交叉审查证据（不变)

TypeScript、Python、Java 的模板打包在 `templates/features/` 中。

## OpenSpec Integration（OpenSpec 集成）

带 `--with-openspec` 安装时，安装器检查 OpenSpec CLI：

```bash
./install.sh --with-openspec
```

它确认 PATH 上有 `openspec`，没有时打印安装指引。从 v1.5.2 起，默认的 `./install.sh` 流程在 CLI 缺失时已经会提示（y/N）跑 `npm install -g @openspec/cli` —— `--with-openspec` 保留用于显式声明。传 `--skip-deps` 可以彻底压制提示。

一旦项目中 OpenSpec 设置好，工作流变成：

```
opsx:explore → opsx:propose（生成 specs + .feature） → plan-review
  → opsx:apply（BDD-TDD：step-defs 先行） → cross-review → opsx:archive
```

完整流程见 `agent-workflow-rules` §3（Path A）和 §5（OpenSpec Workflow）。

## Upgrade（升级）

重新跑安装器；同一条命令既能首次安装也能升级：

```bash
curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash
```

升级时安装器会：

- 把已安装的 `.version` 和仓库的对比；**版本相同时跳过**（用 `--force` 或 `--upgrade` 强制重装）。
- 在覆盖前**备份本地修改过的 `SKILL.md`** 为 `SKILL.md.bak.<timestamp>`，并在最终摘要里列出。
- **幂等 hook 注册**：已有的 `hooks.json` 通过 `jq` 合并且去重。如果缺 `jq`，安装器打印安装命令以及要手动加进去的 JSON 条目。

### 升级时需要知道的限制

- **项目级 hook 不会自动升级。** 每个项目的 `.githooks/agent-quality-gate.sh`（pre-commit 软链指向它）是 `init-project-gates` 一次性复制过来的。全局升级 agent-gates 后，需要在每个已初始化的仓库重新跑 `init project gates` 以同步最新 hook。
- **备份会累积。** 每次检测到用户修改的升级都会留一个新的 `SKILL.md.bak.*` 文件。合并完编辑后跑 `./uninstall.sh --purge-backups`（如果只想清备份就配合 `--keep-skills`）来移除它们。
- **OMO native（OpenCode）的 hook 注册是手动的。** 安装器检测到 `~/.config/opencode/` 时，打印要加到 `~/.config/opencode/hooks.json` `.hooks.PostToolUse[]` 下的 JSON 条目。`doctor.sh` 检查同样的路径/schema；如果它报告 OMO hook 缺失，请手动添加（完整 JSON 形态见 `docs/platform-hooks.md` → OMO）。注意：如果你的 OMO 跑在 Claude Code 上（而不是 OpenCode），OMC 的 `settings.json` 注册已经覆盖你 —— 无需手动步骤。
- **不自动迁移 skill。** 如果未来某个版本重命名或重构了 skill 目录，你可能需要手动清理旧布局 —— 安装器只更新已知名字的 skill。

## Doctor（健康检查）

安装后跑 `~/.agent-gates/doctor.sh`（或在仓库内跑 `./doctor.sh`）来验证部署健康度：

```bash
~/.agent-gates/doctor.sh
```

示例输出（理想 Path A：OpenSpec 已装 + ≥1 个 `.feature` + transcripts 干净）：

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
✓ BDD step_definitions/ has 3 step file(s)

14 pass · 0 warn · 0 fail
```

在默认的 Path B 项目（无 OpenSpec、无 `features/`）里，最后三行变成信息性 `note` 而不是 PASS，所以典型输出是 **11 PASS + 3 note**（不是 14 PASS）。`note` 表示"不适用 / 未配置"，不是"坏了"。

退出码 **没有 FAIL 时为 0**（允许 WARN），**有 FAIL 时为 1**，所以脚本可以接入 CI：

```bash
~/.agent-gates/doctor.sh --quiet --no-network && echo "deployment OK"
```

| Flag | 效果 |
|---|---|
| `--quiet` | 抑制 dim/info notes；只显示 PASS/WARN/FAIL 表格 |
| `--no-network` | 跳过远端 `.version` 检查（离线模式） |
| `--help` | 用法 |

Doctor 检查的范围与 install / uninstall 脚本一致（路径、注册、schema）。某项 FAIL 时，信息里会带一行修复提示，指回 `install.sh` 或本 README 的 Troubleshooting 章节。

## Troubleshooting（故障排查）

| 症状 | 可能原因 | 修复 |
|---|---|---|
| `node not found` | Node.js 缺失或不在 PATH | 装 Node.js ≥18：https://nodejs.org/ |
| `node ≥18 required (found vXX)` | Node 版本太旧 | 升级 Node（例如 `nvm install 20`，或你的包管理器） |
| `jq not found for safe merge` | 已存在 `hooks.json` 但 `jq` 缺失 | 按安装器打印的命令装（`brew install jq` / `apt-get install jq` 等），再重跑 |
| `Install path contains spaces` | `$HOME` 含空格 | 用不含空格的 home 路径；shell hook 无法可靠转义 |
| `No memory* skill found` 警告 | 没装 Memory skill | 在打印出的候选 skills 目录任一处装一个 memory skill；没有的话提醒还是会触发但没目标 skill 可调 |
| Hook 触发了但好像没动作 | Memory skill 缺失，或 agent 忽略了提醒 | 确认 Memory skill 已装；检查 agent platform 是否真的执行了 `PostToolUse` hooks |
| 升级后 skill 行为没变 | 项目级 hook 没刷新 | 在受影响的仓库里重新跑 `init project gates` |
| `hooks.json` 有重复条目 | 手动编辑 + 安装器多次重跑 | `./uninstall.sh` 然后重装，恢复干净状态 |
| 想回滚某次 skill 改动 | 想找上一版 SKILL.md | 在该 skill 目录里找 `SKILL.md.bak.<timestamp>` |

## Relationship Between Components（组件关系）

```
init-project-gates          ─── 设置项目 ───►  .agent/ + hook
       │
       │ 运行时伴侣
       ▼
agent-workflow-rules        ─── 管控 agent 如何工作 ───►  TDD / 验证
       │
       │ 审查强制
       ▼
agent-review-protocol       ─── 交叉检查流水线 ───►  .agent/reviews/
       │
       │ 持久化强制
       ▼
memory-reminder.mjs         ─── 平台 hook ───►  Memory skill 存档
```

## License

MIT

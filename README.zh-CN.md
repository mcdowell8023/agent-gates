# Agent Gates

[English](./README.md) | **中文**

为 AI 编码 agent 提供运行时质量门控。一次安装即可让团队获得 TDD 强制、交叉审查证据检查、记忆持久化提醒、进度跟踪 —— 覆盖 Claude Code、OpenCode、Codex。

> 📖 **中文整体说明**（问题、架构、与 agent-superpowers / OpenSpec 的关系、使用方式、含 mermaid 图）：[docs/explainer.zh.md](./docs/explainer.zh.md)

## 架构

```
agent-gates/
├── lib/hetero/                      # v2.0.0 hetero-check 子系统
│   ├── config.sh                    # 配置加载（env > json > legacy > default）
│   ├── select.sh                    # 模型选择 + effort + 风险分级
│   ├── dispatch.sh                  # 五通道 dispatch + 进程组 spawn + fail-closed
│   ├── serve.sh                     # 共享 opencode serve + .draining 锁
│   └── janitor.sh                   # 生命周期：measure + budget + recycle + circuit-breaker
├── skills/                          # Agent skills（被各平台自动加载）
│   ├── agent-workflow-rules/        # TDD、计划审查、验证、防环
│   ├── agent-review-protocol/       # 三 Agent 评审、交叉检查流水线
│   ├── init-project-gates/          # 项目初始化器（一次性设置）
│   ├── init-deep-fallback/          # 跨平台 AGENTS.md hierarchy 兜底（v1.5.2+）
│   └── memory/                      # Memory skill，bundled 自 clawic/skills（MIT，v1.5.4+）
├── hooks/
│   ├── git/
│   │   └── agent-quality-gate.sh    # Pre-commit：CHECK 1-6（测试 + 审查 + Verifier）
│   └── platform/
│       └── memory-reminder.mjs      # PostToolUse：Memory 持久化强制
├── templates/
│   ├── verifier.md                  # v2.0.0 Verifier 自定义 agent 配置
│   └── .agent/                      # 项目目录模板
├── bin/
│   ├── agent-gates-verify-ack       # v2.0.0 USER_ACK 写入（diff-hash 绑定）
│   ├── agent-gates-verify-strip     # v2.0.0 从 agent 输出剥离 USER_ACK
│   ├── agent-gates-config-migrate   # v2.0.0 Config v1→v2 迁移
│   ├── oc-review                    # opencode 交叉审查 + 重试 + fail-closed
│   └── oc-reaper                    # 清理孤儿 opencode serve 进程
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
| **Memory skill** | **v1.5.4 起内置（bundled）** —— agent-gates 仓自带 `skills/memory/`，install 时直接 cp 到 platform skills 目录。已装则 skip，无网络依赖。 | fork 自 [clawic/skills](https://github.com/clawic/skills)（MIT），同步备注详见 `skills/memory/UPSTREAM.md` | `memory-reminder.mjs` hook 提醒 agent 调用此 skill 持久化会话 |
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

## 新特性

### v2.2.0 — pi 通道 + 三层空转判据

**新增 `pi` 通道，排在 opencode 之前。** 顺序变为
`paseo → pi → opencode → codex → codebuddy → echo-fallback`。

`pi` 是 one-shot：`--help` 里没有 serve / daemon / port 任何子命令，`-p` 处理完即退出。
`opencode` 需要常驻 `opencode serve`，而 Paseo 驱动它时**每个 agent 起一个独立 serve**，
实测 1-1.5GB RSS 且 agent idle 后不回收。实测（审查一个含真 bug 的 JS 文件）：

| 通道 | 耗时 | 峰值 RSS | 跑完残留 |
|---|---|---|---|
| pi `github-copilot/gpt-5.4` | 29.9s | 197MB | 零 |
| pi `volcengine-coding/deepseek-v4-flash` | 12.7s | 216MB | 零 |
| opencode 共享 serve `:4096`（`--attach`） | — | 619MB 常驻 | 1 个，受 oc-review 管 |
| opencode Paseo 托管 | — | 1-1.5GB / 个 | 不回收 |

⚠️ 这张表要看清：共享 serve 那一行是**健康**的（3h10m 均值 5% CPU）。烧机器的从来不是
「用 opencode 审查」，而是**每次调用新起一个 serve**。`oc-review` v1.13.0 的 `--attach`
已经消掉了 per-run 堆叠——绕过它的调用**跑第一次就漏一个约 1GB 的 serve**，与调用频次无关。

用 `HETERO_PI_MODEL=<provider>/<model>` 配置。**不配则该通道静默让路**、路由完全不变——
加通道不能悄悄改掉既有安装的路由。

**`oc-reaper` 的空转检测改为 per-serve 三层判定。** 旧门控问 Paseo「有没有任何 opencode
agent 在 running」，只要有一个，就对**所有** Paseo 托管的 serve 关闭空转检测。现场实测失效：
一个 running agent 保护了 6 个已废弃的 serve，其中 3 个各烧 52-86% CPU；把
`OC_REAPER_SPIN_CPU` 降到 30 仍是 `0 reapable`——挡住它的是门控，不是阈值。

```
层1  有工作子进程（排除 lsp-daemon）        → 在干活，任何 CPU 都保留
层2  无工作子进程 + CPU 低                  → 空闲无害，保留
层3  无工作子进程 + CPU 高 + 主线程 ≥95%
     采样卡在 kevent64                      → 证明是 GC 空转，才清
```

三层都不能省。**层1 不能省**：等 `jest` 子进程的 serve 主线程同样 100% 卡在 `kevent64`，
所以「主线程 kevent64 即空转」**单独使用是错的判据**——当天差点据此杀掉一个已跑 40 分钟的
测试。**层3 不能省**：纯 JS 重计算也符合「无子进程 + 高 CPU」，只有采样能区分 GC 与 JS
（一个 100% CPU 的 `yes` 进程会被正确放过）。`sample` 缺失或失败一律保留——无法证明就不动手。

同时修复：`oc-reaper` 不再清掉 agent-gates 自己的共享 serve。`KEEP_PORT` 原本默认为空，
而 `OC_REVIEW_PORT` 平时不设置，于是 4096 没被识别为受保护端口，那个持久共享 serve 被当作
泄漏回收（实测 age 38051s 被清）。

### v2.1.0 — 门禁不再卡死自己人

真实反馈：并发开发多条线时，门禁成了阻塞项。一条任务在 verify 上耗了两天，而卡它的三件事**全是 agent-gates 自己的缺陷**。

- **「伪造证据」与「用户授权放行」分开。** 伪造仍然禁止；用户明确授权的放行是**合法路径** —— `SKIP_VERIFY=1`、`SKIP_REVIEW=1`、`agent-gates-verify-ack`（用户授权后 agent 可代跑）。三个条件都关于**如实**，不关于权限。gate 的 `INCOMPLETE` 提示现在直接打印命令，而不是那句什么都没说的 "confirm via workflow" —— 后者逼每个 agent 重新推导机制、再向用户解释一遍才能动。
- **不规定通道，只规定证据。** `--import-result` 接受任意来源的审查：`--paseo-agent <id>` 会核实异构 Paseo agent，`--imported-model <id>` 则声明来源并标 `unverified`。两种形式的锚点保证完全相同。新增两阶段流程：`--route paseo --dispatch-out` 捕获锚点 + 快照 prompt（退出码 77），调用方走 MCP 派发，结果经原子 claim 导入。
- **修了三处「回执写得漂亮、事情没发生」** —— `HETERO_OC_MODEL` 此前**根本没有定义**，verify 实际执行 `opencode run -m ""`，它挂起而非失败、只留 0 字节 evidence；paseo channel 为从未启动的 agent 写 `capability=FULL`（其 CLI 是 Electron 应用本体、headless 跑不起来，而 spawn 从不等退出码）；`install.sh` 永远 clone 远程 main 却显示**本地**版本号，本地改动根本装不上 —— 现在 `--local` 从当前 checkout 安装。
- **`oc-reaper` 不再永久保留泄漏的 serve。** 「端口有 ESTABLISHED 连接」排在「有没有真实 `opencode run` 客户端」之前，而 Paseo 托管的 serve 与 daemon 的连接永不断开 ⇒ 该信号永远为真。实测两个 serve 存活 23 小时、全机零个客户端，`--apply` 一个都没回收。

### v2.0.2 — 审查失败会说清到底哪里出了问题

`HETERO_EXHAUSTED: all review models failed` 被用于五种互不相关的失败。其中占比最高的那种——模型答了但没有行首 `VERDICT:` 行——读起来像通道故障，害得排查花一整天去追一个并不存在的 `--format json` 挂死。

- 每种失败各自报告：`review-fail[<model>]:` 点名模型与原因，缺结论行时还会引用模型自己的原话。
- 结论行匹配容忍常见 markdown（`**加粗**`、`##`、列表项、引用、反引号、缩进、中文冒号），但要求该行**只承载取值** —— `PASS_WITH_ISSUES` 这类带限定词的结论会让结果反转，一律拒绝。
- 所有审查调用都由 `with-timeout.mjs` 限时（`AG_REVIEW_TIMEOUT`，默认 300s）。这个 wrapper 自 v1.x 就存在却**零调用点**；现在它还会杀整个进程组——只杀直接子进程时，孙子进程仍持有继承来的 stdout，超时等于没做。
- hetero 分支可落回 codex（`fallback_route` 此前是死配置），并用 `oc_serve_ensure` 自愈共享 serve，而不只是探测它。

### v2.0.0 — hetero-check 子系统 + Verifier 角色（BREAKING）

**BREAKING**：`lib/review-selection.sh` → `lib/hetero/select.sh`（兼容 shim 保留一个 minor 周期）；`review-capability.json` → `hetero-check.json`（`agent-gates-config-migrate` 自动转换）。

**hetero-check 子系统**（`lib/hetero/`）：命名结构化子系统，整合原先散落在 oc-serve、D6 doctor、Gate 2b、reaper 中的逻辑。

- **五通道 dispatch**：Paseo → opencode（fail-closed）→ codex → codebuddy → claude-agent，自动注入 effort（`--variant` / `--thinking` / `-c model_reasoning_effort`）并基于 `is_high_risk_path` 进行风险分级。
- **资源生命周期层**：进程组 spawn（`setsid` / `perl POSIX::setsid()`，兼容 macOS）+ PGID kill（非 `pkill -P`）+ `.draining` TOCTOU 锁 + wall-clock watcher + circuit-breaker 含冷启动检测 + `HETERO_SPAWNED` 归因。防止两起真实 OOM 事故重现（opencode serve 叠加 2.7 GB；codebuddy --acp 崩溃循环 12.5 GB）。
- **配置**：`hetero-check.json` 含生命周期预算、effort 分级、通道开关——全部可通过环境变量覆盖。

**Verifier 角色**：Writer + Reviewer 通过后的黑盒产品验收。

- `templates/verifier.md`：Claude Code custom agent 配置——以用户视角运行产品、报告问题，**永不修改代码**。
- **CHECK 6** pre-commit 门控：四态裁决（PASS / FAIL / QUESTIONS / INCOMPLETE）。FAIL 阻断；QUESTIONS/INCOMPLETE 需要 `USER_ACK`（人工通过 `agent-gates-verify-ack` 确认，绑定 `staged-diff-hash + HEAD`）。高风险路径要求 FULL 能力（Paseo agent）；EVIDENCE_ONLY 通道对高风险路径强制降级为 INCOMPLETE。
- `bin/agent-gates-verify-ack`：人工确认后写入 `.ack` 文件，含 `AGENT_MODE` 防守。
- `bin/agent-gates-verify-strip`：从 verifier 输出中剥离 `USER_ACK` 标记（纵深防御）。
- `.agent/verify/` 目录：与 `.agent/reviews/` 隔离，防止 CHECK 5/6 交叉污染。

**迁移**：`bin/agent-gates-config-migrate` 转换 v1 → v2 配置。老路径有废弃 shim。`install.sh` 首次升级时自动执行迁移。

### v1.9.0 — 全局升级（项目门禁自动跟随）

per-project 门禁现在是**瘦 shim**,委派全局权威 gate,所以 `install.sh --upgrade` **一次升级所有项目**——不再需要每个仓重跑 `init project gates`。

- **`hooks/git/gate-shim.sh`**:每个项目的 `.githooks/agent-quality-gate.sh` 是 ~10 行壳,`exec` 全局 gate(`~/.agent-gates/hooks/git/agent-quality-gate.sh`)。没装 agent-gates 则不挡 commit(契合 `AGENT_MODE=1` "humans pass through")。
- **`agent-gates-migrate`**:扫描项目根目录,把老的冻结拷贝门禁批量换成 shim(默认 dry-run;`--apply` 才动手)。
- **`agent-gates-version`**:查看全局门禁版本(= 所有 shim 项目实际跑的版本);传项目根目录可列各项目 shim/stale 状态。

### v1.8.0 — opencode 交叉审查可靠性

- **`oc-review`**:包装 `opencode run`,空输出自动重试(opencode 偶发 exit 0 空输出);持续失败 exit 75,调用方 fallback codex。
- **`oc-reaper`**:清理孤儿 `opencode serve` 进程(默认 dry-run;`--apply`)。
- `doctor.sh` → `check_opencode_health` 暴露泄漏的 serve。

### v1.7.0 — 异构审查物理强制

- **Gate 2b**:机器支持异构审查(L1+)时,同模型或无标注的 review 被**阻断**——review 文件必须带 `<!-- REVIEW_LEVEL: Lx -->` 证明用了不同模型(拦"Opus 审 Opus"自批)。`SKIP_HETERO_CHECK=1` 逃生。

### v1.6.0 — 跨平台审查能力检测 + 自适应路由

- **能力等级(L0--L3)** 持久化到 `~/.agent-gates/review-capability.json`;**平台自适应路由(§8)** 瀑布(opencode → codex → OMC 插件 → Paseo → agent-tool);**审查 prompt 模板(§9)**;CI/Windows/WSL/容器检测。

## What's Included（装好的内容）

### Skills

| Skill | 用途 | 激活方式 |
|-------|------|--------|
| `init-project-gates` | 项目设置：hook + `.agent/` 目录 + AGENTS.md | 手动："init project" |
| `agent-workflow-rules` | TDD、计划审查、验证、调试 | 代码任务自动加载 |
| `agent-review-protocol` | 三 Agent 评审流水线、交叉检查、平台自适应审查路由（§8）、审查 prompt 模板（§9） | 审查阶段触发 |
| `init-deep-fallback` | 跨平台 AGENTS.md hierarchy 兜底（bundled v1.5.2+） | 由 `init-project-gates` Step 6 在无 OMC/OMO 工具时调用 |
| `memory` | Infinite organized memory（bundled v1.5.4+） | `memory-reminder` hook 触发时自动加载 |

### Hooks

| Hook | 类型 | 触发时机 | 强制内容 |
|------|------|--------|--------|
| `agent-quality-gate.sh` | Git pre-commit | Agent commit（`AGENT_MODE=1`） | 测试文件 + 审查证据 + 异构审查（Gate 2b） |
| `memory-reminder.mjs` | 平台 PostToolUse | todo completed / ≥3 计划时 todo | Memory 存档提醒 + 并行提醒 |
| `gate-shim.sh` | per-project hook 源 | 装入 `.githooks/` | 委派全局权威 gate（v1.9.0+） |

### 命令（`~/.agent-gates/bin/`）

| 命令 | 用途 |
|------|------|
| `oc-review run -m <model> --dir <wd> "<prompt>"` | opencode 交叉审查 + 空输出重试;exit 75 → 调用方 fallback codex |
| `oc-reaper [--apply]` | 清理孤儿 `opencode serve` 进程（默认 dry-run） |
| `agent-gates-verify-ack <run_id> [reason]` | 人工确认后写入 USER_ACK（v2.0.0） |
| `agent-gates-verify-strip` | 管道过滤器：剥离 verifier 输出中的 USER_ACK 标记（v2.0.0） |
| `agent-gates-config-migrate` | 迁移 v1 `review-capability.json` → v2 `hetero-check.json`（v2.0.0） |
| `agent-gates-migrate [--apply] <root>...` | 批量把老门禁迁到 v1.9.0 shim |
| `agent-gates-version [<root>...]` | 查看全局门禁版本;列各项目 shim/stale 状态 |

### 约定：`.agent/` 目录

```
.agent/
├── PROGRESS.md      # Sprint 跟踪、决策、阻塞（git 跟踪）
├── GATES.md         # 质量门控清单（git 跟踪）
├── reviews/         # 交叉审查证据文件（git 跟踪，CHECK 5）
├── verify/          # Verifier 证据 + dispatch artifacts + .ack（v2.0.0，CHECK 6）
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

**CHECK 6 — Verifier Evidence**（v2.0.0）：与 Gate 2 阈值相同，加高风险路径检测。要求 `.agent/verify/*.md` 含 `VERIFY_VERDICT`。PASS → 放行；FAIL → 阻断（先修复）；QUESTIONS/INCOMPLETE → 需要 `.ack` 文件中的 `USER_ACK: PROCEED`（人工确认，绑定 diff-hash）。高风险路径 + EVIDENCE_ONLY 能力 → 强制 INCOMPLETE（必须走 FULL 黑盒通道）。`SKIP_VERIFY=1` 紧急逃生。

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

### 项目级门禁自动升级（v1.9.0+）

v1.9.0 起,项目级 `.githooks/agent-quality-gate.sh` 是**瘦 shim**,委派全局权威 gate。所以**全局升级 agent-gates 会同时升级所有 shim 项目**——不必逐个 re-init。用 `agent-gates-version <项目根>` 核对。

**迁移 v1.9.0 之前的老项目(一次性)**:v1.9.0 之前 init 的项目仍带冻结完整拷贝(不会自动升级)。一把迁移:

```bash
~/.agent-gates/bin/agent-gates-migrate <你的项目根>          # dry-run: 列出 stale 项目
~/.agent-gates/bin/agent-gates-migrate --apply <你的项目根>  # 换成 shim
```

迁移后,在每个仓 review + commit `.githooks/agent-quality-gate.sh` 的改动。之后它们就自动升级了。

### 一键升级 + 迁移（把这段粘给你的 agent）

不想自己敲命令？把下面这段粘给你的编码 agent。安装器是幂等的——**没装会自动安装，已装会升级**——然后把所有已初始化项目迁移到自动跟随的 shim。

> **任务**：在本机安装或升级 agent-gates，然后把所有已初始化项目迁移到 v1.9.0 shim，让它们自动跟随后续升级。全程遵守 agent-gates 门禁纪律，不要用 `--no-verify`。
>
> **项目根目录**（发送前先填，空格分隔）：`ROOTS="$HOME/Projects $HOME/wb/projects"`。不确定就先问我扫哪些根。
>
> 1. **安装或升级**（同一条命令两用——没装则装，已装则升）：`curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash`。然后确认 `cat ~/.agent-gates/.version` 和 `~/.agent-gates/bin/agent-gates-version`。（没有 `curl`？用 `git clone https://github.com/mcdowell8023/agent-gates && cd agent-gates && ./install.sh`。）
> 2. **扫描**门禁状态（只读）：`~/.agent-gates/bin/agent-gates-version $ROOTS`。`[shim → vX]` = 已自动跟随；`[STALE …]` = 老的完整拷贝或未识别 hook（第 3 步会区分）。
> 3. **dry-run** 迁移（不动任何文件）：`~/.agent-gates/bin/agent-gates-migrate $ROOTS`。只迁移可识别的 agent-gates 门禁；手写的同名 hook 会被跳过并报告为 `unknown`。核一眼清单。
> 4. **执行**：`~/.agent-gates/bin/agent-gates-migrate --apply $ROOTS`
> 5. 迁移会改写每个仓的 `.githooks/agent-quality-gate.sh`（on-disk 即刻生效）。**不要 push。** 报告哪些仓现在有未提交的 `.githooks` 改动，让我按各仓规矩 review + commit。
> 6. **报告**：全局版本、迁移了哪些项目、还有哪些 STALE 或被 `unknown` 跳过。
>
> 之后每个迁移过的项目都会自动跟随后续升级——下次你只需跑第 1 步。

### 其他升级须知
- **备份会累积。** 每次检测到用户修改的升级都会留一个新的 `SKILL.md.bak.*` 文件。合并完编辑后跑 `./uninstall.sh --purge-backups`（如果只想清备份就配合 `--keep-skills`）来移除它们。
- **OMO native（OpenCode）的 hook 注册是手动的。** 安装器检测到 `~/.config/opencode/` 时，打印要加到 `~/.config/opencode/hooks.json` `.hooks.PostToolUse[]` 下的 JSON 条目。`doctor.sh` 检查同样的路径/schema；如果它报告 OMO hook 缺失，请手动添加（完整 JSON 形态见 `docs/platform-hooks.md` → OMO）。注意：如果你的 OMO 跑在 Claude Code 上（而不是 OpenCode），OMC 的 `settings.json` 注册已经覆盖你 —— 无需手动步骤。
- **不自动迁移 skill。** 如果未来某个版本重命名或重构了 skill 目录，你可能需要手动清理旧布局 —— 安装器只更新已知名字的 skill。

## Doctor（健康检查）

安装后跑 `~/.agent-gates/doctor.sh`（或在仓库内跑 `./doctor.sh`）来验证部署健康度：

```bash
~/.agent-gates/doctor.sh
```

示例输出（理想 Path A：OpenSpec 已装 + ≥1 个 `.feature` + transcripts 干净 + 异构审查工具齐全）：

```
✓ node v26.0.0
✓ jq jq-1.8.1
✓ Memory skill detected: ~/.cc-switch/skills/memory-1.0.2
✓ Superpowers skills detected (5/5)
✓ installed version: 1.6.0
✓ up to date with remote (1.6.0)
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
✓ Cross-review capability: L3 (opencode + codex)

17 pass · 0 warn · 0 fail
```

在默认的 Path B 项目（无 OpenSpec、无 `features/`）里，OpenSpec/BDD 行变成信息性 `note` 而不是 PASS，交叉审查能力检查反映实际安装的工具（L0 变 WARN，L1+ 为 PASS）。典型输出带异构审查工具但无 OpenSpec 时为 **14 PASS + 1 WARN/PASS + 3 note**。`note` 表示"不适用 / 未配置"，不是"坏了"。

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
| `HETERO_EXHAUSTED` / 审查跑不出东西 | 五种互不相关的原因，最常见的是 prompt 格式 | 见下面 [审查失败](#审查失败先看-review-fail-那一行) |

### 审查失败：先看 review-fail 那一行

`agent-gates-review` 有五种互不相关的失败。v2.0.2 起每种都会单独打一行，前缀是
`review-fail[<模型>]:`。**先读那一行**，底下那句 `HETERO_EXHAUSTED` 汇总不含任何原因信息。

| 报错行 | 实际发生了什么 | 怎么办 |
|---|---|---|
| `answered N chars but produced no VERDICT line` | 模型正常回答了，只是回答里没有 gate 能识别为结论的那一行。**这是占比最高的一种失败。** 报错里带了模型输出的前 200 字符，可以自己确认它确实答了 | 改 prompt，见下。通道、模型、网络都没问题，别往那边查 |
| `opencode exited 0 but produced empty output` | 传输层抖动（`oc-review` 会重试的 P2 模式） | 重试。持续出现就用 `oc-reaper` 查共享 serve |
| `opencode timed out after Ns` | 撞上 `AG_REVIEW_TIMEOUT`（默认 300s） | 收窄 prompt。「找出所有引用 X 的地方」这类开放式要求等于放模型去爬整个仓库。确认 prompt 本身就很大时，才调高 `AG_REVIEW_TIMEOUT` |
| `shared opencode serve unhealthy at <url>` | fail-closed：共享 serve 没了或卡死，拒绝裸跑是刻意设计 | `oc-reaper --apply` 清掉卡死的 serve，再重试 |
| `opencode exited N` / `codex timed out` | 审查进程本身失败 | 手工跑同一条命令看它的 stderr |

#### prompt 必须要求结论行

gate 只把「输出里有一行能被识别为结论」的审查算作可用。prompt 里没要求这一行，审查写得再好也会被丢掉。在审查 prompt 末尾放这段：

```
最后一行必须是下列之一，且只有这一行内容：
VERDICT: PASS
VERDICT: ISSUES
VERDICT: FAIL
```

可用取值（不区分大小写）：`PASS` `PASSED` `REVISE` `REVISED` `FAIL` `FAILED` `ISSUES` `ISSUES_FOUND` `APPROVED` `APPROVE` `REJECT` `REJECTED`。

**结论行除了取值本身不能带别的内容**（装饰符和句末句号无妨）。带限定词的结论一律拒，无论哪种写法——`PASS_WITH_ISSUES`、`PASS-WITH-ISSUES`、`PASS.WITH.ISSUES`、`PASS WITH NOTES`。把仍有遗留问题的审查读成干净通过，会让结论反过来，比直接判失败更糟。审查有保留就写 `VERDICT: ISSUES`，把保留写进正文。

v2.0.2 起，外面裹什么装饰都不影响，下面这些全部接受：

```
VERDICT: PASS          **VERDICT: PASS**      ## VERDICT: PASS
- VERDICT: PASS        > VERDICT: PASS        `VERDICT: PASS`
  VERDICT: PASS        VERDICT：PASS          VERDICT: **PASS**
```

仍然会被拒的两种，因为 gate 无法判断它们是什么意思：取值不在枚举内（`VERDICT: OK`、`VERDICT: NEEDS_WORK`），以及整段回答里没有结论行。

#### 两个**不是**原因的东西

**`opencode --format json` 不会挂死。** v2.0.2 之前的一些记录把根因写成它，那是误诊。在 opencode 1.17.15 上实测：裸跑 / `--attach` × 带 `--format json` / 不带，四条路径全部在 4~20 秒内返回，输出正是 `parse_opencode_json` 期望的 NDJSON。那几次事故的真实原因是两件事叠加——审查 prompt 没要求结论行，以及所有调用都没有超时保护，导致一个无边界 prompt 能跑一个多小时、最后 exit 0 什么也没产出。两处都已修。

**`timeout` 找不到不代表环境坏了。** macOS 不带 GNU `timeout`，用它包住的排查命令会以 127 退出，看起来像工具挂了。改用 `bin/with-timeout.mjs <秒> <命令>`，gate 自己用的就是这个。

#### 两条通道都不可用时：外部审查导入

opencode 和 codex 都跑不了时，还有一条合法路径 —— 由调用方 agent 派 Paseo 子会话，锚点仍由工具掌管。两个阶段：

```bash
# 1. 捕获锚点 + 快照 prompt + 发 token，退出码 77
agent-gates-review <prompt-file> --route paseo --dispatch-out request.json

# 2. 调用方 agent 按 request.json 的 "suggested" 派 Paseo 子会话
#    （走 MCP create_agent —— shell 脚本创建不了本机 Paseo agent），拿到审查后导入：
# 来源可核实——工具会核 agent 确实存在且是异构 provider：
agent-gates-review --import-result review.md --token <token> \
  --paseo-agent <agent-id> --result .agent/reviews/<name>.md

# 来源仅声明——任意通道都行（opencode CLI、codex、别的 agent、人工看的）：
agent-gates-review --import-result review.md --token <token> \
  --imported-model "opencode/github-copilot/gpt-5.5" --result .agent/reviews/<name>.md
```

**不规定通道，只规定证据。** 审查由什么产出的都可以，gate 认的是锚点。两种形式的差别只在对来源是否诚实：带 `--paseo-agent` 时产物记录已核实的 agent；带 `--imported-model` 时记 `REVIEW_TOOL: external` 并把模型标为 `unverified`。两者必须给一个，所以不会出现来源完全不明的审查。

`request.json` 里带一个 `requirements` 块，把它抄进子会话的 prompt，审查就不会回来时缺结论行。

**这条通道保证**：staged diff 在派发与导入之间没变；reviewer 拿到的就是派发时快照的那份 prompt；确实存在一个 provider 非 claude、且创建于派发之后的 Paseo agent；token 只能用一次。

**不保证**：⛔ **不证明审查正文出自那个 agent** —— 调用方可以真派一个异构 agent，却提交自己写的正文。token 不是授权凭据，它存在 agent 可写的目录里。锚点只覆盖 **staged diff**，未 staged 的改动、untracked 文件、依赖版本、运行态都不在范围内。完整表述见 `docs/plans/2026-08-13-paseo-review-channel.md` §4。

#### 伪造证据 与 用户授权放行，是两回事

**伪造永远禁止。** gate 在审查**之前**捕获 `REVIEW_HEAD` / `REVIEW_FILES_SHA256` / `REVIEW_DIFF_SHA256`，审查**之后**再校验一次，用来证明这份证据描述的就是要提交的代码。手工填锚点、改 verdict、编一份报告出来——这些是绕掉那个保证，不是满足它。

**但用户明确授权的放行是合法路径，不算违规。** 用户说了继续，下面这些都可以用：

```bash
SKIP_VERIFY=1 git commit ...      # 跳过 CHECK 6
SKIP_REVIEW=1 git commit ...      # 跳过 CHECK 5
agent-gates-verify-ack <run-id>   # 给 INCOMPLETE 的 verify 记录用户的放行
```

三个条件，都是关于如实，不是关于权限：

1. 用户**真的说了** —— 不是推断的，不是「他应该会同意」
2. 报告里写明这是**授权放行，不是检查通过**
3. 还没验的部分写清楚，不能悄悄消失

关于 `agent-gates-verify-ack` 要看明白一件事：gate 对它只校验 diff hash 和 4 小时时效，**完全不记录签署者身份**。所以「只有人能签」从来不是技术保证，它只是一条纪律，而且代价不小。把 ack 当审计记录看：谁批准的、什么时候、还剩什么没验。

**有一个死锁值得点名。** verify 可能仅仅因为端到端没做而判 `INCOMPLETE`，而端到端必须先部署，部署必须先 commit，commit 又要 verify 通过。**这个环谁都出不去，再努力也没用。** 授权放行正是为这种情况准备的——批准、提交、随后立刻补端到端。不许发生的是假装端到端已经跑过。

## Relationship Between Components（组件关系）

```
init-project-gates          ─── 设置项目 ───►  .agent/ + hook
       │
       │ 运行时伴侣
       ▼
agent-workflow-rules        ─── 管控 agent 如何工作 ───►  TDD / 验证
       │
       ├── 审查强制
       │         ▼
       │   agent-review-protocol  ─── 交叉检查流水线 ───►  .agent/reviews/（CHECK 5）
       │
       ├── verifier 强制（v2.0.0）
       │         ▼
       │   hetero-check 子系统 ─── dispatch + 生命周期 ───►  .agent/verify/（CHECK 6）
       │         │
       │         ├── dispatch（paseo/opencode/codex/codebuddy/claude）
       │         ├── janitor（measure/budget/recycle/circuit-breaker）
       │         └── verifier.md（黑盒产品验收）
       │
       │ 持久化强制
       ▼
memory-reminder.mjs         ─── 平台 hook ───►  Memory skill 存档
```

## License

MIT

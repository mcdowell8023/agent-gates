# agent-gates 是什么

> 跨平台 AI agent 的**工程纪律运行时执行层**（runtime gate layer）。一次安装，让 Claude Code / OpenCode / Codex 三个 agent 平台同时获得 TDD 守门、交叉审查证据检查、Memory 持久化提醒、commit 质量门控。

---

## 1. 解决了什么问题

LLM agent 写代码很快，但很容易：

- 跳过 TDD，先写实现再补测试（甚至不补）
- 自评"已完成"——但没真的跑过验证命令
- 修 bug 修不动了开始瞎试，没有 stop-and-rethink 信号
- todo 完成了但 session 一中断上下文全丢，下次接续从零开始
- commit 把无关改动一起带进来，单 PR 几十文件
- 多 agent 平台各自一套规则，跨平台一致性靠人工

**单纯写在 prompt 里的规则没用** —— agent 读完就忘，没有"刹车"。需要的是 **运行时强制点**（hook + 门控），让违规行为出错而不是滑过去。

agent-gates 就是这一层：把工程纪律编码成 **三个 skill + 两个 hook + 一个项目模板**，配套自动安装器（install.sh）、自检工具（doctor.sh）、卸载器（uninstall.sh）。

---

## 2. 整体架构

```mermaid
flowchart TB
    subgraph install["一次性安装：./install.sh"]
        I1[检测 agent 平台]
        I2[复制 skills 到平台目录]
        I3[部署 hooks 文件]
        I4[注册 PostToolUse hook 到 settings.json / hooks.json]
        I1 --> I2 --> I3 --> I4
    end

    subgraph skills["3 个 skill（agent 运行时自动加载）"]
        S1[init-project-gates<br/>项目初始化器]
        S2[agent-workflow-rules<br/>TDD / 验证 / 防循环]
        S3[agent-review-protocol<br/>三 agent 审查 + 交叉检查]
    end

    subgraph hooks["2 个 hook（事件触发）"]
        H1[memory-reminder.mjs<br/>PostToolUse: TaskUpdate completed]
        H2[agent-quality-gate.sh<br/>git pre-commit: AGENT_MODE=1]
    end

    subgraph platforms["支持的 agent 平台"]
        P1[Claude Code OMC]
        P2[OpenCode OMO]
        P3[Codex OMX]
        P4[cc-switch<br/>三家共用]
    end

    subgraph runtime["每仓库运行时"]
        R1[.agent/PROGRESS.md<br/>.agent/reviews/<br/>.agent/memory/]
        R2[.githooks/agent-quality-gate.sh<br/>pre-commit 链接]
    end

    install --> skills
    install --> hooks
    skills --> platforms
    hooks --> platforms
    S1 -.创建.-> runtime
    H2 -.写入.-> R2

    classDef install fill:#e1f5ff,stroke:#0369a1
    classDef skill fill:#f0fdf4,stroke:#15803d
    classDef hook fill:#fef3c7,stroke:#a16207
    classDef platform fill:#faf5ff,stroke:#7c3aed
    classDef runtime fill:#fef2f2,stroke:#b91c1c

    class I1,I2,I3,I4 install
    class S1,S2,S3 skill
    class H1,H2 hook
    class P1,P2,P3,P4 platform
    class R1,R2 runtime
```

---

## 3. 三大支柱怎么工作

### 支柱一：runtime skill 注入工程纪律

agent 在打开 IDE / 启动会话时，自动加载下面三个 skill 的 SKILL.md。这些 markdown 文件里写的是 **行为规则**（TDD 必走 RED→GREEN、3 次失败强制 stop、commit 前必跑测试……），agent 通过 system prompt 把它们当硬约束执行。

| Skill | 触发时机 | 强制内容 |
|---|---|---|
| `init-project-gates` | 用户喊"初始化项目" / "init project gates" | 创建 `.agent/` 目录 + 装 pre-commit hook + 生成 AGENTS.md |
| `agent-workflow-rules` | 写代码 / 修 bug / 重构 | TDD 三阶段、计划评审门控、3-strike 防循环、verification-before-completion |
| `agent-review-protocol` | 实现完成、走交叉审查 | Three-Agent Review 流水线、严重性分级、再审防环规则 |

### 支柱二：PostToolUse hook 守 Memory 持久化

```mermaid
sequenceDiagram
    autonumber
    participant Agent as Agent (Claude / Codex)
    participant Tool as TaskUpdate tool
    participant Hook as memory-reminder.mjs
    participant Memory as Memory skill
    participant Session as Session 上下文

    Agent->>Tool: 把 todo 标 completed
    Tool->>Hook: PostToolUse 触发
    Hook->>Hook: 检测 status=completed
    Hook-->>Agent: 注入 [AGENT-GATES: Memory Persistence Reminder]
    Note over Agent: 看到 system-reminder 必须先存 memory
    Agent->>Memory: 写当前进展 / 决策 / 下一步
    Memory->>Session: 永久落盘
    Note over Session: 下次会话启动可恢复上下文
```

**关键点**：hook 是平台原生 PostToolUse 事件（OMC 在 `~/.claude/settings.json` 注册、OMX 在 `~/.codex/hooks.json` 注册），agent 没法绕过。validator 拒绝输出 schema 不合规的 hook 响应——v1.2.1 修过这个静默 fail 的 bug。

### 支柱三：git pre-commit gate 守 commit 质量

```mermaid
flowchart LR
    A[git commit] --> B{AGENT_MODE=1?}
    B -- 否（人类开发者）--> Z[正常 commit ✅]
    B -- 是（agent）--> C{Gate 1: 新增 src 文件<br/>必有对应 test?}
    C -- 否 --> X1[阻断 commit ❌]
    C -- 是 --> D{Gate 2: 改动量超阈值?<br/>logic>1 且 diff>50 行<br/>或单文件>150 行}
    D -- 否 --> Z
    D -- 是 --> E{.agent/reviews/<br/>有 VERDICT: PASS?}
    E -- 否 --> X2[阻断 commit ❌]
    E -- 是 --> Z

    classDef block fill:#fef2f2,stroke:#b91c1c
    classDef pass fill:#f0fdf4,stroke:#15803d
    class X1,X2 block
    class Z pass
```

**核心设计**：这个 gate **只约束 agent**，不影响人类开发者。通过 `AGENT_MODE=1` 环境变量区分。Agent 想 commit 必须先有测试 + 跨 agent 审查证据；人类开发者照常提交。

---

## 4. 依赖什么

| 依赖 | 必需性 | 用途 |
|---|---|---|
| Node.js ≥ 18 | **必需** | 跑 `memory-reminder.mjs`（ES modules + `node:fs`） |
| `git` 或 `curl` | **必需** | install.sh 拉取仓库 |
| `bash` | **必需** | install.sh / doctor.sh / agent-quality-gate.sh |
| `jq` | 推荐 | 安全 merge `hooks.json` / `settings.json`；缺了改走手动 |
| Memory 类 skill（`memory` / `writer-memory` 等） | 推荐 | hook 提醒 agent 存档，没装也能跑但 reminder 只有信息意义 |
| 至少一个 agent 平台 | 推荐 | OMC / OMO / OMX / cc-switch；install.sh 自动检测 |

> ⚠️ 注意：`$HOME` 路径**不能含空格**——shell hook 无法可靠转义。

---

## 5. 与 agent-superpowers / OpenSpec 是什么关系

这三个东西经常被混淆，但实际上是**三层并行的**：

```mermaid
flowchart TB
    subgraph layer3["L3 — 规格层（OpenSpec / opsx）"]
        L3A[spec-first 工作流]
        L3B[.feature Gherkin 验收]
        L3C[opsx:explore → propose → apply → archive]
    end

    subgraph layer2["L2 — 纪律规则层（agent-superpowers）"]
        L2A[纪律 prompt snippet]
        L2B[brainstorming → plan → implement<br/>→ spec-review → quality-review<br/>→ verify → complete]
        L2C[嵌入 AGENTS.md 由 agent 读取]
    end

    subgraph layer1["L1 — 运行时执行层（agent-gates）"]
        L1A[3 skill + 2 hook + 项目模板]
        L1B[跨平台安装 + 自检 + 卸载]
        L1C[git pre-commit 物理强制]
    end

    layer3 -. 团队项目<br/>spec 路径 .-> layer1
    layer2 -. 规则映射 .-> layer1
    layer1 -. enforce .-> layer2
    layer1 -. enforce .-> layer3

    classDef l1 fill:#fef2f2,stroke:#b91c1c
    classDef l2 fill:#fef3c7,stroke:#a16207
    classDef l3 fill:#f0fdf4,stroke:#15803d
    class L1A,L1B,L1C l1
    class L2A,L2B,L2C l2
    class L3A,L3B,L3C l3
```

| 项目 | 形态 | 强制性 | 多平台支持 | 跟 agent-gates 关系 |
|---|---|---|---|---|
| **agent-superpowers** | 单个 SKILL.md + AGENTS.md snippet | 软约束（agent 自觉） | 任何能读 SKILL 的 agent | agent-gates 把它的规则**实现**为可触发的 skill + 硬 gate |
| **OpenSpec / opsx** | 多个 `opsx:*` 命令 skill 套件 | 工作流规范 | 任何安装 opsx 的 agent | agent-gates 的 pre-commit gate **可以挂 OpenSpec 检查项**（AGENT_MODE=1 模式下检查 `.feature` 和 spec 引用） |
| **agent-gates** | 跨平台 installer + skill + hook + 项目模板 | 硬约束（PostToolUse hook + git pre-commit） | OMC / OMO / OMX / cc-switch 都装 | **底层执行层** —— 上面两个东西的规则最终都靠这一层在运行时落地 |

**一句话**：
- agent-superpowers **说**应该怎么做（规则文本）
- OpenSpec **规范**功能怎么生（spec-first 流水线）
- agent-gates **强制** agent 必须按那些规则做（hook + gate）

---

## 6. 如何使用

### 6.1 一行装好

```bash
curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash
```

或克隆后装：

```bash
git clone https://github.com/mcdowell8023/agent-gates.git
cd agent-gates && ./install.sh
```

安装器会：
1. 检测 agent 平台（OMC / OMO / OMX / cc-switch），找不到就装到默认 `~/.claude/skills/`
2. 复制 3 个 skill 到对应平台的 skills 目录
3. 部署 hook 文件到 `~/.agent-gates/hooks/`
4. 注册 PostToolUse hook 到平台 settings.json / hooks.json（OMO 当前打印手动指引）
5. 部署 doctor.sh 自检工具到 `~/.agent-gates/doctor.sh`

### 6.2 装完体检

```bash
~/.agent-gates/doctor.sh
```

输出示例：

```
✓ node v26.0.0
✓ jq jq-1.8.1
✓ Memory skill detected: ~/.cc-switch/skills/memory-1.0.2
✓ installed version: 1.3.1
✓ up to date with remote (1.3.1)
✓ memory-reminder.mjs present
✓ agent-quality-gate.sh present (executable)
✓ OMC settings.json hook registered (matcher contains TaskUpdate)
✓ OMO hooks.json hook registered
✓ OMX hooks.json hook registered
✓ hook output schema valid
✓ no memory-reminder hook errors in last-7d transcripts

11 pass · 0 warn · 0 fail
```

退出码：**0 = 无 FAIL（允许 WARN）；1 = 有 FAIL**——CI 友好。
标志：`--quiet`（只显示汇总）/ `--no-network`（离线模式）/ `--help`。

### 6.3 在项目里启用

任意一个 git 仓库内，告诉 agent：

```
初始化项目
```

agent 会调用 `init-project-gates` skill，自动：

1. 创建 `.agent/` 目录（含 PROGRESS.md / GATES.md / reviews/ / plans/ / memory/）
2. 装 pre-commit hook 到 `.githooks/agent-quality-gate.sh`
3. 生成 AGENTS.md 层级（调 deepinit）
4. 注入工作流规则到项目 CLAUDE.md

之后 agent 在这个仓库里写代码会自动遵守 TDD、verification、cross-review 等约束；commit 会被 pre-commit gate 检查。

### 6.4 端到端流程

```mermaid
sequenceDiagram
    participant U as 用户
    participant A as Agent
    participant Skills as Skills
    participant Hook as PostToolUse hook
    participant Mem as Memory skill
    participant Git as Git pre-commit gate

    U->>A: "实现 X 功能"
    A->>Skills: 加载 agent-workflow-rules
    Skills-->>A: 强制 TDD: RED→GREEN→REFACTOR
    A->>A: 写失败测试
    A->>A: 跑测试看到 fail（RED）
    A->>A: 写最小实现
    A->>A: 跑测试看到 pass（GREEN）
    A->>A: 标 todo completed
    Hook-->>A: 注入 [AGENT-GATES: Memory Persistence Reminder]
    A->>Mem: 存当前进展 + 决策
    A->>Skills: 加载 agent-review-protocol
    Skills-->>A: Three-Agent Review 流程
    A->>A: 自评 + Spec reviewer + Quality reviewer
    A->>Git: git commit
    Git-->>Git: AGENT_MODE=1 → 检查测试 + 审查证据
    Git->>A: commit 通过 ✅
```

---

## 7. 关键文件 / 目录

```
~/.agent-gates/                          # 全局安装位置
├── .version                             # 1.3.1
├── doctor.sh                            # 体检工具
└── hooks/
    ├── platform/memory-reminder.mjs     # PostToolUse hook
    └── git/agent-quality-gate.sh        # 项目 pre-commit 母版

~/.claude/skills/                        # OMC skills（或对应平台路径）
├── init-project-gates/SKILL.md
├── agent-workflow-rules/SKILL.md
└── agent-review-protocol/SKILL.md

~/.claude/settings.json                  # 注册 hook：
                                         # .hooks.PostToolUse[].command
                                         # 指向 ~/.agent-gates/hooks/platform/memory-reminder.mjs

<project>/.agent/                        # 仓库内（init-project-gates 创建）
├── PROGRESS.md                          # Sprint 进度（git 跟踪）
├── GATES.md                             # 质量门 checklist
├── reviews/                             # 交叉审查证据（git 跟踪）
├── plans/                               # 实现计划（git 跟踪）
└── memory/                              # 会话 memory（.gitignored）

<project>/.githooks/agent-quality-gate.sh  # pre-commit hook copy
```

---

## 8. Troubleshooting 速查

| 症状 | 多半是 | 怎么修 |
|---|---|---|
| `node not found` | Node.js 不在 PATH | 装 Node ≥ 18 |
| Hook 触发了但 Memory 没存 | 没装 Memory skill | 在任意 skills 目录装一个 memory 类 skill |
| 升级了 agent-gates 但仓库行为没变 | per-project hook 不会自动升级 | 在该仓库 `init project gates` 重跑 |
| OMC matcher 不含 TaskUpdate | install.sh 没装到位 | `~/.agent-gates/doctor.sh` 会标 FAIL；重跑 `install.sh --force` |
| hooks.json 出现重复条目 | 手动改过 + 多次跑 installer | `./uninstall.sh && ./install.sh` |

更完整列表见 [README.md → Troubleshooting](../README.md#troubleshooting)。

---

## 9. 资源

- GitHub: <https://github.com/mcdowell8023/agent-gates>
- 当前版本：v1.3.1（2026-05-22）
- 许可：MIT
- 平台 hook 协议详解：[docs/platform-hooks.md](./platform-hooks.md)
- 体检工具：`~/.agent-gates/doctor.sh --help`

> 这份说明同步落在本地 Obsidian Vault：`Wiki/04_Knowledge/AI/Agent/agent-gates.md`。

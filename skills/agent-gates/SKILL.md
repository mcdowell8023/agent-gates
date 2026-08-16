---
name: agent-gates
description: "agent-gates 运维入口：一条命令看全状态（版本 / skills / serve 泄漏 / 仓库同步 / 项目 gate），以及清理与迁移。Triggers: 'agent-gates 状态', 'gate 状态', 'agent-gates version', '门禁版本', '装的是哪个版本', 'agent-gates 更新了吗', 'serve 泄漏', 'oc-reaper', 'gate doctor', 'agent gates status'."
---

# agent-gates 运维

⛔ **不要自己拼命令去查状态。** 版本、skills 是否齐、有没有 serve 泄漏、仓库同不同步、
项目走的是 shim 还是冻结副本 —— 这些以前要跑四五个命令再解析输出，现在一条就够：

```bash
~/.agent-gates/bin/agent-gates-status
```

约 4 秒。退出码 **0 = 全部正常**，**1 = 有项需要处理**（每项后面直接跟修复命令）。

## 参数

| 参数 | 用途 |
|---|---|
| （无） | 版本 + gate stamp + 四个平台 skills + serve 泄漏 + 仓库同步。~4s |
| `--full` | 额外扫描所有项目找冻结副本。**~80s**，只在怀疑项目没跟上版本时用 |
| `--no-network` | 跳过 remote 比对（离线或图快） |
| `--quiet` | 只出一行，给 hook / 脚本用 |

## 它替代了什么

| 以前 | 现在 |
|---|---|
| `agent-gates-version` | 包含在内 |
| `doctor.sh` | 关键项包含在内（要完整 16 项检查仍跑 `~/.agent-gates/doctor.sh`） |
| `agent-gates-migrate <roots>` 看项目状态 | `--full` |
| `pgrep opencode serve` + 数客户端 + 算年龄 | 包含在内 |
| `git ls-remote` 逐个 remote 比对 | 包含在内 |

## 动作类命令（status 会在需要时提示你跑哪条）

```bash
~/.agent-gates/bin/oc-reaper                     # 先 dry-run 看会清掉什么
~/.agent-gates/bin/oc-reaper --apply             # 清掉无客户端的泄漏 serve
~/.agent-gates/bin/agent-gates-migrate --apply ~/wb ~/AgentWorkspace/projects
```

⚠️ `oc-reaper` 保留**有真实 `opencode run` 客户端**的 serve（任何年龄），以及年龄未超
`OC_REAPER_MAX_AGE`（默认 7200s）的。裸连接不算「有人在用」—— Paseo 托管的 serve 与
daemon 的连接永不断开，早先版本因此把 23 小时的泄漏也当成在用。

## 升级本机

```bash
cd <agent-gates checkout> && ./install.sh --local     # 装当前 checkout（含未推送改动）
./install.sh --upgrade                                # 装远程 main
```

⚠️ **`--upgrade` 装的是远程 main，不是你所在的 checkout。** 横幅显示的却是本地 `.version`，
所以在本地分支上跑它会「显示新版本、装旧代码」，还照样打印一串 `✓ Installed:`。
要装本地改动必须用 `--local`。

项目侧不用管：v1.9.0 起每个项目的 `.githooks/agent-quality-gate.sh` 是薄 shim，
自动跟随全局版本，**不需要逐个 re-init**。

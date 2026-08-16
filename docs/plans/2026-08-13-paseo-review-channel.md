# v2.1.0 计划：外部审查导入通道（Paseo 子会话）

> 状态：**已过审**（第 3 稿）。三轮异构审查：gpt-5.5 提 5 条 → gemini-3.1-pro 确认修复并抓出 `.prompt` 泄漏 → gpt-5.5 复核生命周期闭环 **PASS**，仅留一条实现细节（stale 用 mtime，已写入 §6-24 / §7）
> 分支：`feat/paseo-review-channel`（基于 `fix/hetero-verdict-diagnostics` / v2.0.2）
> Last updated：2026-08-13

---

## 1. 要解决的问题

v2.0.2 修完之后审查失败的**报错**清楚了，**可用通道**并没有变多。2026-08-13 自审 dogfooding 的真实结果：

```
review-fail[github-copilot/gpt-5.5]: shared opencode serve is down ... (fail-closed)
agent-gates-review: falling back to codex
agent-gates-review: codex timed out after 300s
exit=75
```

两条通道同时不可用时，agent 没有任何合法路径产出审查证据。而实践中**有**一条已验证可行的路：调用方 agent 用 MCP `create_agent` 派 Paseo 子会话（`opencode/github-copilot/gpt-5.5` 等）。CRM 会话手工这么做过，审查确实跑出来了。

卡点不在"能不能派"，在**派出去的结果没有合法途径变成 gate 认可的产物**：gate 的 CHECK 5 要三个锚点，锚点的意义是「审查前捕获、审查后校验 staged 未变」这个时序保证；手工填锚点绕掉的正是这个保证，所以被明令禁止。⇒ agent 手工派出的审查再正确也进不了 gate。

## 2. 为什么不让工具自己派 Paseo

实测（2026-08-13）：本机 `paseo run` 从 shell 创建 agent **不可用** —— 它尝试拉起 Paseo Desktop（Electron），报 `FATAL ... Unable to find helper app`，**exit 0 但 `paseo ls` 里查不到 agent**。前台、`-d` 后台、`--host 127.0.0.1:6767` 三种都试过，结果一致。`rift-dispatch` skill §3 的分工也印证：派 Paseo 走 MCP `create_agent`（只有 agent 会话能调），`opencode --pure` 走 CLI，只有 Hub 远程用 `ssh hub`。

**但查询类命令可用**：`paseo agent inspect <id> --json` 从 shell 正常返回，这是 §3.2 来源核实的基础。

> ⚠️ 用 `inspect` 而不是 `ls`（实现阶段实测才发现）：`ls --json` 的 `created` 是**相对时间串**（`"4 minutes ago"`），无法判定先后；`inspect --json` 给绝对 ISO8601 `CreatedAt`。两者的字段名与结构也不同（camelCase vs PascalCase、provider 合并 vs 分开）。另注：`inspect` 对**不存在的 id 也 exit 0**，缺失只能从 payload 判断。

## 3. 方案：两阶段 + 不可变快照 + 来源核实

### 3.1 阶段 1 — 请求派发

```bash
agent-gates-review <prompt-file> --route paseo --dispatch-out <request.json>
```

工具做完以下四步后 **exit 77**（新码：需外部派发）：

1. 照常捕获锚点（`capture_review_anchor`，与现有路径同一份代码）
2. 建 pending **目录** `$GATES_DIR/pending-reviews/<token>/`，把 prompt 内容复制成不可变快照 `prompt`，记录其 sha256
3. 在同一目录写 `record.json`（含锚点、prompt sha256、`created_at`、`expires_at`、`cwd`）
4. 向 `--dispatch-out` 写派发请求；写失败则**整目录删除再退出**（不留悬挂 token）

> ⚠️ **为什么用目录而不是两个平行文件**（`<token>.json` + `<token>.prompt`）：阶段 2 的 claim 必须原子，而**目录 rename 是原子的，两个文件的 rename 不是**。第 2 稿用平行文件时 claim 只 mv 了 `.json`，`.prompt` 会永久留在 `pending-reviews/` 里 —— 成功路径删的是 `processing/<token>.*`，过期清理只扫 JSON，失败路径也没提它，快照会一直堆积。复审（gemini-3.1-pro）抓到的正是这个泄漏。改用目录做单位后，claim / 成功 / 失败 / 过期清理全部以整目录为对象，不存在孤儿文件。

派发请求：

```json
{
  "token": "<32 hex>",
  "prompt_file": "<GATES_DIR>/pending-reviews/<token>/prompt",
  "prompt_sha256": "<64 hex>",
  "suggested": {
    "provider": "opencode/github-copilot/gpt-5.5",
    "alternatives": ["codex/gpt-5.5", "codebuddy-code/deepseek-v4-pro"]
  },
  "requirements": {
    "read_only": true,
    "verdict_line": "最后一行必须是裸行 VERDICT: PASS / ISSUES / FAIL（无 markdown 装饰、无缩进、英文半角冒号）",
    "note": "结论行只能承载取值本身，PASS_WITH_ISSUES 之类会被拒",
    "heterogeneous": "provider 不能是 claude —— 同模型审查不算异构审查"
  },
  "expires_at": "<ISO8601，默认 +2h>",
  "import_cmd": "agent-gates-review --import-result <review.md> --token <token> --paseo-agent <agent-id> --result <out>"
}
```

⚠️ `prompt_file` 指向**快照**而非原始文件 —— 原始文件在两阶段之间可被改动，快照不会。`requirements` 把 v2.0.2 学到的格式约束直接放进请求，agent 照抄进 prompt 就不会再踩「答了但没 VERDICT 行」。

### 3.2 阶段 2 — 导入结果

```bash
agent-gates-review --import-result <review.md> --token <token> \
  --paseo-agent <agent-id> --result <out>
```

**先原子 claim，再校验**（顺序很重要，claim 失败就不做任何后续动作）：

| 步骤 | 失败退出码 |
|---|---|
| 0. `mv pending-reviews/<token> processing/<token>`（**整目录** rename，原子） | 1（token 不存在或已被其它进程 claim） |
| 1. `processing/<token>/record.json` 可解析且字段完整 | 1 |
| 2. 未过期 | 74 |
| 3. **`processing/<token>/prompt` 的 sha256 == 记录值** | 74 |
| 4. **当前 staged 锚点 == 记录的锚点** | 74 |
| 5. **`paseo agent inspect <id> --json` 能拿到该 agent**，且 `Provider` **不含 claude**，且 `CreatedAt` ≥ 记录的 `created_at` | 75 |
| 6. review.md 含合法 VERDICT 行（复用 `has_valid_conclusion`） | 75 |

全过 → `append_marker "paseo" "<该 agent 的实际 provider/model>"` + `output_result` → **`rm -rf processing/<token>`** → exit 0。

失败时的目录归属，按是否还有重试价值区分：

| 失败步骤 | 处置 | 理由 |
|---|---|---|
| 1（记录损坏） | `rm -rf processing/<token>` | 记录已不可信，留着也没法用 |
| 2（过期）· 4（锚点已变） | `rm -rf processing/<token>` | 不可恢复，重试也不会通过 |
| 3（快照被篡改） | `rm -rf processing/<token>` | 材料已污染，必须重新派发 |
| 5（agent 核实失败）· 6（缺 VERDICT 行） | `mv processing/<token> pending-reviews/<token>` **移回** | 换个 agent 或补个合规结论就能重试，锚点仍然有效 |

⇒ 整目录进、整目录出，任何路径都不会留下半个记录或孤儿快照。

`VERDICT: FAIL` **允许导入** —— FAIL 是合法结论，产物照写，由 gate 据此拒绝提交。工具不替 gate 做判断。

产物格式与现有完全一致（`REVIEW_TOOL` / `REVIEW_MODEL` + 三个锚点），⇒ **gate hook 一行都不用改**。

### 3.3 附带改动：失败时给出下一步

`HETERO_EXHAUSTED` 之后补一行：

```
hint: 两条通道都不可用时，可用 --route paseo 让调用方 agent 派子会话审查（见 README Troubleshooting）
```

## 4. 这个通道保证什么、不保证什么（⛔ 必须照实读）

**保证：**
- 审查所依据的 **staged diff** 在派发与导入之间未变（锚点复校）
- reviewer 拿到的 prompt 与派发时一致（快照 + sha256）
- 导入时**确实存在**一个异构 provider 的 Paseo agent，且它创建于派发之后（`paseo agent inspect <id> --json` 核实）
- 同一 token 只能导入一次（rename 原子 claim）

**不保证（不要误读）：**
- ⛔ **不证明 review.md 的正文出自那个 agent。** 调用方可以真派一个异构 agent、却提交自己写的正文。核实把门槛从"随便写个 hash"提到"必须真派一个异构子会话"，但**这不是来源认证**。
- ⛔ **token 不是授权凭据。** 它只做关联与防误导入，存在 agent 可写目录，可被同权限进程读取或伪造。
- ⛔ **只保证 staged diff。** working tree 未 staged 的改动、untracked 文件、依赖版本、测试环境、运行态一概不在锚点范围内。审查结论的有效性只覆盖 staged 内容。
- ⛔ 这是一个**被文档认可的 import 入口**，性质与"手工伪造 marker"（明令禁止）不同。它降低了正确路径的成本，同时也确实新增了一条入口 —— 这一点比第 1 稿里"与现有保证水平相同"的说法要重，不该轻描淡写。

要做到真正的来源认证，需要 gate 侧持有 agent 拿不到的密钥、或由 Paseo daemon 侧签发审查凭证。属于另一个议题，本计划不涉及。

## 5. 非目标

- 不自己派发 Paseo（本机 CLI 不可用，见 §2）
- 不改 gate hook（产物格式不变）
- 不做 Hub 远程通道（方案 B，等真有「完全无人值守」需求再加）
- 不做密码学级来源认证（见 §4）

## 6. 实现顺序（TDD）

每步先写失败测试跑到 RED，再最小实现。新测试文件 `tests/run_review_paseo_channel.sh`，fake `paseo` 二进制注入用 `AG_REVIEW_PASEO`（新 env，与 `AG_REVIEW_CODEX` 同惯例）。

**阶段 1**
1. `--route paseo --dispatch-out` → exit 77 + 请求 JSON 字段完整 + pending 记录与 prompt 快照双双落盘
2. 请求里 `requirements.verdict_line` / `heterogeneous` 存在（防止未来被删掉）
3. `--dispatch-out` 父目录不存在或不可写 → 非 0 退出，且**不留悬挂 pending 记录**

**阶段 2 — 核心保证**
4. happy path → exit 0 + 产物含 `REVIEW_TOOL: paseo` 与三个锚点
5. **staged 在两阶段之间被改 → 拒（74）**
6. **prompt 快照被篡改（sha256 不符）→ 拒（74）**
7. **paseo agent 不存在 → 拒（75）**
8. **paseo agent 的 provider 是 claude（同模型）→ 拒（75）**
9. **paseo agent 的 createdAt 早于派发时刻 → 拒（75）**（防止拿一个旧 agent 顶账）
10. token 过期 → 拒（74）
11. token 复用（第二次导入）→ 拒（1）
12. **并发导入同一 token → 有且仅有一个成功**
13. pending JSON 损坏 / 字段缺失 → 拒（1），且不产出产物
14. review.md 缺 VERDICT 行 → 拒（75），报错沿用 v2.0.2 的诊断文案
15. `VERDICT: FAIL` → **允许导入**（exit 0），产物照写
16. review.md 不可读 / 为空 → 拒（75）
17. 未知 token → 拒（1）

**生命周期（目录方案的重点，第 2 稿的泄漏就出在这里）**
18. claim 之后 `processing/<token>/prompt` 仍可读（证明快照随目录一起迁移，不会被落在 pending 里）
19. 步骤 5/6 失败后目录被移回 `pending-reviews/`，**同一 token 可以重试并成功**
20. 步骤 2/3/4 失败后目录被删除，同一 token 再导入 → 拒（1）
21. 过期清理以**整目录**为单位，删完不留任何残片；`pending-reviews/` 下不存在无 `record.json` 的孤儿目录
22. 清理**不碰** `processing/` 下正在处理的目录
23. **`processing/` 里超过 `AG_REVIEW_PROCESSING_STALE`（默认 1h）的目录按崩溃残留处理**，移回 `pending-reviews/`（记录仍完整）或删除（记录已损坏）
24. **stale 判定用目录进入 `processing/` 的时刻（目录 mtime），不用 `record.created_at`** —— 否则一条 pending 了 3 小时的记录刚 claim 就会被当成崩溃残留清掉。用例：`created_at` 远早于阈值但刚 claim 的目录**不得**被回收
25. `doctor.sh` 报告 `pending-reviews/` 与 `processing/` 各自的数量

## 7. 已知风险

| 风险 | 处置 |
|---|---|
| `pending-reviews/` 堆积 | 每次调用按**整目录**扫删过期；doctor 分别报告 pending / processing 数量 |
| **claim 之后进程崩溃 ⇒ 目录卡在 `processing/`，token 再也用不了** | 这是目录方案自身引入的：`processing/` 里超过 `AG_REVIEW_PROCESSING_STALE`（默认 1h）的目录按崩溃残留处理——记录完整则移回 `pending-reviews/`，损坏则删除。不做主动 PID 探活，因为导入进程可能来自另一台机器上的 agent |
| stale 判定误杀刚 claim 的记录 | 阈值必须对照**目录进入 `processing/` 的时刻（mtime）**，不能用 `record.created_at`——后者会让长时间 pending 的记录一 claim 就被回收（第 3 轮审查提出） |
| agent 派了异构 agent 却提交自己写的正文 | 无法防，已在 §4 明确声明不保证。doctor 可加弱信号（pending 数异常） |
| token 泄露（出现在命令行与 request JSON 里） | 同权限进程本就能读 pending 目录，token 不作为授权凭据，见 §4 |
| token 碰撞 | 以文件存在为准，碰撞则重新生成 |
| `paseo agent inspect --json` 输出格式变化 | 解析失败、缺 `Id`、缺 `Provider`、`CreatedAt` 不可解析，一律按"无法核实"处理 ⇒ 拒（75），不放行 |
| 清理过期与正在导入竞争 | `processing/` 目录不参与过期清理 |

## 8. 验收标准

- `tests/run_review_paseo_channel.sh` 全绿（27 项）
- 全量回归与 v2.0.2 基线一致（18 pass / 2 fail，两个环境敏感 flaky 不计）
- **端到端实跑**：本会话用 MCP `create_agent` 派 `opencode/github-copilot/gpt-5.5` 审一段真实 staged 改动 → 导入 → 确认 exit 0、产物含三个锚点、`REVIEW_MODEL` 记的是该 agent 的真实 provider
- README / README.zh-CN / `skills/agent-review-protocol` 写清两阶段用法、`requirements` 约束，以及 §4 的「保证 / 不保证」原文

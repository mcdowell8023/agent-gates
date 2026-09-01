---
name: agent-review-protocol
description: "Code review quality enforcement: Three-Agent Review pipeline, cross-check protocol, severity handling, and review prompt templates. Load during code review phases or when completing significant implementations. Triggers: 'review protocol', 'three agent review', 'cross check', '代码审查', '交叉检查', 'code review', 'quality review'."
---

# Agent Review Protocol

Code review quality enforcement for AI-assisted development. This skill defines WHO reviews, WHAT they check, and HOW issues are handled — ensuring no significant code ships without independent verification.

**Companion skills:**
- `init-project-gates` — one-time project setup (hook, AGENTS.md, PROGRESS.md)
- `agent-workflow-rules` — runtime discipline (TDD, plan review, verification)
- `verifier.md` (v2.0.0) — black-box product verification (third role, after Writer + Reviewer); see `agent-workflow-rules §9B` and CHECK 6

> **v2.0.0 Verifier role**: runs the product from user perspective after Writer + Reviewer pass. Four-state verdict: PASS / FAIL / QUESTIONS / INCOMPLETE. FAIL blocks the commit; QUESTIONS/INCOMPLETE require `USER_ACK` human sign-off (written by `agent-gates-verify-ack`, diff-hash bound). Never modifies code. Details: `agent-workflow-rules §9B`, `templates/verifier.md`.

---

## 1. Cross-Check Rule (⛔ Hard Constraint)

All completed development and documentation MUST be independently verified by a different model/agent before delivery.

| Work type | Required cross-check |
| --- | --- |
| Code (feature / bugfix / refactor) | Different model/agent does code review + runs tests |
| Documentation | Different model/agent checks accuracy, completeness, actionability |

### Recommended: `agent-gates-review` (v1.10.0+)

Instead of manually choosing a review tool, use the unified review command:

```bash
~/.agent-gates/bin/agent-gates-review <prompt-file> [--result <result-file>]
```

It reads `~/.agent-gates/review-capability.json`, routes to the best available heterogeneous tool (pi first since v2.4.0; opencode is disabled by default — see the priority table in §8), and auto-appends `REVIEW_TOOL` / `REVIEW_MODEL` / `REVIEW_LEVEL` markers to the output. On L0 machines (no heterogeneous tool) it exits 78 — caller falls back to same-model agent-tool.

**Use this command instead of spawning a Claude subagent for review.** On L1+ machines, using a same-model subagent violates the heterogeneous-review requirement (红线 #8).

#### ⛔ 审查失败时：先读 `review-fail[<模型>]:` 那一行

v2.0.2 起每种失败单独报一行。`HETERO_EXHAUSTED` 只是汇总，**本身不含任何原因**——2026-08-13 就是因为把它当原因，花了一整天去查一个不存在的通道 bug。

| 报错行 | 真实原因 | 处置 |
|---|---|---|
| `answered N chars but produced no VERDICT line` | 模型正常答了，输出里没有可识别的结论行。**占比最高**。报错里带模型输出前 200 字符，可自行确认它答了 | 改 prompt（见下）。通道、模型、网络都没问题，别往那边查 |
| `opencode exited 0 but produced empty output` | 传输层抖动 | 重试；持续出现用 `oc-reaper` 查共享 serve |
| `opencode timed out after Ns` | 撞上 `AG_REVIEW_TIMEOUT`（v2.4.1 起默认 120s） | ⭐ **别再收窄 prompt 重试**——实测极小 prompt 也超时。换 pi（§8 优先级 1），同一任务约 7s 返回 |
| `shared opencode serve unhealthy at <url>` | fail-closed，刻意拒绝裸跑 | `oc-reaper --apply` 清掉卡死 serve，再重试 |
| `opencode exited N` / `codex timed out` | 审查进程本身失败 | 手工跑同一条命令看 stderr |

**⛔ 永远不许伪造证据**（这些是造假，不是解决）：
- 手工填 `REVIEW_HEAD` / `REVIEW_FILES_SHA256` / `REVIEW_DIFF_SHA256`——绕掉的正是「审查前捕获、审查后校验 staged 未变」这个时序保证
- 改 verdict、编一份审查/验证报告
- 不带 `AGENT_MODE=1` 偷偷提交（gate 会静默放行，「commit 成功」≠「gate 跑了」）

**✅ 但用户明确授权的放行是合法路径**，不算违规，也不用再来回请示：

```bash
SKIP_VERIFY=1 git commit ...      # 跳过 CHECK 6
SKIP_REVIEW=1 git commit ...      # 跳过 CHECK 5
agent-gates-verify-ack <run-id>   # 给 INCOMPLETE 的 verify 记录用户放行（⚠️ 4 小时时效）
```

三个条件，都是关于**如实**而不是关于权限：
1. 用户**真的说了**——不是推断、不是「他应该会同意」
2. 报告里写明这是**授权放行，不是检查通过**
3. 还没验的部分写清楚，不许悄悄消失

⚠️ 看明白 `agent-gates-verify-ack` 是什么：gate 只校验 diff hash 和 4 小时时效，**完全不记录签署者身份**。所以「只有人能签」从来不是技术保证，只是一条纪律。用户明确授权后 agent 代跑这条命令是可以的——把它当审计记录：谁批准、何时、还剩什么没验。

🔴 **一个会把人锁死的环，要认出来**：verify 可能仅仅因为端到端没做而判 `INCOMPLETE`，而端到端必须先部署 → 部署必须先 commit → commit 又要 verify 过。**这个环再努力也出不去**，它是门禁的时序假设问题，不是你做得不够。遇到这种：如实报告「INCOMPLETE 的唯一原因是时序，不是漏做」，请用户授权放行，提交后立刻补端到端。⛔ 不许假装端到端已经跑过。

审查确实跑不起来、用户又没授权时，才停下报告。

#### prompt 结尾必须要求结论行

审查 prompt 末尾放这段，否则模型答得再好都会被判为失败：

```
最后一行必须是下列之一，且只有这一行内容：
VERDICT: PASS
VERDICT: ISSUES
VERDICT: FAIL
```

v2.0.2 起装饰不影响判定，下面这些全部接受：

```
**VERDICT: PASS**    ## VERDICT: PASS    - VERDICT: PASS
> VERDICT: PASS      `VERDICT: PASS`     VERDICT: **PASS**
  VERDICT: PASS      VERDICT：PASS（中文冒号）
```

⚠️ 仍会被拒的三种：

- 取值不在枚举内（`VERDICT: OK`、`VERDICT: NEEDS_WORK`）
- **结论行带限定词**——`PASS_WITH_ISSUES`、`PASS-WITH-ISSUES`、`PASS.WITH.ISSUES`、`PASS WITH NOTES` 全部拒。有保留就写 `VERDICT: ISSUES`，保留写进正文；把有遗留问题的审查读成干净通过会让结论反过来
- 整段回答没有结论行

⚠️ 装饰容忍是 v2.0.2 才有的。**目标机器上 `~/.agent-gates/.version` 若低于 2.0.2，必须写裸行**——把 VERDICT 包在反引号里被拒过，是真实踩过的坑。

#### 两条通道都不可用时：外部审查导入（v2.1.0）

#### verify 侧（CHECK 6）两个入口，别手写 `.md`

**① 走了 `hetero_dispatch`（自动通道）⇒ 用 `agent-gates-verify-harvest`**

dispatch 只写 `evidence.json` + `dispatch.json`，**不写 `.md`**；而 CHECK 6 读
`.agent/verify/*.md` 并以裸行 `^VERIFY_VERDICT:` 锚定。v2.6.0 起用这条命令收割：

```bash
agent-gates-verify-harvest <verify-run-id>
```

它从 evidence 里提取**模型自己写的结论行**，机械改写成 CHECK 6 的词表，并把原文逐字
记进产物供核对。⛔ **不要手写那个 `.md`** —— 手写 `.md` 就是手写 verdict。
evidence 没有结论行时它会拒绝并让你去 prompt 里加要求，那是对的，别绕过。

#### 🔴 v2.9.1：merge 需要单独的钩子点

`merge-only` 档把审查推迟到「合并进 strict 分支」那一刻 —— 而 **git 对 merge commit 走的是
`pre-merge-commit`，不是 `pre-commit`**。只装 `pre-commit` 的仓库，干净的 merge 完全不受检。

所以每个项目要装**两个**钩子，内容是同一份 `gate-shim.sh`：

```bash
cp ~/.agent-gates/hooks/git/gate-shim.sh .githooks/pre-commit
cp ~/.agent-gates/hooks/git/gate-shim.sh .githooks/pre-merge-commit
chmod +x .githooks/pre-commit .githooks/pre-merge-commit
git config core.hooksPath .githooks
```

⚠️ **fast-forward merge 仍然没有钩子点** —— 它不产生 commit。合并进集成分支时用
`--no-ff`，否则那次合并不经过任何门禁。

#### ⭐ v2.9.0：验收 = 查需求遗漏，要逐条作答

CHECK 6 的目标不是再审一遍代码，是回答「**需求有没有被漏做**」。两种真实形态：
后端接口写了而前端一行没写（用户根本用不了）；需求 5 条只做了 4 条。

**这两类在 diff 里不留痕迹** —— CHECK 5 读 diff，看到的每一行都是对的；实现者自己写的
测试同样失明，它没做的部分自然没写测试。**测试全绿和需求少一半可以同时成立。**
所以清单必须来自需求，不能来自代码。

派发验收时先取出逐条提问，别让模型自己决定要答几条：

```bash
agent-gates-verify-harvest --emit-prompt --req-source .agent/plans/<需求>.md
# → 把输出塞进验收 prompt，它含编号需求 + REQ_ITEM 回答格式 + 状态表
agent-gates-verify-harvest <verify-run-id> --req-source .agent/plans/<需求>.md
# → 校验模型答满每一条；漏答直接拒绝（exit 3），不代填
```

需求源要有 `## 验收标准` 章节（其下每个一级列表项算一条），或 `features/**/*.feature`
的 `Scenario:`。`templates/plan.md` 是带该章节的模板。
⛔ 门禁刻意**不去数** `## 实现步骤` 下的 checkbox —— 那些是任务不是需求。

矩阵行格式（行首不能有列表符号或缩进，门禁严格按行首解析）：

```
REQ_ITEM: 1 | COVERED | api:src/export.ts:18, ui:~src/List.vue:88 | 按钮既有，本次补接口
```

| 状态 | 何时用 |
|---|---|
| `COVERED` | 本次改动实现了它（引用必须落在本次 staged diff 内） |
| `PREEXISTING` | 既有代码已覆盖，本次未改动 |
| `PARTIAL` | 只做了一部分 → 推导为 QUESTIONS |
| `DEFERRED` | 明确不在本次范围，写去向。**增量交付用这个，别回去删需求文档** |
| `NA` | 不适用，写理由 |
| `MISSING` | 该做而没做 → 推导为 FAIL |

证据 `<层面>:<路径>[:行号]`，层面 `ui`/`api`/`db`/`job`/`cfg`；路径带 `~` 表示既有未改
（`ui:~src/List.vue:88`）；非代码证据用 `RUN:` / `EXT:` / `NO_UI:<理由>`。

**触发时机**：`verify.require_matrix` 默认 `auto` —— strict 分支上、且仓库里真有带验收
章节的需求文档时才强制。特性分支上矩阵若已存在仍会解析并打印，但不阻断（迭代中需求
只完成一部分是正常的）。`true` 强制、`false` 关闭。

⚠️ 目标是「**无法静默绕过**」，不是「无法绕过」。`NA`/`DEFERRED`/`PREEXISTING` 都能用来
掩盖漏做，门禁只对它们计数打印。**门禁管形式，异构验收模型管实质** ——
「这条证据是否真完成了这条需求」是语义判断，脚本做不到，别指望它。

**② 审查在别处完成（外部模型、人工）⇒ 用 `agent-gates-verify-import`**

⚠️ 下面两阶段讲的是 **review 侧（CHECK 5）**，产出 `REVIEW_*` 锚点。
**CHECK 6 要的是另一种产物**（`VERIFY_VERDICT` 行 + 带 `staged_diff_hash` 的
`.dispatch.json`），别拿 review 产物去顶——v2.5.0 起 verify 侧有对称入口：

```bash
agent-gates-verify-import <body.md> --imported-model <provider/model>
agent-gates-verify-import <body.md> --paseo-agent <agent-id>
```

正文里必须已经有 `VERIFY_VERDICT: PASS|FAIL|QUESTIONS|INCOMPLETE`（工具不代填），
来源必须声明，锚点由工具计算。⛔ **不要手写 `.dispatch.json`** —— 那是伪造派发记录；
在 v2.5.0 之前那是唯一出路，现在不是了。

opencode 与 codex 都跑不了时，**不要停在这里、也不要伪造锚点**。走两阶段：

```bash
# 阶段 1：工具捕获锚点 + 快照 prompt + 发 token，退出码 77
agent-gates-review <prompt-file> --route paseo --dispatch-out /tmp/req.json

# 阶段 2 · 形式 A：派了 Paseo 子会话，来源可核实
agent-gates-review --import-result /tmp/review.md --token <token> \
  --paseo-agent <agent-id> --result .agent/reviews/<name>.md

# 阶段 2 · 形式 B：任意通道都行（opencode CLI / codex / 别的 agent / 人工看的）
agent-gates-review --import-result /tmp/review.md --token <token> \
  --imported-model "opencode/github-copilot/gpt-5.6-sol" --result .agent/reviews/<name>.md
```

**不规定通道，只规定证据。** 两种形式必须给一个，差别只在对来源是否诚实：A 记录已核实的 agent；B 记 `REVIEW_TOOL: external` 并把模型标 `unverified`。锚点保证两者相同。

`req.json` 的 `requirements` 块**照抄进子会话 prompt**，审查就不会回来时缺结论行。

派子会话时三件必知（都是实测踩过的）：

| 事项 | 说明 |
|---|---|
| **provider 不能是 claude** | 工具会核，同模型审查直接判失败（红线 #8） |
| **跨 provider 必须显式传 mode** | 不能从 claude 继承 `bypassPermissions`。opencode 可用：`Sisyphus - ultraworker` / `Hephaestus - Deep Agent` / `Atlas - Plan Executor` / `Prometheus - Plan Builder` |
| **agent 必须在派发之后创建** | 工具用 `paseo agent inspect <id> --json` 核 `CreatedAt`；拿一个旧 agent 顶账会被拒 |

导入失败时报错会指名原因：agent 找不到 / provider 是 claude / 早于派发 / 缺 `CreatedAt`（fail-closed）/ 缺 VERDICT 行 / 锚点已变 / 过期 / token 已用。其中**锚点已变与过期是不可重试的**（token 直接作废，重新派发），其余可以换个 agent 或补个结论行后用同一 token 重试。

⛔ 这条通道**不证明审查正文出自那个 agent** —— 它只证明你确实派了一个异构子会话。别把它当来源认证，也别据此放松自查。

### Tool Priority (⛔ Hard Constraint)

Cross-check MUST use a different model/vendor. Priority order:

| Priority | Tool | When to use |
| --- | --- | --- |
| 1. ⭐ **pi + heterogeneous model** (首选) | `pi -p --tools read,grep,find,ls --provider <provider> --model <model> "<prompt>"` （⚠️ `--provider` 与 `--model` 是**两个独立参数**，不能写成 `provider/model` 一串；prompt 是位置参数放最后） | **Default for all cross-checks** |

> 🔴 **`--tools read,grep,find,ls` 不是可选的。** pi 默认带 `edit` / `write` / `bash`，
> 审查者会直接动手改。2026-09-01 实测：一次代码审查里 gemini-3.1-pro 改了被审的源文件、
> 建了 `fix-harvest-reconcile` 分支、commit 两次 amend、**push 到了 GitHub**，
> 还顺手把工作树从我的业务分支切走了。
>
> 它那处改动**看起来完全合理**（在 harvest 里按矩阵推导更严的 verdict），实际违反了
> harvest「只做机械改写、不做判断」的契约，而且抹掉了门禁 E4 本会打印的差异 ——
> 一个似是而非的改动被静默应用，比一个明显的错误更难发现。
>
> 审查者只读是硬规则：它的产出是判断，不是补丁。
| 2. **codex CLI + GPT-5 series** (备选) | Two sub-commands (see below) | pi 不可用，或 prompt 过长 |
| 3. 🔻 **opencode CLI**（降级，需显式启用） | `opencode run --pure -m <provider/model> --dir <workdir> --format json "<prompt>"` | ⛔ **默认不要用**——见下方红字。仅在 pi 与 codex 都不可用时 |
| 4. **code-reviewer / critic agent** (兜底) | Same Claude model, different agent role | **Only when 1–3 are genuinely unavailable** (true L0 machine). NOT a shortcut when a heterogeneous tool is installed — see §8 "L0 Fallback is a VIOLATION When L1+ is Available". |

### ⛔ 为什么 opencode 从首选降到第 3（2026-08-26）

同一个审查任务实测：

| 路径 | 结果 |
|---|---|
| `agent-gates-review`（走 opencode 通道） | **120s 超时**，极小 prompt 也一样 |
| 手动 `opencode run --pure --attach` | **200s 超时** |
| `pi -p`（同一任务） | **~7s 返回**，evidence 立即可得 |

opencode 需要常驻 `opencode serve`；实测一个跑了 **4 天、烧掉 133 分钟 CPU、机器上零客户端**。
多个会话连续反馈「审查卡住导致任务无法进行」——**卡点在审查，不在开发**。

⚠️ **撞到 opencode 超时不要收窄 prompt 重试**——极小 prompt 也超时。换 pi。

agent-gates v2.4.0 起该通道默认关闭，v2.4.1 起 `oc-review` 在禁用时会**立即拒绝**
（exit 69，0 秒返回）并提示替代命令。要恢复：`HETERO_CHAN_OPENCODE=1` 或
`channels.opencode.enabled=true`。

### pi 的模型怎么选

> ⚠️ **2026-09-01 实测：`github-copilot/gpt-5.5` 返回 400 `resource not found`（连测 5 次）**，
> `gpt-5.2` 报 `model_not_supported`（已下架）。可用：`gpt-5.6-sol` / `luna` / `terra`、
> `gpt-5.4`、`gpt-5.3-codex`。**目录里列着 ≠ 账号可用** —— `~/.pi/agent/models-store.json`
> 里明明有 gpt-5.5。填具体型号前先探活，且**连测 ≥3 次**：我曾把一次 transient 的
> `gpt-5.6-sol` 失败当成「不可用」报了出去。
>
> ⚠️ `pi` 撞到这个 400 时**退出码是 0**，输出里只有那行错误。派后台审查只看退出码，
> 会把「模型不可用」当成「审查通过」—— 收割前必须确认输出里有 VERDICT 行。
>
> 策略那行不用改：`gpt-5.6` 就在「gpt-5.5 及以上」里。

⛔ 硬约束仍是**评审族 ≠ 实施族**，不是「必须用某个模型」。优先 gpt-5.5 及以上；没有就用
任何满足异构的模型；`deepseek-v4-flash` 性价比很高、推荐使用，**前提是先过异构校验**。
`~/.agent-gates/hetero-check.json` 里可配 `pi_models.primary` 与 `implementer_family`，
配了之后走 `agent-gates-review` **不需要每次指定**。

### Model Selection for Cross-Check

| Scenario | Recommended model |
| --- | --- |
| Development review (find bugs/gaps) | `github-copilot/gpt-5.6-sol` |
| Diagnosis / root-cause verification | `openai/gpt-5.5-pro` (strong reasoning) |
| Large document review | `github-copilot/gemini-3.1-pro-preview` (long context + different perspective) |
| Small patch / short code | code-reviewer agent (fast, acceptable for trivial) |

### opencode Command Template

**⚠️ Prompt length (v1.10.1 记录，v2.0.2 修正了适用范围)**：opencode run 非交互模式 prompt 超 ~800 字符曾观察到卡死（GPT-5.5 实测 800 字挂 22 分钟，短 prompt 秒回）。手动调用时仍建议**控制 prompt ≤200 字符**，背景让模型从 `--dir` 自己读代码——短 prompt 也更省 token。

⚠️ 两处需要知道的实际行为：

- `MAX_CHARS`（默认 800）的自动降级**只在 legacy L0-L3 路由生效**。配置里有 `review_models` / `hetero_models` 时走 hetero 分支，该分支不检查 prompt 长度，长 prompt 会照样发给 opencode。
- v2.0.2 起所有调用都有超时（`AG_REVIEW_TIMEOUT`，默认 300s），所以即使撞上这个现象，也是**一条明确的 timeout 报错**而不是无限期挂住。看到 `opencode timed out` 时，先怀疑 prompt 的探索范围没边界，再怀疑长度。

Parse script (extract plain text from `--format json` stream):

```bash
OC_PARSE='python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get(\"type\") == \"text\":
            print(obj.get(\"part\", {}).get(\"text\", \"\"), end=\"\")
    except: pass
"'
```

Short prompt (inline, recommended — keep ≤200 chars):

```bash
opencode run --pure -m github-copilot/gpt-5.6-sol --dir <workdir> --format json "<short prompt>" 2>&1 | eval "$OC_PARSE"
```

- Prompt file: `~/AgentWorkspace/tmp/<task>-prompt.md`
- Result file: `~/AgentWorkspace/tmp/<task>-result.md`
- Run with `run_in_background=true` to avoid blocking main session.
- **Do NOT stuff full file contents into prompt** — GPT-5.5 chokes on long non-interactive prompts. Instead, write a short instruction ("read file X, review for Y") and let the model read the file itself via its sandbox.

**⚠️ Common mistakes**:

| Wrong | Why | Correct |
| --- | --- | --- |
| `opencode run -p "prompt"` | `-p` is `--password`, not prompt | prompt is a positional arg — put it last |
| `> result.md` empty | default format is interactive, no output in non-TTY | add `--format json` + pipe through `OC_PARSE` |
| result contains JSON fragments | redirected without parsing | pipe through `OC_PARSE` before redirect |
| Long prompt (~800+ chars) | GPT-5.5 hangs/times out in non-interactive mode | Keep ≤200 chars; let model read files itself |
| Missing `--pure` | OMO Hephaestus injects intent detection + subtask dispatch | Always add `--pure` on both `serve` and `run` |

### codex Command Template (v1.10.1)

codex has **two sub-commands** for different review scenarios:

| Scenario | Command | Notes |
| --- | --- | --- |
| Review git diff/commit | `codex review --commit HEAD` (or `--base <branch>` / `--uncommitted`) | Built-in sandbox + structured output. **Cannot combine `--commit` with `[PROMPT]`** (mutually exclusive). |
| Review arbitrary content (design doc, plan, non-diff) | `codex exec -s read-only --skip-git-repo-check -C <dir> < prompt-file` | Prompt via **stdin** (not positional arg — positional hangs on "Reading additional input from stdin"). |

**Deprecated** (do NOT use):
- `codex -q --full-auto` — no `-q` flag in 0.134.0
- `codex-companion.mjs task --write` — old OMC plugin path, ~3 min timeout, unreliable

### Pre-Dispatch Requirements

Before sending work for cross-check, the prompt MUST include:

1. **Full context**: what was built, why, which files changed
2. **Original conclusions**: paste the implementer's self-assessment verbatim
3. **File list**: exact paths to review (no ambiguity)
4. **Output format**: specify expected review format (table, checklist, etc.)
5. **Explicit distrust instruction**: "Do not trust my conclusions. Read source and verify independently."
6. **Read-only constraint**: reviewer must NOT modify files

### Timeout / Failure Fallback

If Priority #1 (opencode CLI) times out or errors:
1. Retry once with shorter prompt (summary only, not full file contents).
2. If still fails → fall through to Priority #2 (codex CLI).
3. If codex also unavailable → fall through to Priority #3 (code-reviewer agent).
4. Document which tool was actually used in the review evidence.

### Non-Negotiable

- Cross-check failure → fix → re-verify. Never skip.
- Self-review by the same agent/model that wrote the code does NOT count.
- Evidence of cross-check must be available (reviewer output, pass/fail).
- Same-model same-agent self-review violates 红线 #8.

### Relationship to Three-Agent Pipeline

**Cross-Check (§1) and Three-Agent Review (§3) are SEPARATE mechanisms:**
- Three-Agent Pipeline = structured sequential review for implementation quality (can use same-model oracle agents)
- Cross-Check = final heterogeneous-model verification gate AFTER the pipeline passes

The Three-Agent Pipeline alone does NOT satisfy the Cross-Check requirement unless Role 2 or Role 3 uses Priority #1 or #2 tools (different model/vendor). If all three roles use same-model oracle, a separate Cross-Check step is still required before delivery.

---

## 2. When to Use Three-Agent Review vs Simplified Review

### Three-Agent Review (Full Pipeline) — REQUIRED when:

- Changes span ≥3 files
- Involves security, authentication, payment, or data migration
- User explicitly requests review
- Plan Review Gate (🔴) marked the task as critical
- Introduces new architecture patterns or external interfaces

### Simplified Review (Self-assessment + Single Oracle Check) — ALLOWED when:

- Single file, ≤20 lines of simple modification
- Pure configuration change (no business logic)
- Documentation / comment changes only

**When in doubt, use Full Pipeline.**

---

## 3. Three-Agent Review Pipeline

Strict sequential execution. No skipping or merging roles.

### Role 1: Implementer (Self-Assessment)

The agent that wrote the code produces a self-assessment report:

```markdown
## Self-Assessment Report

### Changes Summary
- [file:lines] — what was changed and why

### Tests
- New tests: [count], covering: [list scenarios]
- All tests passing: [yes/no, with evidence]
- Coverage of new code: [estimate]

### Known Risks
- [risk 1]
- [risk 2]

### Verification Evidence
- Build: [exit code]
- Lint: [0 errors / N warnings]
- Tests: [X passed, Y skipped, 0 failed]
```

**Deliverables:** Code + Tests + Self-Assessment Report

---

### Role 2: Spec Reviewer (Requirements Verification)

**Core principle: DO NOT trust the Implementer's self-assessment. Verify independently.**

#### Checklist (every item must be evaluated)

- [ ] Every requirement has a corresponding implementation
- [ ] Every requirement has corresponding test coverage
- [ ] Boundary conditions and error paths are handled
- [ ] Interface contracts (params, return types, error codes) match specification
- [ ] No requirements were silently dropped or partially implemented

**No formal spec document?** If requirements came from chat/ticket/verbal spec, the reviewer must first reconstruct requirements from the task description or PR body, confirm scope with implementer, THEN proceed with the checklist.

#### Output Format

```markdown
## Spec Review

| # | Requirement | Implementation | Test Coverage | Verdict |
|---|---|---|---|---|
| 1 | [requirement text] | [file:line] | [test file:line] | ✅ / ❌ |
| 2 | ... | ... | ... | ... |

### Issues (if any)
- ❌ REQ-2: [description of gap] — `src/auth.ts:42`
```

**Any ❌ blocks progression to Role 3.** Must fix and re-review.

---

### Role 3: Quality Reviewer (Code Quality & Security)

**Only starts AFTER Spec Reviewer gives all ✅.**

#### Checklist

- [ ] **Maintainability**: Clear naming, reasonable structure, acceptable complexity
- [ ] **Test quality**: Tests are meaningful (not just existence checks), cover edge cases
- [ ] **Code style**: Follows project conventions (not just linter rules)
- [ ] **Security**: No hardcoded secrets, injection risks, permission leaks, unsafe deserialization
- [ ] **Performance**: No obvious regressions (N+1 queries, unbounded loops, memory leaks)
- [ ] **Dependencies**: No unnecessary new dependencies; existing ones used correctly

#### Output Format

```markdown
## Quality Review

| # | Dimension | Verdict | Notes |
|---|---|---|---|
| 1 | Maintainability | ✅ / ⚠️ / ❌ | [details if not ✅] |
| 2 | Test quality | ✅ / ⚠️ / ❌ | ... |
| 3 | Code style | ✅ / ⚠️ / ❌ | ... |
| 4 | Security | ✅ / ⚠️ / ❌ | ... |
| 5 | Performance | ✅ / ⚠️ / ❌ | ... |
| 6 | Dependencies | ✅ / ⚠️ / ❌ | ... |

### Issues (if any)
- ❌ CRITICAL: [description] — `file:line`
- ⚠️ IMPORTANT: [description] — `file:line`
- 💡 SUGGESTION: [description] — `file:line`
```

---

## 4. Issue Severity & Handling

| Severity | Definition | Required Action |
| --- | --- | --- |
| ❌ Critical | Functional error, security vulnerability, data loss risk | Must fix → **restart full Three-Agent Pipeline** |
| ⚠️ Important | Poor maintainability, insufficient tests, performance risk | Must fix → **re-run Quality Reviewer only** |
| 💡 Suggestion | Style preference, optional optimization | Record but don't block delivery |

### Anti-Loop Rule

- Same issue: max **2 rounds** of fix-and-re-review
- After 2 rounds still unresolved → escalate to user for decision
- Re-review only covers modified code, not unchanged sections
- **Cascading new issues**: if a fix introduces >2 NEW issues (not the original), escalate to user instead of continuing fix cycles indefinitely

---

## 5. Review Delegation Patterns

### Cross-Check via opencode CLI (Priority #1 — PREFERRED)

Use this for the final cross-check gate after Three-Agent Pipeline passes:

```bash
# 1. Write prompt to file
cat > ~/AgentWorkspace/tmp/crosscheck-prompt.md << 'EOF'
# Cross-Review: [feature name]

You are independently reviewing work done by Claude. Do NOT trust the conclusions below — read source and verify yourself.

## Author's Self-Assessment
[paste implementer's self-assessment]

## Files to Review
- [file paths]

## Check Dimensions
1. Logic correctness and boundary conditions
2. Test coverage adequacy
3. Security (no hardcoded secrets, injection, permission leaks)
4. Code style consistency with project

## Output
Return: PASS or ISSUES with file:line references. Max 500 words.
EOF

# 2. Run with heterogeneous model
opencode run --pure -m github-copilot/gpt-5.6-sol --dir <workdir> --format json "$(cat ~/AgentWorkspace/tmp/crosscheck-prompt.md)" 2>&1 | eval "$OC_PARSE" > ~/AgentWorkspace/tmp/crosscheck-result.md &
```

### Three-Agent Pipeline Roles via oracle (same-model, for structured review)

> Note: These oracle-based patterns satisfy the Three-Agent Pipeline but do NOT satisfy the Cross-Check rule (§1) unless combined with a Priority #1 or #2 final gate.

### For Spec Review (Role 2)

```typescript
task(
  subagent_type="oracle",
  load_skills=["agent-review-protocol"],
  run_in_background=false,
  description="Spec review: [feature name]",
  prompt=`
TASK: Spec Review (Role 2 of Three-Agent Review Pipeline)
EXPECTED OUTCOME: Per-requirement verdict table with ✅ or ❌ for each item.
REQUIRED TOOLS: Read, Grep, Glob (read-only — NO edits)
MUST DO:
- Independently verify each requirement has implementation AND test coverage
- Check interface contracts match specification
- Check boundary/error paths
- Output the exact table format from agent-review-protocol skill §3 Role 2
MUST NOT DO:
- Trust the implementer's self-assessment
- Skip any requirement
- Edit any files
CONTEXT:
- Requirements: [path to requirements/spec]
- Implementation: [paths to changed files]
- Tests: [paths to test files]
- Self-assessment: [paste or reference]
`
)
```

### For Quality Review (Role 3)

```typescript
task(
  subagent_type="oracle",
  load_skills=["agent-review-protocol"],
  run_in_background=false,
  description="Quality review: [feature name]",
  prompt=`
TASK: Quality Review (Role 3 of Three-Agent Review Pipeline)
EXPECTED OUTCOME: Quality dimension table with ✅/⚠️/❌ verdicts.
REQUIRED TOOLS: Read, Grep, Glob (read-only — NO edits)
MUST DO:
- Evaluate all 6 dimensions: maintainability, test quality, code style, security, performance, dependencies
- Flag any ❌ Critical issues that block delivery
- Reference specific file:line for all issues
- Output the exact table format from agent-review-protocol skill §3 Role 3
MUST NOT DO:
- Edit any files
- Mark ⚠️/❌ without specific file:line evidence
- Skip security check
CONTEXT:
- Spec Review passed: [confirmed]
- Implementation: [paths to changed files]
- Tests: [paths to test files]
- Project conventions: [reference AGENTS.md or style guide]
`
)
```

### For Simplified Review (Single Check)

```typescript
task(
  subagent_type="oracle",
  load_skills=[],
  run_in_background=false,
  description="Quick review: [change summary]",
  prompt=`
Review this small change for correctness and style consistency.
Files: [paths]
Change: [summary]
Return: PASS or specific issues with file:line references.
`
)
```

---

## 6. Integration with Workflow

### When in the Development Cycle

```
Plan → Plan Review (agent-workflow-rules §3) → Implement (TDD) → Self-Assessment → 
Three-Agent Review (this skill) → Fix issues → Re-review → Deliver
```

### Relationship to Other Gates

| Gate | Governed by | When |
| --- | --- | --- |
| Plan Review | `agent-workflow-rules` §3 | Before implementation starts |
| TDD Enforcement | `agent-workflow-rules` §2 | During implementation |
| Verification | `agent-workflow-rules` §4 | Before claiming done |
| Code Review | **This skill** | After implementation, before delivery |
| Cross-Check | **This skill** §1 | Always, for any completed work |

---

## 7. Review Evidence Requirements

A review is NOT complete without:

- [ ] Reviewer output with per-item verdicts
- [ ] All ❌ items resolved (with fix evidence)
- [ ] Final reviewer output showing all ✅
- [ ] Tests passing after any review-prompted fixes

**Forbidden:** Claiming "reviewed" without reviewer output artifact.

---

## 8. Cross-Check Platform Routing

Before executing a Cross-Check (§1), the agent reads the persisted configuration `~/.agent-gates/review-capability.json` to select the review route. This replaces ad-hoc tool probing with deterministic, user-tunable routing.

### Route Priority (Waterfall)

Routes are tried top-to-bottom. A higher-priority route that is available and healthy always wins.

| Priority | Route | Command Pattern | Heterogeneous? |
| --- | --- | --- | --- |
| 1 (→ L3) | opencode CLI | `agent-gates-review <prompt-file>` (auto-routes; short prompt ≤200 chars) | Yes |
| 2 (→ L1) | codex CLI (arbitrary) | `codex exec -s read-only --skip-git-repo-check -C <workdir> < <prompt-file>` (prompt via **stdin**) | Yes |
| 2b (→ L1) | codex CLI (diff) | `codex review --commit HEAD` (or `--base <branch>` / `--uncommitted`; no custom prompt) | Yes |
| 3 (→ L1) | OMC codex plugin | Via `codex:codex-rescue` agent or `/ask codex` (agent-based, not CLI-drivable by `agent-gates-review`) | Yes |
| 4 | Paseo | `create_agent provider="codex/gpt-5.4" prompt="<review>" background=true` | Yes |
| 5 (→ L0) | Agent tool (ultimate fallback) | Claude Code Agent tool — same-model sub-agent | **No** |

Note: L0/L1/L2/L3 refer to capability levels set by `doctor.sh`, not route priority numbers. L3 = opencode + codex, L2 = opencode, L1 = codex or OMC plugin, L0 = none.

**Route 1 — use `oc-review`, not bare `opencode run`** (v1.13.0): `~/.agent-gates/bin/oc-review` wraps `opencode run` with **retry-on-empty** and **shared serve** management. It auto-starts a persistent `opencode serve --pure --port 4096` and injects `--attach` to route all runs through it, eliminating per-run serve stacking (the P1 memory leak that caused kernel panic). On persistent empty output it exits **75** with an `oc-review:`-prefixed stderr line → treat as route failure and fall through to route 2 (codex). Set `OC_SERVE_DISABLED=1` to skip serve integration. Orphaned serves are swept by `~/.agent-gates/bin/oc-reaper --apply`.

**Model selection (v1.13.0 D6)**: `doctor.sh` runs the D6 algorithm to detect available models, exclude flash/coding-vendor duplicates, probe reachability, and persist `review_models` in `review-capability.json`. Fields: `coding_vendor` (inferred from platform), `primary` (reverse-heterogeneous pick), `panel_pool` (verified alternative models), `panel_active` (concurrent reviewers). Static recommendations live in `~/.agent-gates/data/review-model-recommendations.json`.

**Route 2 — codex prompt MUST go via stdin** (`< prompt-file`), NOT as a positional arg. `codex exec "..."` blocks on "Reading additional input from stdin..." in non-TTY/background contexts. `-s read-only` sandboxes the reviewer so it physically cannot modify files.

L0 is always available but does NOT satisfy the heterogeneous-model requirement of §1.

### Routing Logic

```
read ~/.agent-gates/review-capability.json
  → config exists?
      → use preferred_route
        → execution succeeds within timeout?
            → done (record REVIEW_LEVEL)
        → fails or times out?
            → try fallback_route
              → also fails?
                  → ultimate_fallback: agent-tool (L0)
  → config missing?
      → go straight to agent-tool (L0)
      → emit warning: "review-capability.json not found — run doctor.sh to configure"
```

### REVIEW_LEVEL Header (Mandatory)

Every review output file MUST include a header indicating the actual review level and tool used:

```markdown
<!-- REVIEW_LEVEL: L2 -->
<!-- REVIEW_TOOL: opencode/gpt-5.5 -->
```

This enables auditing which reviews were truly heterogeneous and which fell back to same-model.

### Environment Adaptation

| Environment | Consideration |
| --- | --- |
| CI (`"env": "ci"`) | Review tools may exist but auth tokens differ from local; requires an extra health probe before selecting route |
| Container | Tool binary paths may differ from host; `review-capability.json` should use absolute paths or `$PATH` lookup |
| Windows / WSL | Path format adaptation (backslash vs forward slash); WSL can invoke host binaries via `wslpath` |

### Timeout Handling

Each route has a default timeout. When exceeded, the agent automatically falls through to the next route.

| Route | Default Timeout | Notes |
| --- | --- | --- |
| opencode CLI (L4) | 5 minutes | Generous — handles large diffs |
| codex CLI (L3) | 3 minutes | Known hard limit on background mode |
| OMC codex plugin (L2) | 3 minutes | Inherits codex timeout characteristics |
| Paseo (L1) | 5 minutes | Async; agent polls for completion |
| Agent tool (L0) | No timeout | Runs in-process |

### L0 Fallback is a VIOLATION When L1+ is Available (⛔)

The Agent-tool / same-model fallback (L0) is **only** acceptable on a genuine L0 machine — one where `review-capability.json` reports `level: L0` because no opencode/codex/OMC-plugin is installed. 

**If the machine's capability is L1 or higher, using the L0 same-model fallback is a VIOLATION of the different-model requirement (红线 #8), not an acceptable degradation.** "opencode hung once before" / "it's faster to just spawn a sub-agent" are NOT valid reasons to skip heterogeneous review when a heterogeneous tool is installed. Spawning `general-purpose` / `oracle` with no model override on an Opus session = Opus reviewing Opus = same model = does not count.

Real-world finding (2026-06-02 transcript mining): ~90% of cross-review sessions on L2/L3 machines silently fell back to same-model. That is why this is now physically enforced (below), not just convention.

### Physical Enforcement (v1.7.0)

The CLI pre-commit gate (`agent-quality-gate.sh`) reads `review-capability.json` and **blocks the commit** when:
- machine capability is `L1`/`L2`/`L3`, AND
- the latest review file has `REVIEW_LEVEL: L0` **or no `REVIEW_LEVEL` marker at all**.

So on any machine with opencode/codex installed, a review file MUST carry a `<!-- REVIEW_LEVEL: L1 -->` (or higher) header proving a different model was used. A true L0 machine is exempt (no alternative exists).

- Escape hatch (genuine exceptions only — stale config, emergency): `SKIP_HETERO_CHECK=1`.
- `REQUIRE_HETEROGENEOUS=1` is the agent-side equivalent for the in-session review flow (treat L0 as fail, not degraded pass).

**How to fix L0**: Install at least one external review tool to reach L1+:
- Fastest: `npm install -g @openai/codex` (L1 — GPT cross-review)
- Best: install opencode CLI from https://opencode.ai (L2 — multi-provider)

### hetero-check Dispatch (v2.0.0 — Verifier / CHECK 6)

The Verifier (CHECK 6) is dispatched via `lib/hetero/dispatch.sh` — a five-channel waterfall separate from the review routing above:

| Priority | Channel | Capability | Notes |
| --- | --- | --- | --- |
| 1 | **Paseo agent** | FULL | Required for high-risk paths (`is_high_risk_path`); interactive session |
| 2 | **opencode run** (fail-closed) | EVIDENCE_ONLY | `oc-review` wrapper; exit 75 on failure → next channel |
| 3 | **codex exec** | EVIDENCE_ONLY | Prompt via stdin; `-s read-only` sandbox |
| 4 | **codebuddy** | EVIDENCE_ONLY | `--acp` disabled by default (crash-loop guard from 12.5 GB incident) |
| 5 | **claude-agent** (same model) | EVIDENCE_ONLY | Forced INCOMPLETE on high-risk path |

**Effort injection** (`lib/hetero/select.sh`): risk-graded tier → per-channel flag: `--variant` (opencode), `--thinking` (codex), `-c model_reasoning_effort` (codebuddy).

**Shared serve** (`lib/hetero/serve.sh`): persistent `opencode serve --pure --port 4096` + `.draining` TOCTOU lock. Prevents per-run serve stacking (the 2.7 GB OOM incident). PGID kill (not `pkill -P`); wall-clock watcher; circuit-breaker with cold-start detection.

**High-risk enforcement**: high-risk path + EVIDENCE_ONLY capability → forced INCOMPLETE → requires `USER_ACK: PROCEED` in `.ack` file. Human writes `.ack` via `agent-gates-verify-ack` after manual inspection.

---

## 9. Review Prompt Templates

Pre-written prompt templates for each review role. These solve the "sub-agent doesn't know what to do" problem by giving structured, copy-paste-ready prompts with placeholders.

### 9.1 Spec Review Prompt (Role 2 — Requirements Verification)

```markdown
你是独立的 Spec Reviewer。不要信任实现者的自评,自己读源码验证。

## 任务
逐项验证每个需求是否有对应实现和测试覆盖。

## 需求来源
[粘贴需求描述或 PR body]

## 待审查文件
[列出文件路径]

## 输出格式 (严格遵守)

| # | 需求 | 实现位置 | 测试覆盖 | 判定 |
|---|------|---------|---------|------|
| 1 | [需求文本] | [file:line] | [test file:line] | ✅ / ❌ |

如有 ❌,在表格后列出具体差距。
最后一行必须是: VERDICT: PASS 或 VERDICT: ISSUES
```

### 9.2 Quality Review Prompt (Role 3 — Code Quality)

```markdown
你是独立的 Quality Reviewer。Spec Review 已通过,你只关注代码质量。

## 待审查文件
[列出文件路径]

## 检查维度 (每项必须评估)

| # | 维度 | 判定 | 说明 |
|---|------|------|------|
| 1 | 可维护性 | ✅/⚠️/❌ | 命名、结构、复杂度 |
| 2 | 测试质量 | ✅/⚠️/❌ | 有意义、覆盖边界 |
| 3 | 代码风格 | ✅/⚠️/❌ | 项目约定一致 |
| 4 | 安全 | ✅/⚠️/❌ | secrets、注入、权限 |
| 5 | 性能 | ✅/⚠️/❌ | N+1、无界循环、内存泄露 |
| 6 | 依赖合理性 | ✅/⚠️/❌ | 无多余依赖 |

如有 ❌/⚠️,给出 file:line 引用。
最后一行: VERDICT: PASS 或 VERDICT: ISSUES
```

### 9.3 Cross-Check Prompt (Heterogeneous Review)

```markdown
你在独立审查另一个 AI agent 的工作。不要信任下面的自评结论,自己读源码验证。

## 实现者自评
[粘贴自评报告]

## 待审查文件
[列出文件路径]

## 检查重点
1. 逻辑正确性 + 边界条件
2. 测试覆盖充分性
3. 安全 (hardcoded secrets, injection, permission)
4. 代码风格与项目约定一致性

## 输出要求
- 500 字以内
- 每个问题引用 file:line
- 最后一行: VERDICT: PASS 或 VERDICT: ISSUES
```

### 9.4 Usage

When performing a review, the agent:

1. Copies the appropriate template from above.
2. Fills in all `[placeholder]` fields with actual content (file paths, requirements, self-assessment).
3. Sends the completed prompt through the route selected by §8 (Cross-Check Platform Routing).
4. Parses the response for `VERDICT:` line to determine pass/fail.

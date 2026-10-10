# 审查级别策略：异构 > 同构 > 不查（v2.10.0 补充）

> 分支：`feat/review-budget`（已有 caa43e6 审查预算、2bb0c4d qwen 族修复）
> 用户 2026-10-11 定的规则：「只要遵循 异构 > 同构 > 不查 即可」，不强制具体模型

## 1. 问题

门禁不强制具体模型，只判审查者与实现者是否同族。但对照用户规则有五处不一致：

| # | 位置 | 现状 | 出入 |
|---|---|---|---|
| 1 | CHECK 3 计划审查（`agent-quality-gate.sh:384`） | 本机支持异构时，同族（L0）计划审查直接阻断 | 规则允许同构兜底 |
| 2 | CHECK 5 Gate 2b（`agent-quality-gate.sh` 「Review is same-model」） | L0 只有带 `HETERO_EXHAUSTED` 才放行 | 同上 |
| 3 | 不查 | 合 strict 分支没有审查记录就阻断；skill §1 与 README 写了 `SKIP_REVIEW=1`，hook 从未实现 | 最后一档走不通 |
| 4 | paseo 派发建议（`paseo_dispatch`） | 写死 `pi/github-copilot/gpt-5.6-sol`、`grok-4.5`（copilot 10-06 因费用移除） | 把人引向不可用通道 |
| 5 | 导入定级 | 免 token 导入一律记本机能力级别（L1），不看实际模型；paseo 导入遇到 claude provider 直接 exit 75 拒绝 | 一边不判、一边过严 |

**术语**：同构 = 与实现者同族、但在独立会话 / agent 里做的审查。实现会话自己的自评不算审查（不变）。

## 2. 设计

1. **CHECK 3**：L0 计划审查从 `_this_problem` 改为 `_this_warn`，文案「同族审查，按 异构 > 同构 > 不查 放行，记录在案」。不审计划的出口沿用已有 `SKIP_PLAN_CHECK=1`（文档写明是「不查」档）。
2. **CHECK 5 Gate 2b**：L0 无 `HETERO_EXHAUSTED` 从 `fail` 改为告警放行。**缺 `REVIEW_LEVEL` 标记仍阻断**：每份经 `agent-gates-review` 产出的产物都带这个标记，缺它说明产物不是工具产出的，属于产物完整性问题，与选什么模型无关。
3. **`SKIP_REVIEW=1`**：Gate 2 在 merge-only 跳过判断之后，`NEEDS_REVIEW=1` 且 `SKIP_REVIEW=1` ⇒ 大声打印「CHECK 5 skipped: SKIP_REVIEW=1 —— 不查档，报告里必须写明」并跳过 CHECK 5。只影响 CHECK 5，不影响 CHECK 6（`SKIP_VERIFY` 另有）与 Gate 2b 以外的检查。
4. **派发建议读配置**：`paseo_dispatch` 的 python 读 `$CAP_FILE` 里 `_get_review_models_key` 选出的键（`hetero_models` 优先，兼容旧配置；否则 `review_models`）的 `primary` / `panel_pool`，pi 通道开时前缀 `pi/`；无配置 ⇒ 写通用提示「任意异构模型（pi -p / codex exec）」；末尾加一条同构兜底说明（异构都不可用时，用同模型独立会话审查，导入时 `--imported-model` 写实际模型，会记 L0）。⛔ 不再出现写死的型号。
5. **导入按实际模型定级**：
   - 免 token 导入与 paseo 声明式导入：`hetero_families_differ "$IMPORTED_MODEL" "$实现者族"` 为真 ⇒ 记本机级别，否则记 L0。实现者族取 `HETERO_IMPLEMENTER_FAMILY` > `hetero-check.json` 的 `implementer_family`，与 `agent-gates-plan-review` 同口径；取不到 ⇒ L0（fail-closed，配合第 2 条只是告警）
   - paseo 已验证 agent：删掉 python 里「provider 含 claude ⇒ exit 5」，照常校验 createdAt 后输出 `<Provider>/<Model>`；bash 用同一个定级函数判族 —— 先看 Model 的族，认不出再看 Provider 的族（`claude` → anthropic、`codex` → openai）。⛔ 不能把 claude 固定判 L0：实现者是 OpenAI 族时 Claude 审查就是异构（计划审查 R1 阻断项 2）
   - 三条导入路径（免 token、带 token 声明式、带 token 已验证 agent）共用一个 `_review_level_for <model-desc>` 函数，结果写进 `append_marker` 用的级别；⛔ 不许某条路径继续沿用本机级别
   - 派发请求 `requirements.heterogeneous` 从「provider 不能是 claude」改为「优先异构；异构都不可用时可用同族模型的独立会话审查，导入后记 L0（告警放行）」（计划审查 R1 阻断项 1，`bin/agent-gates-review:858`）
   - CHECK 5 选产物：同一 diff 有多份 PASS 时优先选 `REVIEW_LEVEL` 为 L1+ 的那份，避免已有异构审查却打出 L0 告警
6. **文档**：`agent-review-protocol` §1（Non-Negotiable 里「同模型自审不算」改为区分自评与同构审查）、§8「L0 Fallback is a VIOLATION」与「Physical Enforcement」改写为三档顺序；README 中英、CHANGELOG 的 v2.10.0 段补充。

### 不做

- 不改全局红线 #8（「必须用不同模型/agent 做交叉检查」）——同构审查属于「不同 agent」已符合；「不查」与 #8 的关系交用户决定
- 不改直跑路由（`run_hetero_review`）的模型选择与 `HETERO_EXHAUSTED` 逻辑

## 3. 步骤（TDD）

1. **RED**：
   - `tests/run_gate_plan_review.sh` C4 改为「放行 + 输出含 L0 告警」
   - `tests/run_gate.sh` T12 改为「放行 + 输出含 L0 告警」；T11（缺标记）保持阻断
   - 新增 `tests/run_gate_skip_review.sh`：strict 档需要审查、无产物 ⇒ 阻断；`SKIP_REVIEW=1` ⇒ 放行且打印不查档；`SKIP_REVIEW=1` 不影响 CHECK 6
   - `tests/run_review_level_policy.sh`：
     - 免 token 导入：异构型号记 L1、同族（claude-opus）记 L0、认不出的记 L0；`HETERO_IMPLEMENTER_FAMILY=openai` 时 claude 型号记 L1、gpt 型号记 L0
     - 带 token 声明式导入（`--token` + `--imported-model`，无 `--paseo-agent`）同样按型号定级，⛔ 不沿用本机级别
     - 带 token 已验证 agent（假 paseo）：Provider=claude 导入成功记 L0；实现者 openai + Provider=claude 记 L1；Provider=opencode、Model=claude-opus-5 记 L0（按 Model 判族）
     - 派发建议：配置为百炼时含 `pi/bailian-token-plan/qwen3.8-max`、不含 `github-copilot`；`hetero_models` 键优先；无配置时给通用提示；`requirements.heterogeneous` 不再写「不能是 claude」
     - CHECK 5：同一 diff 一份 L0 PASS + 一份 L1 PASS ⇒ 不打 L0 告警
   - 跑一次确认失败
2. **GREEN**：按 §2 实现
3. 文档
4. 全量 `tests/run-all.sh`
5. 代码审查 R1 → 修 → R2 闭合轮（最多 2 轮）
6. 提交；合并 main；安装；同步全局规则镜像

## 4. 风险

| 风险 | 处理 |
|---|---|
| 放宽后 agent 图省事直接同构 | 工具路由仍先走异构；同构产物记 L0、门禁打印告警，报告可见；skill 写明顺序 |
| `SKIP_REVIEW=1` 被滥用 | 打印醒目告警；skill 要求只在同构也跑不了时用、报告写明 |
| 导入定级变严，原来记 L1 的同族导入现在记 L0 | 配合第 2 条只告警不阻断，不会新增卡点 |

<!-- PLAN_REVIEW: L1 -->
<!-- PLAN_REVIEW_TOOL: codex -->
<!-- PLAN_REVIEW_MODEL: codex/gpt-5.6-sol -->
<!-- PLAN_REVIEW_VERDICT: PASS -->
<!-- PLAN_REVIEW_SHA256: 0d776181ddcdb9a2dd6e533bbe7ab0a3cb8315ab904decce31be5104209d79ef -->
<!-- PLAN_REVIEW_AT: 2026-10-10T16:30:38Z -->
<!-- PLAN_REVIEW_RAW: VERDICT: PASS -->

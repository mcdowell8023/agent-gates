# 审查预算：限轮数、限数量、先验收后审查（v2.10.0）

> 分支：`feat/review-budget`（基于未合并的 `fix/review-stale-fail` de411a5，它已实现「后一轮 PASS 取代锚在旧状态的 FAIL」，用户 09-14 裁定先落地）
> worktree：`agent-gates-worktrees/review-budget`
> 用户确认：2026-10-10 会话（「嗯，同意」）

## 1. 要解决的问题

审查与测试的 token 花费过高，测试代码量超过业务代码。证据：

- 09-24 一次合并：6 轮审查、4 个审查 agent，输出约 7 万 token，cached 读约 2334 万 token，合计 $32（`memory/projects/agent-gates.md`）。大头是 Paseo 长会话反复重读上下文。
- wb 各仓 `strict_branches` 含 `test`：每批每仓在合 test、合 master 各要一份 review + verify，合 test 那份锚在 test 的 HEAD 上，合 master 时必然作废。
- 审查模板只有 PASS/ISSUES 两档、没规定「只有建议也写 PASS」；「测试不足」被定为必须修 ⇒ 每轮都要求补边界测试，补完 diff 变了又重审。
- 轮数没有硬上限。规则早写了「迭代期别审」，09-10 照样派出 11 个 agent —— 只写规则拦不住。

**成功标准**：每批（仓 + 源分支 + 目标分支）自动审查 ≤ 2 轮，第 3 轮必须带诊断理由才放行，且理由写进产物；合 test 默认不审；R2 只审阻断项与修复 diff。

## 2. 范围

### 做

| # | 改动 | 类型 |
|---|---|---|
| A | `agent-gates-review` 审查轮数上限：`review.max_rounds`（默认 2）、`--escalated "<理由>"`、exit 73、产物加 `REVIEW_BATCH` / `REVIEW_ROUND` / `REVIEW_ESCALATED` 标记；`--due` 增加 `rounds_used` / `rounds_max` 两行 | 代码 |
| B | Gate 1 支持 `tests.exempt` glob 豁免；不配置时行为不变 | 代码 |
| C | `agent-review-protocol` / `agent-workflow-rules` skill 文本：单审查员、阻断/建议分列、VERDICT 只看阻断、测试维度收窄、合 master 标准顺序、R2 闭合轮模板、不收敛诊断表、计划审查 ≤ 2 轮 | 文档 |
| D | README（中英）、CHANGELOG、`.version` → 2.10.0；全局规则镜像 `~/.claude/rules/global/30-delegation.md`、`10-workflow.md` 同步 skill | 文档 |
| E | wb 各仓 `.agent/gates.json` 的 `strict_branches` 删 `test`（33 个文件，先备份） | 配置 |

### 不做（自查过度设计后砍掉）

- 审查结果跨 strict 分支复用（master 前进时 R2 在最新 master 上做，导入时锚点当场算即可）
- 合 test「高风险路径例外」的代码实现（test 审不审交给配置）
- verify（CHECK 6）的轮数上限：规则写「整批 1 次、放在最后」，代码暂不限，后续真出现重复 verify 再加
- TDD 红线 #6 的默认范围调整（用户另定）；B 只提供配置能力
- 并发写共享库的加锁

## 3. 设计

### A. 审查轮数上限（`bin/agent-gates-review`）

**批次键** `REVIEW_BATCH = <目标分支>|<源分支>|<实例>`（R1 审查阻断项 1：没有实例边界时，同一对分支第二次合并会开局就超限，护栏变永久锁）：
- 目标分支 = `git rev-parse --abbrev-ref HEAD`
- 处于 merge 暂存（`git rev-parse --git-path MERGE_HEAD` 存在）：
  - 源分支先从 `MERGE_MSG` 首行解析 `Merge branch '<x>'`，失败再用 `git name-rev --name-only --refs='refs/heads/*' MERGE_HEAD` 并去掉 `~N` / `^N`；都失败用 `MERGE_HEAD@<短 sha>`（计数会在源分支前进后重置 —— 预算护栏不是安全边界，文档写明）
  - 实例 = `git merge-base HEAD MERGE_HEAD` 的短 sha。同一批内：功能分支追加修复、master 被别人前进，merge-base 都不变；上一批合进去之后，同一对分支再合，merge-base 前移 ⇒ 自动成为新批次。功能分支把 master 合进来同步冲突也会让 merge-base 前移、计数重置（宽松方向的失效，可接受，文档写明）
  - 源分支名仍要保留：两个从同一 master 提交切出的功能分支 merge-base 相同，只靠实例会串
- 不在 merge 中：源分支 = 目标分支，实例 = `HEAD` 短 sha（每次直接提交各算一批）

**轮次定义**：共享库（`artifact_store_dir reviews`）里 `REVIEW_BATCH` 相同的产物，按 `REVIEW_DIFF_SHA256` 去重计数。同一份暂存状态重复审（包括按模块拆开的多份）只算一轮；改了代码再审算新一轮；master 前进导致 HEAD 变化也算新一轮。无 `REVIEW_BATCH` 标记的历史产物不计。

**上限**：`AGENT_GATES_REVIEW_MAX_ROUNDS` > 项目 `.agent/gates.json` 的 `review.max_rounds` > 用户 `~/.agent-gates/gates.json` > 默认 2；`0` = 不限；非法值告警并按 2。复用 `lib/gate-mode.sh` 的 `_gate_cfg_get`。

**检查点**：新函数 `_review_round_check`，放在 `_review_due_check` 之后、路由之前 ⇒ 覆盖直跑、`--route paseo` 派发、`--import-result`（带或不带 token）三条路径。未启用锚点（没暂存内容 / 不在 git 里）或共享库不可用 ⇒ 跳过并在 stderr 说明。

**超限**：当前 diff 已计入 ⇒ 不是新一轮，放行。否则 `已用轮数 >= 上限` ⇒ exit 73，提示停止打补丁、按 skill 的不收敛诊断表处理；`--escalated "<理由>"`（理由非空，否则 exit 1）放行并告警，理由压成单行、去掉 `-->` 后写入 `<!-- REVIEW_ESCALATED: ... -->`。

**标记**：`append_marker` 在锚点标记后追加 `<!-- REVIEW_BATCH: ... -->`、`<!-- REVIEW_ROUND: <n> -->`（n 含本轮）。

**`--due`**：契约（exit 0/79、key=value 行）不变，只追加 `rounds_used=` / `rounds_max=` 两行，给绕过 CLI 直接派 Paseo 的派发侧在花钱前判断。skill 写明：先暂存 merge 再问；`rounds_used >= rounds_max` 时不要派审查。
- R1 审查阻断项 2：`--due` 在 `bin/agent-gates-review:192` 就退出，而 `sha256_stream`、`review_staged_*`、`artifact_store_dir` 定义在其后 ⇒ 实现时把这几个纯函数和新增的轮次函数**上移到 `--due` 分支之前**；`--due` 仍不读 capability、不写产物、不调模型。测试断言 `rounds_used` 是实际数字而非空串
- `--escalated` 加入 `--due` 的互斥清单（与 `--early` 同样处理），否则会静默降级成只查询却 exit 0

### B. Gate 1 豁免（`hooks/git/agent-quality-gate.sh`）

- 配置 `tests.exempt`（glob 列表），项目配置整份优先于用户配置（与 `strict_branches` 同口径）。⛔ 不能用 `_gate_cfg_get`：它对列表打印 Python repr（`['docs/*']`），glob 永远不命中、豁免静默失效 ⇒ 仿 `_gate_strict_branches` 写列表读取器，无内置默认
- 文档不夸大收益：Path A 仓的 CHECK 2（`.feature`）与 CHECK 6 需求矩阵不受影响
- Gate 1 循环开头：命中任一 glob ⇒ 跳过并计数；循环后打印 `ℹ️ Gate 1: N file(s) exempt via tests.exempt`（列前 5 个），⛔ 不静默放行
- glob 语义：匹配仓库相对路径，bash `[[ == ]]` 模式，`*` 跨目录
- 改动集中在一处，减少与未合并的 `fix/gate-accept-suffixed-spec`（同样改 Gate 1）合并时的冲突

### C. skill 文本要点

`agent-review-protocol`：
- §2：合并点默认**单个异构审查员**，清单合并需求核对与质量；三 Agent 流水线只在用户明确要求时用（需求遗漏由 CHECK 6 verify 负责，不重复）
- §2.5：判据二表格改为「合 test 默认不审（配置决定）」；新增合 master 标准顺序：验收通过 → R1 整批 → 修 → 部署 test 定向回归 → R2 闭合轮 → verify → 合；审查单元 = 一个仓，diff > 约 1500 行才拆；跑法用一次性 CLI（`codex exec` / `pi -p`），只喂 diff 与需求文档，不开长会话；轮数上限与 `--escalated`
- §4：阻断项须带具体失败场景并关联验收标准（或安全 / 数据丢失）；VERDICT: ISSUES 当且仅当有阻断项；某条验收标准完全没有测试 = 阻断，补边界测试 = 建议；Anti-Loop 改为轮数上限 + 不收敛诊断表（越界挑刺 → 降级不找用户；过度设计 → 删代码；方向错 → 回方案层；真缺陷且修复成本高 → 才找用户，只问「带已知问题上线还是延期」）
- §9：9.2 / 9.3 模板按阻断/建议分列 + 结论规则；新增 9.5 R2 闭合轮模板、9.6 不收敛诊断报告模板

`agent-workflow-rules`：§2.6 补轮数上限与 `rounds_used`；§7 计划审查 ≤ 2 轮（R1 全量、R2 闭合），第 3 轮须诊断。

### E. wb 配置

- 备份到 `~/AgentWorkspace/configs/backups/wb-gates-json-2026-10-10/`（保留相对路径）
- 用 python 读 JSON、从 `strict_branches` 删 `test`、更新 `_note`、`indent=2, ensure_ascii=False` 写回
- 现状：37 个 `gates.json` 里 4 个主仓（crm-center、crm-platform、empower-business、wb-project-service）已经没有 `test`，剩 33 个要改
- 验证：**逐个文件**断言可解析、含 `strict_branches` 键、改后不含 `test`（缺键会回落到用户配置或内置默认 `test/master/main`，删了等于没删）；再抽一个仓在 test 分支跑 `--due` 得 `due=no`、在 master 得 `due=yes`
- 回滚：从备份目录拷回

## 4. 执行步骤（TDD）

1. **RED** `tests/run_review_rounds.sh`：① R1、R2（不同 diff）导入成功，产物带 BATCH/ROUND 标记 ② 同一 diff 重复导入不占新轮 ③ R3 exit 73 且提示诊断 ④ R3 带 `--escalated` 成功、产物带 ESCALATED ⑤ `--escalated ""` exit 1 ⑥ 不同源分支独立计数 ⑦ `max_rounds=0` 不限、env 覆盖配置、非法值按 2 ⑧ `--route paseo` 在 R3 被拒且不签发 token（显式构造 capability fixture 与 node 依赖，防止以 exit 75 冒充 73）⑨ `--due` 输出 rounds 两行、`rounds_used` 为实际数字、退出码不变；`--due --escalated` exit 1 ⑩ merge 暂存时批次键取 MERGE_MSG 的源分支 ⑪ 同一对分支第一批合并完成后再合第二批，从第 1 轮开始计 ⑫ 同一批内 master 前进（HEAD 变、merge-base 不变）仍计入同一批。跑一次确认失败
2. **GREEN** 实现 A，跑新测试 + `run_review_due.sh` + `run_review_import_tokenless.sh`
3. **RED** `tests/run_gate_test_exempt.sh`：无配置行为不变；命中豁免放行并打印；未命中仍拦；用户级配置生效、项目级整份覆盖。确认失败
4. **GREEN** 实现 B
5. 文档 C、D
6. 全量 `tests/run-all.sh`、`bash -n`、`git diff --check`
7. 交叉审查（按本计划自己的规则）：R1 一次性异构审查整批 → 修 → R2 闭合轮；仍不收敛按诊断表处理
8. E（wb 配置），验证
9. 写 inbox 记忆；向用户汇报，合并 main / 安装到 `~/.agent-gates` / push 等用户确认

## 5. 风险与回滚

| 风险 | 处理 |
|---|---|
| 默认 2 轮对所有安装生效，第 3 次审查直接 exit 73 | 报错写清原因与 `--escalated`、`max_rounds=0` 两条出路；CHANGELOG 标 behavior change |
| 批次键靠分支名，改名或 detached merge 会重置计数 | 文档写明是预算护栏；不做安全承诺 |
| 计数在导入时生效，绕过 CLI 自己跑的审查 token 已经花掉 | `--due` 给派发侧 rounds 信息 + skill 硬性要求派发前先问 |
| test 移出 strict 后坏代码进共用 test 环境 | 非 strict 分支的 merge 整段跳过门禁（`agent-quality-gate.sh:114-119`），合 test 时 Gate 1 / CHECK 3 也不跑；但这些提交在功能分支上 commit 时已过 Gate 1 / CHECK 3（merge-only 只放宽审查）。配置可随时加回；破坏性 migration / 外发消息类改动按 skill 规定部署前单独审 |
| 与未合并的 `fix/gate-accept-suffixed-spec` 在 Gate 1 冲突 | 改动集中在循环开头一处 |

回滚：代码 revert 本分支；配置从备份拷回。

<!-- PLAN_REVIEW: L0 -->
<!-- PLAN_REVIEW_TOOL: pi -->
<!-- PLAN_REVIEW_MODEL: bailian-token-plan/qwen3.8-max -->
<!-- PLAN_REVIEW_VERDICT: PASS -->
<!-- PLAN_REVIEW_SHA256: a46661f55584b9fe9affb2b21f8f94a025384b81911fd28ca6342c261938bede -->
<!-- PLAN_REVIEW_AT: 2026-10-10T08:03:08Z -->
<!-- PLAN_REVIEW_RAW: VERDICT: PASS -->

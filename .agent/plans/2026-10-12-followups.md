# 遗留问题收口（v2.11.0）

> 分支：`fix/followups-1012`（基于 main `7ba820d`，v2.10.2）
> 起因：用户 2026-10-12「既然发现问题，你得处理啊」—— 处理 v2.10.x 过程中发现、记为后续待办的问题

## 1. 问题（均已实测或读码确认）

| # | 问题 | 证据 |
|---|---|---|
| 1 | 安装器每次都装回 Memory skill（`SKILLS=(... memory ...)` 写死），用户 10-07 已按 Plan A 移除它，每次装完都要手工还原；且 SKILL.md 备份是**原地** `SKILL.md.bak.<ts>`（规则禁止），触发条件是「新旧内容不同」—— 升级时必然不同，于是每次都备份，还误报成「本地改过」 | `install.sh:26`、`backup_if_modified()`；10-11 / 10-12 三次安装实测 |
| 2 | 门禁两处读 `REVIEW_LEVEL` 口径不一：Gate 2b 用 `grep … \| head -1`，择优用 `tail -1`；且两处都匹配**正文里**的 `REVIEW_LEVEL: Lx` 字样。审查正文引用这串文字（本仓的审查记录就有）会被当成标记：正文写了 L0 ⇒ 误报同族；正文写了 L1 而没有真正标记 ⇒ 绕过「缺标记阻断」 | `agent-quality-gate.sh` Gate 2b、`_gate_rf_is_hetero` |
| 3 | paseo 验证 agent 的报错文案写 `paseo agent ls --json`，实际调用的是 `agent inspect <id> --json` | `bin/agent-gates-review` `_paseo_verify_agent` 与 rc 3 / 7 文案 |
| 4 | CHECK 3 只要 `.agent/plans/` 里**任意一份**计划审查有效就放行，与本次改动无关也算 | 实测：放一份「三个月前另一件事」的已审计划，新改动无计划 ⇒ `PASSED`；拿走 ⇒ 被拦 |
| 5 | 提醒钩子 `memory-reminder.mjs` 文案写死「用 Memory skill → save(…)」，本机三个平台都启用；与用户现行规则（红线 #12：inbox 脚本）不符，Memory skill 也已移除 | `hooks/platform/memory-reminder.mjs:32-45`；`~/.claude/settings.json` 等三处登记 |

## 2. 设计

### 1. 安装器

- 新增 `--skip-memory-skill`：本次不装 bundled `memory`、不建它的软链，并写标记 `$INSTALL_DIR/.skip-memory-skill`，**之后的安装都沿用**；`--with-memory-skill` 删标记恢复。有标记时打印一行说明，不静默
- 备份移出 skill 目录：`$INSTALL_DIR/backups/skills/<skill>/SKILL.md.<ts>`
- 只在「已装的 SKILL.md 与上次安装记录的 sha256 不同」时备份；每次安装后把各 SKILL.md 的 sha256 写进 `$INSTALL_DIR/installed-skills.sha256`，**按目标文件的绝对路径记**（`<sha256>  <绝对路径>`）—— 只按 skill 名记的话，`--target` 装过别的目录后会把本地改过的文件误判为未改、不备份就覆盖（计划审查 R1 阻断项 2）。没有该路径的记录（首次 / 老版本升级 / 新目标）⇒ 保守备份一次。文案改为「与上次安装的版本不同（可能被本地修改）」
- `--skip-memory-skill` 遇到已存在的 `memory` 目录或软链：⛔ 不自动删除，打印逐条路径与清理命令
- `uninstall.sh --purge-backups` 同时清 `$INSTALL_DIR/backups/skills/` 与旧的原地 `SKILL.md.bak.*`；安装结束的提示文案改指新位置
- 本机：用 `--skip-memory-skill` 跑一次，之后不再装回

### 2. 审查级别标记的读取

- 新增 `_gate_rf_level <file>`：只认整行 `<!-- REVIEW_LEVEL: L[0-3] -->`（允许首尾空白），取**最后一个**（标记追加在正文之后）
- Gate 2b 与 `_gate_rf_is_hetero` 都改用它；缺标记仍阻断
- `doctor.sh` 检查最近审查记录是否 L0 的那处（同样是正文子串匹配）改用同一口径

### 3. paseo 报错文案

- rc 3 / rc 7 文案改为 `paseo agent inspect <id> --json`

### 4. CHECK 3 绑定分支（兼容旧标记）

- `agent-gates-plan-review` 记录时追加 `<!-- PLAN_REVIEW_BRANCH: <当前分支> -->`（detached HEAD 不写）。哈希本来就剥掉全部 `PLAN_REVIEW_*` 行，不受影响
- 新增 `agent-gates-plan-review <plan> --rebind`：零 token 补绑 —— 校验现有 `PLAN_REVIEW_SHA256` 与计划正文一致、结论为 PASS，才把 `PLAN_REVIEW_BRANCH` 改成当前分支；哈希不符（计划审后又改过）拒绝
- CHECK 3 判定：
  - 绑定到**当前分支**的有效计划 ⇒ 放行
  - 绑定到**别的分支** ⇒ 不算覆盖本次改动（新行为，只影响 v2.11 起记录的计划）
  - **未绑定**（v2.11 之前记录的）⇒ 照旧放行（保持原作者「旧标记必须放行」的兼容承诺），但告警列出文件名，并**按类型给提示**（计划审查 R1 阻断项 1）：
    - 有 `PLAN_REVIEW_SHA256` 与结论（v2.9–v2.10 用工具记录的）⇒ `agent-gates-plan-review <plan> --rebind`
    - 没有哈希 / 结论（更早手写的标记）⇒ `--rebind` 做不了；提示用审查正文重新记录（`--result … --model …`），或本次用 `SKIP_PLAN_CHECK=1`
  - 处于 merge（`MERGE_HEAD` 存在）⇒ 跳过 CHECK 3 并打印一行。理由：计划是「写代码时的纪律」，功能分支逐次提交时已检查；wb 这类 `.agent/` 被 gitignore 的仓库，计划留在功能分支 worktree，主仓看不到。⚠️ 已知局限：合并时解决冲突新加的改动不经 CHECK 3，由合并点的 CHECK 5 审查（审的是整份合并 diff）兜住
  - detached HEAD ⇒ 不做绑定判断，告警
- 失败提示列出「找到但不覆盖本次改动」的计划及原因（绑定别的分支 / 哈希不符 / 结论非 PASS）

### 5. 提醒文案可配置

- `memory-reminder.mjs`：`$AGENT_GATES_DIR/memory-reminder.md`（默认 `~/.agent-gates/`）存在且非空 ⇒ 用它作 todo 完成提醒的正文，否则用内置文案；读失败一律回落内置、exit 0（钩子不得阻塞）
- 本机写这个文件，内容按红线 #12：用 `memory-inbox-add.sh` 写 inbox

### 不做

- CHECK 3 对未绑定旧计划改为阻断（会破坏所有已部署仓库，原作者明确禁止；改为告警 + 零成本补绑）
- 自动探测重复的 memory skill 并去重
- 提醒钩子的并行提醒文案（与本问题无关）

## 3. 步骤（TDD）

1. RED → GREEN 逐项：
   - #2 `tests/run_gate.sh`：正文含 `REVIEW_LEVEL: L0` 而标记为 L1 ⇒ 无同族告警；正文含 `REVIEW_LEVEL: L1` 而无标记 ⇒ 阻断
   - #3 `tests/run_review_paseo_channel.sh`：假 paseo 的 inspect 失败 ⇒ 报错含 `agent inspect`
   - #4 `tests/run_gate_plan_review.sh` / `tests/run_plan_review.sh`：记录写入 BRANCH；绑定当前分支放行；绑定别的分支不放行且提示；未绑定放行 + 告警 + rebind 提示；`--rebind` 哈希一致才成功；merge 时 CHECK 3 跳过；原有夹具里手写的计划标记按需补 BRANCH 或保留未绑定（验证兼容）
   - #1 `tests/run_install.sh` 或新文件：`--skip-memory-skill` 不装 memory 并写标记、下次沿用、`--with-memory-skill` 恢复；备份落在 `$INSTALL_DIR/backups/`、skill 目录内无 `.bak`；未改动的 SKILL.md 不备份、改过的才备份
   - #5 `tests/run.sh` 夹具：有自定义文件用自定义文案；文件为空 / 不可读回落内置
2. 文档：README 中英、CHANGELOG、`.version` → 2.11.0；`init-project-gates` / `agent-review-protocol` 中涉及 CHECK 3 与 `--rebind` 的说明
3. `tests/run-all.sh` 全量
4. 代码审查：推荐不强制，有异构通道就跑 R1（最多 2 轮）
5. 合并 main、`install.sh --local --skip-memory-skill`、写本机提醒文案；推送需用户确认

## 4. 风险

| 风险 | 处理 |
|---|---|
| CHECK 3 新行为让在途功能（v2.11 后记录、绑定了别的分支名）被拦 | 只影响 v2.11 起记录的计划；失败提示给出 `--rebind` 一条命令 |
| 未绑定旧计划仍可放行无关改动 | 告警点名文件 + rebind 提示，从「静默」变「可见」；新记录的计划全部绑定 |
| merge 时跳过 CHECK 3 | 现状下 merge 时 CHECK 3 实际靠「任意旧计划」通过，没有真实约束；跳过并打印更诚实 |
| 安装器 sha256 清单缺失时仍会备份一次 | 备份在 skill 目录外，不违反规则；之后有清单即准确 |

<!-- PLAN_REVIEW: L1 -->
<!-- PLAN_REVIEW_TOOL: pi -->
<!-- PLAN_REVIEW_MODEL: volcengine-coding/glm-5.3 -->
<!-- PLAN_REVIEW_VERDICT: PASS -->
<!-- PLAN_REVIEW_SHA256: a27afb7a0fea061fd2e7bc2e73c9bbca88c5a955d82922710237021273ced866 -->
<!-- PLAN_REVIEW_AT: 2026-10-12T04:10:40Z -->
<!-- PLAN_REVIEW_RAW: VERDICT: PASS -->
<!-- PLAN_REVIEW_BRANCH: fix/followups-1012 -->

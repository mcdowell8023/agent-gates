# Changelog

All notable changes to agent-gates will be documented in this file.

## [1.6.0] - 2026-05-29

### Added (跨平台审查路由 — 磨平不同 AI agent 平台的审查能力差距)

- **`doctor.sh` 新增 `check_cross_review_capability`** — 每次 doctor 运行时重新检测所有异构审查工具(opencode CLI / codex CLI / OMC codex 插件 / Paseo),计算能力等级(L0-L3),写入 `~/.agent-gates/review-capability.json` 持久化配置。含 CI / Windows / WSL / 容器环境检测。L0 时输出升级建议。
- **`install.sh` 新增 `detect_review_capability`** — 安装时首次检测审查能力,写入持久化配置。L0 时输出详细安装引导(codex CLI / opencode CLI)。
- **`agent-review-protocol` SKILL.md §8 Cross-Check Platform Routing** — 审查时读 `review-capability.json`,按优先级瀑布式路由: opencode → codex → OMC codex plugin → Paseo → agent-tool (最终兜底)。含超时处理、环境适配、`REQUIRE_HETEROGENEOUS=1` 严格模式。
- **`agent-review-protocol` SKILL.md §9 Review Prompt Templates** — 预写好 Spec Review / Quality Review / Cross-Check 三套 prompt 模板,解决"子 agent 不知道干啥"的问题。
- **`~/.agent-gates/review-capability.json`** — 新增持久化配置文件,记录决策树(5 个路线的可用性 + 路径 + 版本)、能力等级、首选/备选/兜底路线。

### Changed
- **`agent-workflow-rules` SKILL.md §12.1** — 交叉审查 tool priority 从固定列表改为引用 `agent-review-protocol` §8 自适应路由。新增 `REVIEW_LEVEL` 强制标注要求。

### Design Decisions
- 决策树在 install/doctor 时确定并持久化,审查时只读配置 + 失败回退,不做实时检测
- Paseo 标注可用但不参与自动等级计算(它是编排层不是审查工具)
- L0 (同模型审查) 默认 warn 不阻塞,可通过 `REQUIRE_HETEROGENEOUS=1` 升级为 fail
- review 文件必须标注 `<!-- REVIEW_LEVEL: L0/L1/L2/L3 -->` 供 doctor 事后检查

### Notes
- gpt-5.5 异构审查 VERDICT: REVISE → 采纳 4 条(health probe / 迁移表 / REVIEW_LEVEL / 失败回退) + CI/Win/容器
- 后置 9 项(D1-D9)记录在方案文档,留 Rampart 跟进
- 方案文档: `~/AgentWorkspace/docs/research/v1.6-cross-review-routing.md`

## [1.5.5] - 2026-05-28

### Fixed (E2E 测试发现的两个小改进)
- **`hooks/git/agent-quality-gate.sh` trivial skip 加 info 输出** — 之前 trivial 改动直接 `exit 0` 静默，用户看 commit 输出不知道 gate 是否运行过。现在输出 `✅ Agent Quality Gate: trivial change skipped (N file(s), +N lines)` 让用户明确知道 gate 工作了并决定跳过。
- **`doctor.sh check_hook_output_schema` 使用 `|| return 0`** — 之前 `[[ -f "$mjs" ]] || return` 在 `set -e` + 残缺 mock 环境下会触发隐式 return 非 0 让脚本中止，summary 不输出。改为显式 `return 0` 保证 graceful skip。仅 mock / 残缺安装场景触发，实际用户安装无感知。

### Notes
- 两项均为 E2E 测试发现的非阻塞改进（v1.5.4 全部 79/79 测试通过，但这两项 UX/健壮性可以更好）
- 测试: 60 unit + 19 E2E = 79 pass / 0 fail（无回归）

## [1.5.4] - 2026-05-28

### Changed (Memory skill 从 sparse-clone 改为内置)
- **`skills/memory/`** 新增 — fork 自 [clawic/skills](https://github.com/clawic/skills) MIT 的 `skills/memory/` 子目录（6 个文件：`SKILL.md` / `_meta.json` / `memory-template.md` / `patterns.md` / `setup.md` / `troubleshooting.md`）+ 新增 `UPSTREAM.md` 标明 attribution 和上游同步流程。
- **`install.sh` SKILLS 数组** 加 `memory` — 走标准 `install_skills()` 流程（与 `init-project-gates` / `agent-workflow-rules` / `agent-review-protocol` / `init-deep-fallback` 同等地位）。
- **删除 `install_memory_skill()` 函数 + sparse-clone 逻辑** — 不再需要 install 时 git clone clawic/skills。安装更稳（无网络依赖）+ 更快（直接 cp）。
- **删除 `check_memory_skill_installed()` 函数**（dead code，无调用方）+ 删除 `MEMORY_SKILL_REPO` / `MEMORY_SKILL_SUBPATH` 常量。
- **`install_external_deps()` 简化** — 只剩 Superpowers + OpenSpec 两层（Memory 已交给 `install_skills()`）。

### Removed
- 网络依赖（针对 Memory skill）— 内网用户 / CI / 离线环境也能装

### Documentation
- README.md / README.zh-CN.md 双语同步：Architecture 目录树补 `memory/` + `init-deep-fallback/` + Auto-Installed Dependencies 表 Memory 行从 "sparse-clone" → "Bundled"（attribution 指向 `skills/memory/UPSTREAM.md`）+ Skills 表加 memory + init-deep-fallback 两行
- docs/explainer.zh.md L156 sparse-clone 描述同步更新
- `skills/memory/UPSTREAM.md` 记录 fork 来源 / 同步命令 / license attribution

### Test Coverage
- `tests/run_install.sh` T7 改为验证 `skills/memory/SKILL.md` 内置存在（替代旧 `check_memory_skill_installed` 测试）

### Notes
- Superpowers 14 个 skill **不内置**（仓库 ~MB 级，且 obra/superpowers 更新频繁，sparse-clone 更合理）
- Memory skill 与 clawic 上游分叉风险：v1.5.4 fork 时与上游字节一致；后续 clawic 更新由 agent-gates 维护者按 UPSTREAM.md 手动同步（频率低，clawic 自身 Memory skill 已稳定在 v1.0.2）

## [1.5.3] - 2026-05-28

### Fixed
- **`doctor.sh` banner 动态版本号** — 之前 hardcode `Agent Gates Doctor v1.5`，v1.5.1 / v1.5.2 升级后 banner 不变，给用户造成"装的版本是不是没生效"的错觉。改为从 `~/.agent-gates/.version` 动态读取并居中对齐（自动 padding，支持任意长度版本号如 `v1.5.3` / `v2.0.0-beta` / `v10.0.0` 都不破坏 box 框线）。
- `.version` 缺失时 banner 显示 `Agent Gates Doctor v?`（不再误报）。

### Notes
- 纯 cosmetic patch，零功能变更。
- 所有测试不受影响（doctor 内部 check_* 函数行为不变）。
- v1.5.4 计划：Memory skill 内置（fork `clawic/skills/skills/memory/` 到 `agent-gates/skills/memory/`，避免 install 时网络依赖）。

## [1.5.2] - 2026-05-28

### Added (依赖自动安装)
- **`install.sh` 默认自动安装外部依赖**（强制依赖开箱即用）：
  - **Memory skill** — sparse-clone `clawic/skills`（MIT），仅 `skills/memory/`，复制到主 platform skill dir。已装则 skip。
  - **Superpowers 14 个 skill** — clone `obra/superpowers`，全部 `skills/*` 复制。已装 5 个 hardcore（test-driven-development / brainstorming / verification-before-completion / writing-plans / executing-plans）则 skip 整批。
  - **OpenSpec CLI** — 检测 `which openspec`，缺失时**交互式询问 y/N** 执行 `npm install -g @openspec/cli`。非交互 shell 默认 N。明确告知用户全局环境影响（红线 #2）。
- `--skip-deps` 参数：opt-out 外部依赖安装（CI / 老用户保留入口）

### Fixed (平台检测一致性)
- **F1: `doctor.sh check_omc_registration`** 加"未装则 skip"前置 — 与 OMO/OMX 行为对齐。之前 Claude Code 未装时 doctor 报 WARN "settings.json missing — not initialized?"，现在改为 NOTE skip "OMC not installed"。
- **F2: `install.sh` OMO 自动 hook 注册** — 之前 v1.4 标记为 "automated registration not yet supported"，现已确认 OMO `~/.config/opencode/hooks.json` schema 等价 OMC/OMX，复用 `register_hook()` jq 注册逻辑，OpenCode 用户不再需要手动配置。

### Changed (init-project-gates Step 6)
- **跨平台 init 决策树**（D 方案 — `/init` 兜底）：
  1. Claude Code + OMC plugin 装了 → OMC `deepinit` (hierarchy)
  2. OpenCode + OMO 包装了 → `/init-deep` (hierarchy)
  3. 任意 platform → 平台原生 `/init` (单根)
  4. 都不行 → agent 手写最小根 AGENTS.md
- 不强制装 OMC/OMO plugin；hierarchy 是 nice-to-have。跨平台统一接口留待 Rampart 基座层。

### Removed (脱敏)
- `init-project-gates/SKILL.md` 删除 `pingcode-log` 引用（公司内部 PingCode 工时工具）
- `init-project-gates/SKILL.md` 删除 `waza-check` 引用（无功能依赖的关联文档）
- `templates/PROGRESS.md` "PingCode 工时参考" → "工时参考"（脱敏）
- CLAUDE.md 注入模板里的 "PingCode" 字样泛化为 "工时"

### Test Coverage
- run.sh: 6 pass
- run_doctor.sh: **19 pass**（v1.5.1 17 + F1 OMC skip 2 个新测试）
- run_gate.sh: 14 pass
- run_install.sh: **12 pass**（v1.5.1 5 + 7 个新 auto-deps 测试）
- run_codegraph_hook.sh: 9 pass
- **总计: 60 pass / 0 fail**（v1.5.1 是 51）

### Notes
- v1.5.2 仍是 agent-gates 的维护版。**Rampart 是基座重构**，会磨平各 platform 差异（rampart init-deep 统一接口，自动选 OMC/OMO/fallback）。
- 现在的 v1.5.2 用户开箱可用：装好就有 Memory + Superpowers，OpenSpec 询问后装，hook 自动注册到所有已装 platform。

## [1.5.1] - 2026-05-28

### Added
- **`doctor.sh check_superpowers_install`**(TDD 实现) — 检测 5 个上游 superpowers skill (test-driven-development / brainstorming / verification-before-completion / writing-plans / executing-plans) 在 5 个平台 skill dir (~/.claude/skills、~/.config/opencode/skills、~/.codex/skills、~/.cc-switch/skills、~/.agents/skills) 的存在。全部 found → PASS;部分 → WARN 列出 missing;全无 → WARN 提示 install URL。`tests/run_doctor.sh` 加 5 个新测试 (17/17 全绿)。
- **CodeGraph chpwd hook 集成**(v1.4 后遗留功能) — `hooks/shell/codegraph-chpwd.zsh` + `tests/run_codegraph_hook.sh` (9/9 通过) + `install.sh --codegraph-hook` 参数注册到 `~/.zshrc` + `init-project-gates` 可选 Step 7 引导。Cherry-picked from feat/codegraph-chpwd (e41c5d6)。
- **`agent-workflow-rules` SKILL.md §17 迭代收敛规则**(同步到 `~/.claude/rules/global/10-workflow.md`) — 同一文档/实现 ≥ 2 轮独立审查仍 REVISE → 强制反思整体思路,禁止继续 patch。来源:Drift Review v0.1→v0.3 教训。
- **`agent-workflow-rules` SKILL.md §18 团队模式 / 并行优先**(同步到镜像) — 复杂多任务必须优先并行派出子 agent,≥ 2 个互不依赖子任务必须并行。

### Fixed
- 无 (v1.5.0 ship 后未发现需修复缺陷)

### Notes
- v1.5.1 是 agent-gates 的**最后一个 feature 版本**。后续工作转移到独立仓 **Rampart** (基座 + 可扩展模块架构重构)。agent-gates 进入维护状态,仅做安全/兼容性修复。
- Vault `BDD-CLI-Gate-OpenSpec整合方案.md` §实施现状对照表同步更新到 v1.5.1 (100% 对齐设计层)。

### Test Coverage
- run.sh: 6/6
- run_doctor.sh: 17/17 (v1.5 12 + v1.5.1 新增 5)
- run_gate.sh: 14/14
- run_install.sh: 5/5
- run_codegraph_hook.sh: 9/9
- **总计: 51/51 pass** (v1.5.0 是 37/37)

## [1.5.0] - 2026-05-27

### Added
- **`agent-quality-gate.sh` v1.5** — two new pre-commit checks for Path A (OpenSpec) projects:
  - **CHECK 1**: `openspec/changes/` must contain at least one active change directory. Blocks commit when the directory exists but is empty.
  - **CHECK 2**: New source files in Path A projects require `features/*.feature` BDD scenarios. Blocks commit when no `.feature` files exist.
  - Path detection added: auto-detects Path A via `openspec/changes/`, `.opencode/skills/openspec-propose/`, or `.claude/skills/openspec-propose/`. Path B projects skip CHECK 1 and CHECK 2.
- **`doctor.sh` v1.5** — `check_bdd_step_definitions`: detects `features/step_definitions/` and counts step definition files (`.ts`, `.js`, `.py`, `.java`, `.rb`). PASS when files found, WARN when missing.
- **`install.sh` v1.5** — `--with-openspec` flag: checks for `openspec` CLI on PATH, reports version or install instructions.
  - New `check_openspec()` function.
- **BDD scaffolding templates** in `templates/features/`:
  - `example.feature` — starter Gherkin scenario
  - `step_definitions/example.steps.ts` — TypeScript (Cucumber.js)
  - `step_definitions/example_steps.py` — Python (pytest-bdd)
  - `step_definitions/ExampleSteps.java` — Java (Cucumber-JVM)
- **`init-project-gates` SKILL.md** — Step 5b: BDD scaffolding for Path A projects. Auto-detects project stack and copies matching templates.
- **`agent-workflow-rules` SKILL.md** — §6.6 (step definitions directory structure), §6.7 (scenario reference in TDD RED), §6.8 (commit message scenario reference).
- **Tests**: `tests/run_gate.sh` (11 tests for CHECK 1 + CHECK 2), `tests/run_install.sh` (5 tests for --with-openspec), 3 new tests in `tests/run_doctor.sh`.

### Documentation
- **README** — new "BDD Quick Start" and "OpenSpec Integration" sections. Updated gate descriptions and doctor sample output to include CHECK 1, CHECK 2, and step_definitions check.

### Why
- v1.4.0 had zero integration points for OpenSpec and BDD despite them being core to the Path A workflow design. CHECK 1 + CHECK 2 close the gap between the documented rules and actual enforcement. BDD templates lower the adoption friction for teams starting with Gherkin.

## [1.4.0] - 2026-05-22

### Added
- **`doctor.sh` v1.4** — two new project-level checks that run when the cwd is a git repo (detected via `[[ -d .git ]] || [[ -f .git ]]`, no `git` binary needed so Xcode-license issues on macOS don't break the check):
  - `check_openspec_install` — detects `.opencode/skills/openspec-propose/`, `.claude/skills/openspec-propose/`, or `openspec/changes/` and reports which workflow path applies (Path A with OpenSpec vs Path B without). PASS when present, informational `note` when absent.
  - `check_bdd_features_dir` — counts `features/*.feature` files. PASS when ≥1 file present, WARN when `features/` exists but is empty (Path A requires BDD scenarios), `note` when the directory is absent.
- Banner bumped to `Agent Gates Doctor v1.4`.
- `tests/run_doctor.sh` — 5 new test cases covering: OpenSpec detected via `openspec/changes/`, OpenSpec absent (informational), `.feature` files present, `features/` empty WARN, project-level checks skip when not in a git repo. 9/9 tests pass.

### Documentation
- **README** — new `Workflow Paths: A (OpenSpec) vs B (no OpenSpec)` section explaining auto-detection, planning/acceptance/implementation differences per path, and the shared `agent-workflow-rules` skill as canonical source. Doctor sample output updated to 13 PASS lines reflecting the new checks.
- **`docs/platform-hooks.md`** — new `Project-level checks (v1.4)` addendum clarifying that the doctor's openspec/bdd checks are unrelated to the platform hook registration and only run inside a git repo.
- **Global rule sync** (`~/.claude/rules/global/10-workflow.md`) — rewritten as a concise mirror that points to `agent-workflow-rules` SKILL.md as the canonical source. Keeps the entry-point essentials (intent recognition, 🔴 Skill Gate hard gates, trivial standard, anti-pattern self-check, red-line references) and routes section detail (TDD / OpenSpec / BDD / Plan Review / CLI Gate / Verification / Anti-Over-Engineering / Debugging) through the skill's §3–§16. Conflict resolution: skill wins.

### Why
- v1.3.x doctor only inspected platform/hook health; project-level workflow readiness (OpenSpec install, BDD `.feature` coverage) was invisible. v1.4 surfaces both so agents and users know which workflow path applies before starting work.
- The global 10-workflow.md and the skill SKILL.md had drifted into two near-duplicates that contradicted on small points. The mirror pattern (skill = canonical, global rule = pointer) eliminates the maintenance trap and matches the convention used elsewhere in the rule system.

### Known limitations
- `doctor.sh` does not yet probe upstream `agent-superpowers` skills (`test-driven-development`, `brainstorming`, `verification-before-completion`, `opsx:explore`). The workflow rules and global mirror reference them as hard Skill Gate triggers, but their presence is currently the user's responsibility. A `check_superpowers_install` analogous to `check_openspec_install` is planned for v1.5.
- `install.sh` does not auto-install upstream skills or the OpenSpec CLI. This is intentional per the project's destructive-command red line — third-party tooling must be installed by the user (see README "Upstream skill dependencies"). The installer prints candidate paths when missing but never mutates the system on the user's behalf.

## [1.3.1] - 2026-05-22

### Fixed (three equal-priority P0 regressions in v1.3.0 doctor.sh)

- **P0-1 — Missing OMO health check.** `doctor.sh` covered OMC and OMX but had no `check_omo_registration` for the OpenCode platform. v1.3.1 adds it: skips with `note` when `~/.config/opencode/` is absent, otherwise validates `~/.config/opencode/hooks.json` contains a `.hooks.PostToolUse[].hooks[].command` matching `memory-reminder` (jq probe). Returns `WARN` when the file or hook is missing — matches the existing OMX behavior. The OpenCode platform is now first-class in the health report.
- **P0-2 — Matcher-mismatch silently passed.** When OMC `settings.json` contained a memory-reminder hook but the matcher lacked `TaskUpdate`, the v1.3.0 code path reported `WARN`. That is the exact failure mode v1.1.2 was created to surface — Claude Code's current tool name is `TaskUpdate`, so a matcher without it means the hook never fires. v1.3.1 reclassifies this branch to `FAIL` so doctor exits non-zero and CI / users get a clear signal to re-run `install.sh`.
- **P0-3 — Pipeline hang on no-match transcripts.** `check_transcript_errors` used `find … | xargs -0 grep -l … | xargs grep -l "memory-reminder" | wc -l`. On macOS BSD `xargs`, an empty stdin makes the second `xargs` invoke `grep` with no file arguments, which then blocks reading from stdin — the script hangs forever. v1.3.1 rewrites the function with a `while IFS= read -r f; do … done < <(find …)` loop that has no `xargs`, no pipefail interaction, and no empty-stdin trap. Also avoids a second class of bug from the obvious "just add `|| true`" patch: a partially-failing pipeline produced concatenated output (e.g., `"4\n0"`) that broke the `== "0"` comparison and showed garbled counts.

### Tests
- New `tests/run_doctor.sh` — sources `doctor.sh` under a mocked `$HOME` and `$INSTALL_DIR`, invokes the affected check functions directly, asserts the `PASS / WARN / FAIL` arrays.
  - `P0-1`: OMO hook detected → `PASS`.
  - `P0-1b`: OMO hook missing → not `PASS` (either `WARN` or `FAIL`).
  - `P0-2`: OMC matcher missing `TaskUpdate` → `FAIL`.
  - `P0-3`: `check_transcript_errors` completes in <5s on transcripts with no matches.
  - `P0-3b`: companion direct-pipeline reproducer that demonstrates the original BSD-xargs hang (informational; the function-level test above is the real assertion).

### Cross-platform notes
- The transcript scan now works identically on macOS (BSD xargs) and Linux (GNU xargs) — both have the same hang behavior on the original code, both work cleanly with the while-read loop.

## [1.3.0] - 2026-05-22

### Added
- **`doctor.sh`** — standalone deployment health-check tool. 10 checks: node ≥18, jq, Memory skill detection, local `.version`, remote `.version` parity, hook files present + executable, OMC `settings.json` hook registration (with matcher inspection for `TaskUpdate` presence), OMX `~/.codex/hooks.json` registration, end-to-end hook output schema validation (executes `memory-reminder.mjs` with a sample payload and asserts `hookEventName=PostToolUse` + reminder body contains the `AGENT-GATES` tag), and a 7-day transcript scan for `hook_non_blocking_error` related to memory-reminder. Outputs `PASS / WARN / FAIL` table + summary count. Exits `0` on no-fail (warnings allowed), `1` on any fail — CI-friendly. Flags: `--quiet`, `--no-network`, `--help`.
- `install.sh` now deploys `doctor.sh` to `$INSTALL_DIR/doctor.sh` alongside the hook scripts. The "Done!" summary points users to the verify path.
- README: new `Doctor` section with sample output, flag table, and CI usage hint.

### Why
- The v1.2.1 root cause (missing `hookEventName` field) was invisible without inspecting transcript JSONL — there was no easy way for a user to confirm "hook is actually wired up correctly". Doctor turns that into one command.

## [1.2.1] - 2026-05-22

### Fixed (critical)
- **`memory-reminder.mjs`**: emitted JSON now includes the required `hookSpecificOutput.hookEventName: "PostToolUse"` field. Without it, Claude Code's hook-output validator rejects the response, writes a `hook_non_blocking_error` attachment to the session transcript (visible in `~/.claude/projects/<repo>/<session>.jsonl`), and **silently drops the reminder**. Net effect: `[AGENT-GATES: Memory Persistence Reminder]` never reached the agent on Claude Code since the hook's introduction.
- End-to-end verified by spawning a fresh Paseo `claude/sonnet` agent in `cwd=~/Projects/agent-gates`, having it call `TaskCreate` + `TaskUpdate(status=completed)`, then reading back the injected reminder verbatim. Pre-fix run reported `NO`; post-fix run reported `YES` with the first three lines of the reminder body matching.

### Discovery context
- v1.1.2 fixed where the hook is registered (`settings.json` not `hooks.json`) and the matcher (`TaskUpdate`/`TaskCreate` added). That made Claude Code attempt to invoke our hook for the first time — at which point the schema mismatch surfaced. v1.0.0–v1.2.0 all had this defect; it was latent because earlier sessions never reached the validator code path.

## [1.2.0] - 2025-05-21

### Added
- **agent-workflow-rules SKILL.md §8 Memory Persistence (⛔ Hard Constraint)** — new section detailing when to save (each completed todo, each phase delivery, session end), how to act on the `[AGENT-GATES: Memory Persistence Reminder]` system-reminder injected by `memory-reminder.mjs`, what to record, what NOT to save, loading prior memory on session start, and the no-Memory-skill fallback flow using `.agent/PROGRESS.md` + `.agent/memory/`.
- §0 Precedence note updated to describe the new §8 in relation to global rules.

### Changed
- Renumbered subsequent SKILL.md sections: Progress Tracking → §9, Anti-Pattern Self-Check → §10, Completion Definition → §11.

## [1.1.2] - 2025-05-21

### Fixed (critical)
- **install.sh**: hook registration now writes to `~/.claude/settings.json` `.hooks.PostToolUse[]` for OMC and `~/.codex/hooks.json` `.hooks.PostToolUse[]` for OMX. Previously wrote to `~/.claude/hooks.json` and root-level `.PostToolUse`, which **Claude Code does not read** — meaning the memory-reminder hook never actually fired on Claude Code since v1.0.0.
- **install.sh**: PostToolUse matcher expanded from `TodoWrite|todowrite` to `TodoWrite|todowrite|TaskUpdate|TaskCreate` to cover Claude Code's current todo tool names. The old matcher never matched on Claude Code installations.
- **install.sh**: `register_hook` now uses the nested `.hooks.PostToolUse` schema for both OMC and OMX, idempotent merge via `jq` that preserves all unrelated top-level settings.json keys (model, permissions, theme, etc.).
- **uninstall.sh**: removes hook entries from `~/.claude/settings.json` and `~/.codex/hooks.json` using the nested schema; preserves all other settings.json keys; also sweeps the legacy `~/.claude/hooks.json` path so users on prior versions get cleaned up.

### Changed
- README "Supported Platforms" table now shows the actual config file path and schema per platform; OMO marked as manual until v1.2.0.
- OMO automated registration deferred — added warning + manual instructions in installer output.

### Known limitations
- Claude Code does NOT hot-reload `settings.json`. Hook activation requires a new Claude Code session after install.

## [1.1.1] - 2025-05-21

### Added
- `install.sh`: hard `check_dependencies` for Node.js ≥18 (fails with install hint when missing)
- `install.sh`: `check_optional_deps` — detects `jq` and Memory skill, prints platform-specific install commands when missing (does not auto-mutate system)
- `install.sh`: backs up user-modified `SKILL.md` as `SKILL.md.bak.<timestamp>` before overwriting on upgrade; final summary lists all backups
- `install.sh`: `--upgrade` alias for `--force`; `--help` flag with usage
- `uninstall.sh`: `--purge-backups` to remove generated `SKILL.md.bak.*` files; `--help` flag
- README: Prerequisites entry for Memory skill; new `Upgrade` section with limitations; new `Troubleshooting` table

### Changed
- Installer "Done" summary now lists backed-up skill files and a per-project hook upgrade reminder
- `register_hook_json` fallback message now includes the platform-specific `jq` install command

## [1.1.0] - 2025-05-21

### Fixed
- **memory-reminder.mjs**: False-positive detection when todo content contains "completed"/"done" — now checks `todos[].status` field specifically
- **install.sh**: Can now merge into existing `hooks.json` via `jq` (previously required manual merge)
- **install.sh**: Detects OMO (OpenCode) override path `~/.config/opencode/hooks.json`

### Added
- `uninstall.sh` for clean removal of hooks, skills, and platform registrations
- `.version` file for version pinning and upgrade detection
- `tests/` directory with hook test fixtures and runner
- Code readability improvements (stdin fd, exit code, fallback regex documentation)

## [1.0.0] - 2025-05-20

### Added
- Initial monorepo structure with 3 skills: `init-project-gates`, `agent-workflow-rules`, `agent-review-protocol`
- `hooks/git/agent-quality-gate.sh` v1.3 — test correspondence + cross-review enforcement
- `hooks/platform/memory-reminder.mjs` — PostToolUse hook for Memory persistence reminders
- `install.sh` — multi-platform installer with auto-detection
- `templates/.agent/` — project-level PROGRESS.md, GATES.md, .gitignore
- `docs/platform-hooks.md` — hook registration documentation
- `README.md` — architecture overview and quick-start guide

---
name: agent-workflow-rules
description: "Canonical runtime workflow for agent-assisted development: intent recognition, Path-A (OpenSpec) vs Path-B routing, TDD, BDD scenario alignment, plan review, verification, anti-over-engineering, cross-review enforcement, memory persistence, and CLI pre-commit gate semantics. Load this skill in any project where agents write code. Triggers: 'workflow rules', 'TDD', 'BDD', 'OpenSpec', 'plan review', 'cli gate', 'AGENT_MODE', '工作流规则', '开发纪律', '团队项目', 'agent discipline', 'quality workflow'."
---

# Agent Workflow Rules

Runtime development discipline for AI coding agents. This skill governs HOW the agent works within a project — intent recognition, coding flow routing (team/OpenSpec vs individual), test-driven development with BDD scenario alignment, plan review before execution, evidence-based verification, minimal implementation, cross-review, memory persistence, and CLI pre-commit gate semantics.

**Authority**: This skill is the **canonical source** of agent workflow rules. The global `~/.claude/rules/global/10-workflow.md` mirrors these sections for agents that don't load skills directly. **On conflict, this skill wins.** When updating a rule, edit the skill first and only sync the global file second.

**Companion skills:**
- `init-project-gates` — one-time project setup (`.agent/`, AGENTS.md, pre-commit hook)
- `agent-review-protocol` — Three-Agent Review pipeline + cross-check tooling

---

## 1. Intent Recognition (Re-Evaluate Every User Message)

Re-evaluate user intent from the **current** message each turn. Do NOT auto-inherit "implementation mode" from prior turns.

| Phrase | True intent | Default behavior |
| --- | --- | --- |
| "Explain X" / "How does Y work" | Understand / research | Search → synthesize answer |
| "Implement X" / "Add Y" / "Create Z" | Implement | Plan → execute → verify |
| "Look at X" / "Investigate Y" | Investigate | Explore → report findings |
| "What do you think of X" | Evaluate | Analyze → recommend → wait for confirmation |
| "X is broken" / "Y errors" | Fix | Diagnose → minimal fix |
| "Refactor" / "Optimize" / "Clean up" | Open-ended change | First assess codebase → propose plan |

Only when the current message explicitly requests implementation/modification AND scope is concrete, start coding. If still gathering context or evaluating, do NOT create implementation todos.

---

## 2. Skill Gate (Mandatory Checkpoint)

After identifying user intent but BEFORE starting work, scan installed skills and load those matching the task.

```text
Intent identified → 【Skill Gate: scan → load】 → Path A/B routing → start work
```

### Enforcement Tiers

| Tier | Meaning | Skip condition |
| --- | --- | --- |
| 🔴 Hard gate | Must load, skip = violation | None |
| 🟡 Strong default | Should load, skip needs reason | Task meets trivial criteria |
| 🟢 Domain match | Load when domain involved | Task doesn't touch that domain |

### 🔴 Hard Gates (Never Skip)

| Trigger | Must do |
| --- | --- |
| Writing production code (feature / bugfix / refactor) | Follow §4 TDD Flow |
| Creative work (new feature, new component, behavior change) | Explore requirements first (brainstorming or §5 OpenSpec `opsx:explore`) |
| Non-trivial change in a team project (has OpenSpec) | Confirm OpenSpec change + `.feature` exist (§5, §6) |
| Multi-step plan ready for execution | **Plan review** (§7) |
| About to claim "done" / "fixed" / "passing" | Follow §9 Verification Gate |

### 🟡 Strong Defaults

| Trigger | Should do |
| --- | --- |
| Multi-step implementation | Write plan before coding |
| Bug / test failure / unexpected behavior | Systematic debugging (§11) |
| Implementation complete, ready to deliver | Request code review (§12 cross-review) |

### Trivial Criteria (May Skip 🟡 and 🟢)

ALL of the following must be true:
- ≤ 1 file involved
- ≤ 10 lines changed
- No new exports, routes, or components

**🔴 Hard gates are NEVER skipped, even for trivial tasks.**

### Scope Escalation

If task grows beyond initial classification (trivial → multi-file, or bugfix → refactor), PAUSE and re-run Skill Gate.

---

## 3. Coding Flow Routing — Path A vs Path B

Non-trivial coding tasks branch by project type:

### Path A — Team Project (has OpenSpec)

Project has `.opencode/skills/openspec-propose/` or `.claude/skills/openspec-propose/`:

```text
opsx:explore → opsx:propose (含 .feature) → 🔴 plan-review → opsx:apply (BDD-TDD)
  → spec-review → quality-review → CLI gate → opsx:archive → complete
```

Stages:

- **opsx:explore** (§5.1): replaces `brainstorming`; deep requirement / approach exploration. 🔴 hard gate satisfied.
- **opsx:propose** (§5.2): generates `proposal.md` + `specs.md` (must reference `features/*.feature`) + `design.md` + `tasks.md` (each step references a scenario). Replaces `writing-plans`.
- **🔴 plan-review** (§7): Oracle review including `.feature` reasonableness.
- **opsx:apply** (§5.3): execute `tasks.md` step by step, each tied to a scenario. §4 TDD remains required (NOT replaced by opsx:apply).
- **spec-review / quality-review** (§12): Three-Agent Review pipeline.
- **CLI gate** (§8): pre-commit hook auto-checks (`AGENT_MODE=1` only).
- **opsx:archive** (§5.4): archive the change. Complements §9 Verification.

### Path A — Skill Gate Mapping

| Path A stage | Replaces this gate | Status |
| --- | --- | --- |
| `opsx:explore` | `brainstorming` 🔴 | Satisfies hard gate |
| `opsx:propose` | `writing-plans` 🟡 | Satisfies strong default |
| `opsx:apply` | **Does NOT replace** §4 TDD 🔴 | TDD still required |
| CLI gate + `opsx:archive` | Complements §9 Verification 🔴 | Both run |

### Path B — Individual / No-OpenSpec Project

```text
brainstorming → plan → 🔴 plan-review → implement → spec-review → quality-review
  → verify → complete
```

Inherits the existing flow (`brainstorming` + `writing-plans` + §4 TDD + §9 Verification).

### Path Detection

On project open, the agent checks:

- File `.opencode/skills/openspec-propose/SKILL.md` exists → Path A
- File `.claude/skills/openspec-propose/SKILL.md` exists → Path A
- Otherwise → Path B

Both paths share the same plan review gate (§7) and TDD flow (§4).

---

## 4. Standard TDD Flow (⛔ Hard Constraint)

All code development — new features, bug fixes, refactoring, behavior changes — MUST follow RED → GREEN → REFACTOR. No exceptions without explicit user authorization.

### 4.1 Three Phases

1. **RED**: Write a test for the target behavior. Run it. **Watch it fail.**
   - Failure must be "target doesn't exist / behaves wrong" — not syntax/import errors.
   - Do NOT proceed until you see failure evidence.
   - **Path A (team project)**: acceptance tests MUST implement step definitions for the corresponding `.feature` scenario (§6). Don't soften scenario `Then` conditions.

2. **GREEN**: Write the **minimum** implementation to make that test pass.
   - Only code that turns the current red test green. Nothing else.
   - Run tests. Confirm target test passes AND existing tests still pass.

3. **REFACTOR**: Clean up while all tests are green.
   - Run tests after every refactor. Stay green.
   - Do NOT introduce untested behavior during refactor.

### 4.2 Iron Law

> **No production code without a failing test first.**

- "Implement first, test later" is anti-TDD. Treat it as a violation.
- Code written without a prior red phase is considered invalid draft.
- Bug fixes also follow TDD: write a failing test that reproduces the bug, then fix.

### 4.3 Evidence Requirements

| Phase | Required evidence |
| --- | --- |
| RED | Paste/reference failure output (assertion + traceback) |
| GREEN | Paste/reference all-green output (pass count) |
| REFACTOR | All-green output after each refactor step |

**No evidence = phase not complete. Do not advance.**

### 4.4 Authorized Exceptions (User Must Grant Per-Use)

- Exploratory scripts (throwaway / spike)
- One-time data migration / ops scripts
- Pure configuration files (no logic branches)
- Reverse-TDD (adding tests to existing untested code)
- Generated code (codegen output)

Authorization must be:
- Granted THIS session (no historical references)
- Scoped to specific files/range (no extension to adjacent code)
- Recorded in session (user message + affected paths)

### 4.5 Anti-TDD Signals (Stop Immediately If Any)

- Implementation written but `tests/` has NO failing record for it
- "Get it working first, test later"
- Validating via manual curl / UI clicks instead of automated test
- Subagent delivered implementation without matching tests
- Tests written but never seen to fail before passing

---

## 5. OpenSpec Workflow (Path A only)

When the project has OpenSpec installed (`.opencode/skills/openspec-propose/` or `.claude/skills/openspec-propose/`), non-trivial coding tasks MUST use this flow.

### 5.1 Four Phases

| Phase | Command | Artifact | Note |
| --- | --- | --- | --- |
| Exploration | `opsx:explore` | Thought notes | Replaces `brainstorming` |
| Proposal | `opsx:propose` | proposal + specs + design + tasks | Replaces `writing-plans` |
| Apply | `opsx:apply` | Code + tests | Replaces `executing-plans` |
| Archive | `opsx:archive` | Archived change | Marks change complete |

### 5.2 `specs.md` MUST Reference BDD

`opsx:propose` generated `specs.md` includes an acceptance criteria section referencing `features/*.feature` files:

```markdown
## 验收标准

BDD scenarios defined in:
- `features/<feature-name>.feature`

Each scenario must have a corresponding passing automated test in implementation.
```

### 5.3 `tasks.md` MUST Reference Scenarios

Each task step must cite its associated scenario:

```markdown
- [ ] 实现用户注册接口 → `features/user-registration.feature` Scenario: 使用有效邮箱注册成功
```

### 5.4 Archive

After tasks complete + verification passes + CLI gate passes, run `opsx:archive` to mark the change done and move it to the archive.

---

## 6. BDD Gherkin Requirements (Path A; Recommended for Path B)

### 6.1 File Location

```
project-root/features/<feature-name>.feature
```

Project may override (e.g. `test/features/`) but team must be consistent.

### 6.2 Relationship to TDD

- `.feature` defines **acceptance criteria** (WHAT to verify)
- TDD RED implements **step definitions** (HOW to verify)
- Scenario `Then` / `那么` = test `expect` assertion. No softening allowed.

### 6.3 Test Layering

- **Acceptance tests**: MUST align with `.feature` scenarios, implementing step definitions
- **Unit / regression tests**: may exist independently, but must trace back to a scenario-covered functional module
- "Random tests with no functional traceability" are NOT allowed

### 6.4 Per-Stack Frameworks

| Stack | BDD framework |
| --- | --- |
| Node.js / TypeScript | `@cucumber/cucumber` + vitest / jest |
| Java / Spring Boot | Cucumber-JVM + JUnit 5 |
| Python | `pytest-bdd` or `behave` |
| Frontend E2E | Playwright + `playwright-bdd` |

### 6.5 Gherkin Example

```gherkin
功能: 用户注册

  场景: 使用有效邮箱注册成功
    假如 一个未注册的邮箱 "new@example.com"
    而且 一个符合规则的密码 "Abc123!@#"
    当 用户提交注册请求
    那么 系统返回 201 状态码
    而且 响应体包含用户 ID
    而且 数据库中存在该用户记录
```

Both Chinese (`功能/场景/假如/当/那么`) and English (`Feature/Scenario/Given/When/Then`) keywords are supported. Pick one per team.

### 6.6 Step Definitions Directory Structure

```
project-root/
├── features/
│   ├── user-registration.feature
│   ├── login.feature
│   └── step_definitions/
│       ├── user-registration.steps.ts   (or .py / .java)
│       └── login.steps.ts
└── src/
    └── ...
```

Step definition files live alongside `.feature` files in `features/step_definitions/`. Each `.feature` file should have a corresponding step definition file.

| Stack | Step definition naming | Location |
| --- | --- | --- |
| Node.js / TypeScript | `<feature>.steps.ts` | `features/step_definitions/` |
| Python | `<feature>_steps.py` | `features/step_definitions/` |
| Java | `<Feature>Steps.java` | `features/step_definitions/` (or `src/test/java/steps/`) |

### 6.7 Scenario Reference in TDD RED Phase

When writing a TDD RED test for a Path A project, the test MUST trace to a `.feature` scenario:

1. **Identify the scenario**: find the `.feature` scenario this code change satisfies.
2. **Implement step definitions**: the RED test implements `Given/When/Then` steps from that scenario.
3. **Reference in commit**: the commit message cites the scenario (see §6.8).

If no scenario exists for the behavior being implemented, write the `.feature` scenario FIRST, then proceed with RED.

### 6.8 Commit Message Scenario Reference

Path A commits that implement a scenario SHOULD reference it:

```
feat(auth): 实现邮箱注册接口

Scenario: features/user-registration.feature — 使用有效邮箱注册成功
TDD: RED→GREEN 完成，step definitions 全部通过
```

Format: `Scenario: <file-path> — <scenario-name>`

This is a SHOULD (recommended), not a MUST. Omitting it does not block the commit gate, but including it improves traceability.

---

## 7. Plan Review Gate (🔴 Hard Constraint)

**Multi-step implementation plans MUST be reviewed BEFORE execution begins.**

### 7.1 Triggers (any one)

- Plan modifies 2+ files
- Plan has 3+ atomic steps
- Plan introduces new dependencies, architecture patterns, or external interfaces

### 7.2 Review Flow

1. Submit plan to Oracle (or senior reviewer) with these dimensions:
   - **Goal alignment**: addresses user's original request?
   - **Technical approach**: architecture/dependency choices reasonable?
   - **Step completeness**: missing steps? dependency order correct?
   - **Risk identification**: breaking changes? performance? security?
   - **TDD annotation**: code steps correctly marked RED/GREEN/REFACTOR?
   - **BDD alignment (Path A)**: `.feature` reasonably covers core scenarios?

2. PASS → proceed to implementation.
3. Suggestions/issues → revise plan → resubmit.
4. **Never bypass review and start coding.**

### 7.3 Exemptions

- Task meets Trivial criteria (≤1 file, ≤10 lines, no new exports)
- Emergency hotfix with explicit user authorization (must review retroactively)

### 7.4 Review Prompt Template

```text
Review this implementation plan. Evaluate:
1. Goal alignment with user requirements
2. Technical approach reasonableness
3. Step completeness and ordering
4. Risks (breaking changes, security, performance)
5. TDD phase annotations correctness
6. BDD .feature coverage of core scenarios (Path A only)

Return PASS or specific revision suggestions.

---
[plan content]
```

---

## 8. CLI Pre-Commit Gate (Physical Enforcement)

Per-project `.githooks/agent-quality-gate.sh` (installed by `init-project-gates`) physically enforces gates at commit time.

### 8.1 Activation

Only fires when `AGENT_MODE=1` env var is set. **Human developers pass through freely.**

Before any agent `git commit`, the agent MUST `export AGENT_MODE=1`. The Skill assumes this is set; if missing, the gate silently allows everything — a security failure mode for accidental commits.

### 8.2 Trivial Exemption

The gate skips when ALL of:
- No new source files (excluding tests)
- ≤ 15 added lines (cached diff total)
- ≤ 2 changed files

### 8.3 Checks

| # | Check | v1.3.1 status | Path | Comment |
| --- | --- | --- | --- | --- |
| 1 | OpenSpec change exists | ⏳ planned v1.4.1 | Path A only | `openspec/changes/<name>/` must be present |
| 2 | `.feature` exists | ⏳ planned v1.4.2 | Path A (and recommended Path B) | New functional source requires matching `features/*.feature` |
| 3 | Source has corresponding test | ✅ implemented | Both | Multi-language: ts/tsx/js/jsx/py/java/kt/go |
| 4 | Tests pass | by CI, NOT in hook | Both | Design decision: tests run by CI, not pre-commit |
| 5 | Cross-review evidence | ✅ implemented | Both | `.agent/reviews/*.md` with `VERDICT: PASS` |

### 8.4 CHECK 5 — Cross-Review Trigger Thresholds

The hook requires `.agent/reviews/<date>-<topic>.md` (with explicit `VERDICT: PASS` line, ≤ 4h old, ≤ 20 lines post-review change) when:

- `LOGIC_FILES > 1 AND diff > 50 lines`, OR
- `single_file > 150 lines`

Excludes `.lock`, `.md`, `.json`, `.yaml`, `.yml`, `generated/`, `migrations/`, `.d.ts`, test files.

### 8.5 Bypass Rules

- `--no-verify` is **forbidden** unless user explicitly authorizes emergency bypass
- `SKIP_REVIEW=1` env var skips CHECK 5 only (still other gates) — emergency hotfix path
- Merge commits and first commit of a new project auto-skip CHECK 5

---

## 9. Verification Gate (Complete Before Any "Done" Claim)

**Evidence before claims. No fresh verification evidence = no completion claim.**

```text
1. IDENTIFY: What command/check proves this conclusion?
2. RUN: Execute the command fully.
3. READ: Read complete output, check exit code and failure count.
4. VERIFY: Does output support the conclusion?
   - No → report actual state with evidence.
   - Yes → report conclusion with evidence.
5. ONLY THEN: Make done/passing/fixed claim.
```

### 9.1 Evidence Requirements

| Claim | Required evidence |
| --- | --- |
| Tests pass | Test command output showing 0 failures |
| Build succeeds | Build command exit 0 |
| Lint clean | Lint output 0 errors |
| Bug fixed | Original symptom's reproduction case passes |
| Requirements met | Point-by-point check against requirements |
| Agent task done | Independently verify diff + run commands (don't trust agent self-report alone) |

**Forbidden phrases without evidence:** "should be fine", "looks good", "done", "fixed".

---

## 10. Anti-Over-Engineering (Always Active During Implementation)

Do what's asked. Nothing more, nothing less.

- **Don't add unrequested features.** Even if "easy to add while I'm here."
- **Don't refactor unrequested code.** Bug fix ≠ cleanup adjacent code.
- **Three similar lines > premature abstraction.** Don't create helper/util for one-time ops.
- **Don't design for hypothetical future needs.** No "what if we need to extend this later."
- **Don't add comments/docs to unmodified code.**
- **Edit existing files over creating new ones.**
- **When blocked, consider alternatives or ask.** Don't brute-force.

> Note: Design / brainstorming / `opsx:explore` phases are exempt. This rule constrains IMPLEMENTATION behavior only.

---

## 11. Systematic Debugging

When encountering bugs, test failures, or unexpected behavior: investigate root cause FIRST. No random changes.

1. Read the error message carefully.
2. Reproduce reliably; if unreproducible, gather more data.
3. Check recent changes: git diff, new deps, config changes.
4. Find working similar examples in the same codebase.
5. Compare working vs broken — list differences.
6. State hypothesis explicitly: "I believe X because Y."
7. Make minimal change to verify, changing one variable at a time.
8. Write failing test reproducing the bug, then implement single root-cause fix.
9. Verify fix passes with no regressions.

**Three Failures Rule**: After 3 consecutive fix attempts on the same issue, STOP. Question your assumptions or architecture. Consult Oracle/senior or ask the user. Do not continue blind fixing.

---

## 12. Plan & Todo Management

- Multi-step tasks MUST have todos created BEFORE starting execution.
- Todos must be executable atomic steps with real-time status updates.
- Only ONE todo may be `in_progress` at a time.
- Mark complete IMMEDIATELY after finishing (never batch).
- While user is still providing context → do NOT create implementation todos or touch code.

### 12.1 Mandatory Cross-Review Todo (⛔ Hard Constraint)

When the task involves **>1 non-test logic file AND >50 total changed lines**, OR **>150 changed lines in a single logic file** (excluding `.lock`, `.md`, `.json`, `.yaml`, `.test.`, `.spec.`, `generated/`, `migrations/`), the agent MUST:

1. Include a final todo item: `"交叉审查：用不同模型审查本次变更"` — ALWAYS the **last** todo before claiming done.
2. Ensure directory exists: `mkdir -p .agent/reviews`
3. Execute cross-review using `agent-review-protocol` §8 platform-adaptive routing. The agent reads `~/.agent-gates/review-capability.json` to select the best available heterogeneous review tool (opencode → codex → omc-codex-plugin → paseo → agent-tool fallback). See §8 for route details and timeout handling.
4. Save the review output to `.agent/reviews/<date>-<topic>.md`. File MUST end with explicit verdict line: `VERDICT: PASS` or `VERDICT: ISSUES`.
5. Only THEN mark the final todo complete and proceed to commit.

**Anti-loop (⛔)**: Cross-review follows the same 2-round cap as Three-Agent Pipeline (§4 of `agent-review-protocol`). After 2 rounds of fix→re-review still unresolved, escalate to user. Do NOT continue indefinitely.

**Review level tracking**: The review output file MUST include a `<!-- REVIEW_LEVEL: L0/L1/L2/L3 -->` header line indicating the actual heterogeneous capability used. `doctor.sh` checks this on subsequent runs. L0 reviews trigger a warning; set `REQUIRE_HETEROGENEOUS=1` to make L0 a blocking failure.

**Physical enforcement**: §8 CLI gate (`agent-quality-gate.sh` v1.3+) validates:
- Has `.agent/` but no `reviews/` → blocks
- Has `reviews/` but no file within 4h → blocks
- Review file lacks `VERDICT: PASS` line → blocks
- Staged files modified >20 lines after review mtime → blocks (requires re-review)
- No `.agent/` dir at all → warns only (project not yet initialized)

**Exceptions (skip cross-review):**
- Merge commits
- First commit of a new project (no existing code to review against)
- Hotfix with explicit user bypass authorization (`SKIP_REVIEW=1`)

---

## 13. Memory Persistence (⛔ Hard Constraint)

Session work MUST be persisted via a Memory skill so future sessions can resume context. This **complements** §14 Progress Tracking: Memory is semantic recall (skill-level), `.agent/PROGRESS.md` is file-level state.

### 13.1 When to save

Persistence is **not** a final wrap-up action. Save throughout the session:

| Trigger | What to save |
| --- | --- |
| Each todo marked completed | Short summary of that todo's outcome |
| Each phase delivery (brainstorm conclusion, plan, TDD cycle, research result) | Conclusion + key decision |
| Session about to end / context near limit | Handoff snapshot — where I am + next step |

Do NOT batch saves to the end of the session — save right after each unit of work.

### 13.2 Acting on the `memory-reminder` hook

When agent-gates is installed, `memory-reminder.mjs` injects a system-reminder marked `[AGENT-GATES: Memory Persistence Reminder]` after each todo is marked completed (matcher: `TodoWrite|todowrite|TaskUpdate|TaskCreate`). **Treat it as a mandatory check** — confirm you have persisted, or persist now. Do NOT respond with "I will save it later" — save before continuing to the next action.

### 13.3 What to record

| Field | Description |
| --- | --- |
| Current progress | What's done in this session |
| Key decisions | Decisions + rationale |
| Outstanding work / blockers | What remains, what's blocked, why |
| Files & branches | Critical paths, branch names |
| Next step | Where to pick up on resume |

### 13.4 What NOT to save

- Full code dumps or long log excerpts → use summaries + pointers (file path, line, function name)
- Ephemeral chat context already in conversation history
- Information derivable from `git log` / file reads — let the next session recover by reading the repo

### 13.5 Loading prior memory on session start

On **new session start**, read prior memory (Memory skill recall, `.agent/PROGRESS.md`, project notes under `memory/`) BEFORE acting. The agent must restore context, not start fresh and guess.

### 13.6 When no Memory skill is installed

The `memory-reminder` hook still fires but has no target skill to call → the reminder is informational only. Use `.agent/PROGRESS.md` + `.agent/memory/` (gitignored, see §14) as the persistence layer instead.

---

## 14. Progress Tracking (Multi-Day Work)

If the project has `.agent/PROGRESS.md`:

- After completing each todo: update today's "完成" section.
- After each commit: add to "Commit 日志" table.
- At session end: update "工时参考" with hours and description.
- Keep "当前状态" table current (phase, test count, build status, latest commit).
- Keep "关键信息" section current (especially after branch changes).
- **New session start**: read `.agent/PROGRESS.md` FIRST to restore context.

All agent working artifacts live in `.agent/`:
```
.agent/
├── PROGRESS.md    # Progress tracking (git tracked)
├── GATES.md       # Quality gates checklist (git tracked)
├── reviews/       # Cross-review evidence (git tracked)
├── memory/        # Cross-session memory (.gitignore)
└── plans/         # Implementation plans (git tracked)
```

---

## 15. Anti-Pattern Self-Check

Stop immediately if any of these are true:

- About to write feature code but haven't followed TDD → STOP
- About to design creatively but haven't explored requirements → STOP
- Modifying 3+ files but don't have a plan → STOP
- Plan ready to execute but hasn't been reviewed → STOP
- About to say "done" but haven't run verification → STOP
- Multi-file change about to commit but no `.agent/reviews/` evidence → STOP
- Doing things beyond what was asked (adding features, refactoring unrelated code) → STOP
- Same fix failed 3 times → STOP, question architecture
- Path A team project but no OpenSpec change record → STOP
- Path A team project writing acceptance tests without `.feature` scenarios → STOP
- `AGENT_MODE=1` not exported before commit → STOP

### 15.1 Rationalization Quick-Check

| Excuse | Reality |
| --- | --- |
| "Too simple for a plan" | Simple tasks are where most time is wasted on assumptions |
| "Implement first, test later" | Post-hoc tests only prove what code does, not what it should do |
| "Should be fine" | Run the verification command |
| "Just a small change" | Do root cause investigation first |
| "I'm confident" | Confidence ≠ evidence |
| "This time is different" | Rules apply especially when you think they don't |
| "I already know the answer" | Read the file first |
| "Let me try again" (after 2 failures) | Third failure = question architecture |

---

## 16. Completion Definition

Task is complete ONLY when ALL are true:

- [ ] User's original request fully addressed
- [ ] All todos completed or explicitly cancelled
- [ ] Modified files pass relevant diagnostics
- [ ] Required tests/build/lint ran with results shown
- [ ] Cross-check completed (different model/agent verified)
- [ ] PROGRESS.md updated (if exists)
- [ ] Path A team project: OpenSpec `opsx:archive` executed (if applicable)
- [ ] Memory persisted via §13 Memory Persistence

---

## §17 迭代收敛规则（Iteration Convergence）

**触发**：同一个设计文档 / 同一个实现 ≥ 2 轮独立审查仍被判 REVISE。

**强制动作**：暂停修补，反思整体思路。不允许直接出下一版继续 patch。

**反思提问清单**：
1. 反复出现的不同 bug 是否指向同一个隐性假设？
2. 我是不是在堆叠新机制而非简化？
3. 现在的设计是不是重新发明了一个已有机制？
4. 复杂度是不是已经超过解决的问题本身？

**禁止动作**：
- 直接出 v0.N+1 继续修边界
- 让审查者"按你的修复方案再审一次"

**正确动作**：
- 回到 v0.1 检查初始决策是否走偏
- 用扩展性 + 渐进式重新组织，每版只解决一个核心问题
- 如果 reset 比 patch 更简单，就 reset

**真实案例**：v1.6 Drift Review v0.1→v0.3 三轮审查均 REVISE。根因不是细节 bug，是把 drift review 设计成"门禁的升级版"，重新发明了 cross-review gate。reset 为"cross-review 子类"后复杂度大降。

---

## §18 团队模式 / 并行优先（Team-First Parallelism）

**核心原则**：复杂多任务必须优先并行派出子 agent，禁止默认串行包揽。

**判定**：
- ≥ 2 个**互不依赖**的子任务 → 必须并行（同一 message 多个 Agent tool call）
- 1 个 trivial 单任务 → 主 agent 自己做
- 串行依赖链（A 输出是 B 输入）→ 不强制并行，但应识别可分支点

**判断子任务是否互不依赖的标准**：
- 改动**不同文件集**
- 不需要彼此的产出作为输入
- 失败时不影响对方继续

**反模式（出现即停手）**：
- 主 agent 包揽 ≥ 3 件可拆任务
- "我先做 A 再做 B 再做 C" — 检查：A B C 真的有依赖吗？没有就并行
- 子 agent 后台跑期间主 agent 闲等

**真实案例**：v1.5.1 收尾包含规则沉淀 / Vault 更新 / CHANGELOG / 测试验证 4 件互不依赖的事，主 agent 包揽 3 件被用户纠正"分工反了"。正确做法：4 件全派出去并行，主 agent 留最后 commit + push。

**与现有 §30-delegation 的关系**：本节是**触发约束**（什么时候必须派）；30-delegation 是**操作规范**（派的 prompt 格式要求）。两者互补。

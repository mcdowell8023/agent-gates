---
name: agent-workflow-rules
description: "Runtime discipline rules for agent-assisted development: TDD enforcement, plan review gates, verification-before-completion, anti-over-engineering, and systematic debugging. Load this skill in any project where agents write code. Triggers: 'workflow rules', 'TDD', 'plan review', '工作流规则', '开发纪律', 'agent discipline', 'quality workflow'."
---

# Agent Workflow Rules

Runtime development discipline for AI coding agents. This skill governs HOW the agent works within a project — enforcing test-driven development, plan review before execution, evidence-based verification, and minimal implementation.

**Precedence**: When loaded alongside `10-workflow.md` (global rules), this skill supplements and extends it. On conflict, the **stricter rule** wins. This skill adds §7.1 cross-review enforcement and §8-§9 which are not in `10-workflow.md`.

**Companion skills:**
- `init-project-gates` — one-time project setup (hook, AGENTS.md, PROGRESS.md)
- `agent-review-protocol` — code review quality (Three-Agent Review, cross-check)

---

## 1. Skill Gate (Mandatory Checkpoint)

After identifying user intent but BEFORE starting work, scan installed skills and load those matching the task.

```text
Intent identified → 【Skill Gate: scan → load】 → Start work
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
| Writing production code (feature / bugfix / refactor) | Load TDD skill or follow §TDD Flow below |
| Creative work (new feature, new component, behavior change) | Explore requirements first (brainstorming / design phase) |
| Multi-step plan ready for execution | **Oracle reviews plan** (see §Plan Review Gate) |
| About to claim "done" / "fixed" / "passing" | Follow §Verification Gate |

### 🟡 Strong Defaults

| Trigger | Should do |
| --- | --- |
| Multi-step implementation | Write plan before coding |
| Bug / test failure / unexpected behavior | Systematic debugging (§Debugging) |
| Implementation complete, ready to deliver | Request code review |

### Trivial Criteria (May Skip 🟡 and 🟢)

ALL of the following must be true:
- ≤ 1 file involved
- ≤ 10 lines changed
- No new exports, routes, or components

**🔴 Hard gates are NEVER skipped, even for trivial tasks.**

### Scope Escalation

If task grows beyond initial classification (trivial → multi-file, or bugfix → refactor), PAUSE and re-run Skill Gate.

---

## 2. Standard TDD Flow (⛔ Hard Constraint)

All code development — new features, bug fixes, refactoring, behavior changes — MUST follow RED → GREEN → REFACTOR. No exceptions without explicit user authorization.

### Three Phases

1. **RED**: Write a test for the target behavior. Run it. **Watch it fail.**
   - Failure must be "target doesn't exist / behaves wrong" — not syntax/import errors.
   - Do NOT proceed until you see failure evidence.
   - For team projects with BDD: acceptance tests must implement `.feature` scenario step definitions.

2. **GREEN**: Write the **minimum** implementation to make that test pass.
   - Only code that turns the current red test green. Nothing else.
   - Run tests. Confirm target test passes AND existing tests still pass.

3. **REFACTOR**: Clean up while all tests are green.
   - Run tests after every refactor. Stay green.
   - Do NOT introduce untested behavior during refactor.

### Iron Law

> **No production code without a failing test first.**

- "Implement first, test later" is anti-TDD. Treat it as a violation.
- Code written without a prior red phase is considered invalid draft.
- Bug fixes also follow TDD: write a failing test that reproduces the bug, then fix.

### Evidence Requirements

| Phase | Required evidence |
| --- | --- |
| RED | Paste/reference failure output (assertion + traceback) |
| GREEN | Paste/reference all-green output (pass count) |
| REFACTOR | All-green output after each refactor step |

**No evidence = phase not complete. Do not advance.**

### Authorized Exceptions (User Must Grant Per-Use)

- Exploratory scripts (throwaway / spike)
- One-time data migration / ops scripts
- Pure configuration files (no logic branches)
- Reverse-TDD (adding tests to existing untested code)
- Generated code (codegen output)

Authorization must be:
- Granted THIS session (no historical references)
- Scoped to specific files/range (no extension to adjacent code)
- Recorded in session (user message + affected paths)

---

## 3. Plan Review Gate (🔴 Hard Constraint)

**Multi-step implementation plans must be reviewed BEFORE execution begins.**

### Triggers (any one)

- Plan modifies 2+ files
- Plan has 3+ atomic steps
- Plan introduces new dependencies, architecture patterns, or external interfaces

### Review Flow

1. Submit plan to Oracle (or senior reviewer) with these dimensions:
   - **Goal alignment**: Does plan accurately address the user's original request?
   - **Technical approach**: Are architecture/dependency choices reasonable?
   - **Step completeness**: Missing steps? Correct dependency order?
   - **Risk identification**: Breaking changes? Performance? Security?
   - **TDD annotation**: Are code steps correctly marked RED/GREEN/REFACTOR?

2. PASS → proceed to implementation.
3. Suggestions/issues → revise plan → resubmit.
4. **Never bypass review and start coding.**

### Exemptions

- Task meets Trivial criteria (≤1 file, ≤10 lines, no new exports)
- Emergency hotfix with explicit user authorization (must review retroactively)

### Review Prompt Template

```text
Review this implementation plan. Evaluate:
1. Goal alignment with user requirements
2. Technical approach reasonableness
3. Step completeness and ordering
4. Risks (breaking changes, security, performance)
5. TDD phase annotations correctness

Return PASS or specific revision suggestions.

---
[plan content]
```

---

## 4. Verification Gate (Complete Before Any "Done" Claim)

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

### Evidence Requirements

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

## 5. Anti-Over-Engineering (Always Active During Implementation)

Do what's asked. Nothing more, nothing less.

- **Don't add unrequested features.** Even if "easy to add while I'm here."
- **Don't refactor unrequested code.** Bug fix ≠ cleanup adjacent code.
- **Three similar lines > premature abstraction.** Don't create helper/util for one-time ops.
- **Don't design for hypothetical future needs.** No "what if we need to extend this later."
- **Don't add comments/docs to unmodified code.**
- **Edit existing files over creating new ones.**
- **When blocked, consider alternatives or ask.** Don't brute-force.

> Note: Design/brainstorming phases are exempt. This rule constrains IMPLEMENTATION behavior only.

---

## 6. Systematic Debugging

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

## 7. Plan & Todo Management

- Multi-step tasks MUST have todos created BEFORE starting execution.
- Todos must be executable atomic steps with real-time status updates.
- Only ONE todo may be `in_progress` at a time.
- Mark complete IMMEDIATELY after finishing (never batch).
- While user is still providing context → do NOT create implementation todos or touch code.

### 7.1 Mandatory Cross-Review Todo (⛔ 硬性约束)

When the task involves **>1 logic file** OR **>150 changed lines in a single logic file** (excluding `.lock`, `.md`, `.json`, `.yaml`, `generated/`, `migrations/`), the agent MUST:

1. Include a final todo item: `"交叉审查：用不同模型审查本次变更"` — ALWAYS the **last** todo before claiming done.
2. Ensure directory exists: `mkdir -p .agent/reviews`
3. Execute cross-review using `agent-review-protocol` §1 (tool priority: opencode CLI > codex > code-reviewer).
4. Save the review output to `.agent/reviews/<date>-<topic>.md` (file MUST contain reviewer verdict: PASS/ISSUES/✅/❌).
5. Only THEN mark the final todo complete and proceed to commit.

**Anti-loop (⛔)**: Cross-review follows the same 2-round cap as Three-Agent Pipeline (§4 of `agent-review-protocol`). After 2 rounds of fix→re-review still unresolved, escalate to user. Do NOT continue indefinitely.

**Physical enforcement**: `agent-quality-gate.sh` v1.1+ blocks commits without valid review evidence when `.agent/reviews/` exists. If the directory doesn't exist, hook warns but passes — the process rule (this section) still applies regardless.

**Exceptions (skip cross-review):**
- Merge commits
- First commit of a new project (no existing code to review against)
- Hotfix with explicit user bypass authorization (`SKIP_REVIEW=1`)

---

## 8. Progress Tracking (Multi-Day Work)

If the project has `.agent/PROGRESS.md`:

- After completing each todo: update today's "完成" section.
- After each commit: add to "Commit 日志" table.
- At session end: update "PingCode 工时参考" with hours and description.
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

## 9. Anti-Pattern Self-Check

Stop immediately if any of these are true:

- About to write feature code but haven't followed TDD → STOP
- About to design creatively but haven't explored requirements → STOP
- Modifying 3+ files but don't have a plan → STOP
- Plan ready to execute but hasn't been reviewed → STOP
- About to say "done" but haven't run verification → STOP
- Multi-file change about to commit but no `.agent/reviews/` evidence → STOP
- Doing things beyond what was asked (adding features, refactoring unrelated code) → STOP
- Same fix failed 3 times → STOP, question architecture

### Rationalization Quick-Check

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

## 10. Completion Definition

Task is complete ONLY when ALL are true:

- [ ] User's original request fully addressed
- [ ] All todos completed or explicitly cancelled
- [ ] Modified files pass relevant diagnostics
- [ ] Required tests/build/lint ran with results shown
- [ ] Cross-check completed (different model/agent verified)
- [ ] PROGRESS.md updated (if exists)

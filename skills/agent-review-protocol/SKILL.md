---
name: agent-review-protocol
description: "Code review quality enforcement: Three-Agent Review pipeline, cross-check protocol, severity handling, and review prompt templates. Load during code review phases or when completing significant implementations. Triggers: 'review protocol', 'three agent review', 'cross check', '代码审查', '交叉检查', 'code review', 'quality review'."
---

# Agent Review Protocol

Code review quality enforcement for AI-assisted development. This skill defines WHO reviews, WHAT they check, and HOW issues are handled — ensuring no significant code ships without independent verification.

**Companion skills:**
- `init-project-gates` — one-time project setup (hook, AGENTS.md, PROGRESS.md)
- `agent-workflow-rules` — runtime discipline (TDD, plan review, verification)

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

It reads `~/.agent-gates/review-capability.json`, routes to the best available heterogeneous tool (L3→opencode→codex, L2→opencode, L1→codex), and auto-appends `REVIEW_TOOL` / `REVIEW_MODEL` / `REVIEW_LEVEL` markers to the output. On L0 machines (no heterogeneous tool) it exits 78 — caller falls back to same-model agent-tool.

**Use this command instead of spawning a Claude subagent for review.** On L1+ machines, using a same-model subagent violates the heterogeneous-review requirement (红线 #8).

### Tool Priority (⛔ Hard Constraint)

Cross-check MUST use a different model/vendor. Priority order:

| Priority | Tool | When to use |
| --- | --- | --- |
| 1. **opencode CLI + heterogeneous model** (首选) | `opencode run -m <provider/model> --dir <workdir> --format json "<prompt>"` (⚠️ `-p` 是 `--password`；prompt 是位置参数放最后；**必须 `--format json`** 否则非 TTY 无输出) | Default for all cross-checks |
| 2. **codex CLI + GPT-5 series** (备选) | Via `codex:codex-rescue` agent | When opencode unavailable; note 3-min timeout limit |
| 3. **code-reviewer / critic agent** (兜底) | Same Claude model, different agent role | **Only when 1+2 are genuinely unavailable** (true L0 machine). NOT a shortcut when opencode/codex is installed — see §8 "L0 Fallback is a VIOLATION When L1+ is Available". |

### Model Selection for Cross-Check

| Scenario | Recommended model |
| --- | --- |
| Development review (find bugs/gaps) | `github-copilot/gpt-5.5` |
| Diagnosis / root-cause verification | `openai/gpt-5.5-pro` (strong reasoning) |
| Large document review | `github-copilot/gemini-3.1-pro-preview` (long context + different perspective) |
| Small patch / short code | code-reviewer agent (fast, acceptable for trivial) |

### opencode Command Template

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

Short prompt (inline):

```bash
opencode run -m github-copilot/gpt-5.5 --dir <workdir> --format json "<prompt>" 2>&1 | eval "$OC_PARSE"
```

Long prompt (file → file, recommended):

```bash
opencode run -m github-copilot/gpt-5.5 --dir <workdir> --format json "$(cat <prompt-file>)" 2>&1 | eval "$OC_PARSE" > <result-file>
```

- Prompt file: `~/AgentWorkspace/tmp/<task>-prompt.md`
- Result file: `~/AgentWorkspace/tmp/<task>-result.md`
- Run with `run_in_background=true` to avoid blocking main session (this is for the SHELL process, not the task() function).
- **Arg-length limit**: macOS ~262KB. If prompt exceeds ~200KB, split into summary + file references instead of inlining full content.

**⚠️ Common mistakes**:

| Wrong | Why | Correct |
| --- | --- | --- |
| `opencode run -p "prompt"` | `-p` is `--password`, not prompt | prompt is a positional arg — put it last |
| `> result.md` empty | default format is interactive, no output in non-TTY | add `--format json` + pipe through `OC_PARSE` |
| result contains JSON fragments | redirected without parsing | pipe through `OC_PARSE` before redirect |

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
opencode run -m github-copilot/gpt-5.5 --dir <workdir> --format json "$(cat ~/AgentWorkspace/tmp/crosscheck-prompt.md)" 2>&1 | eval "$OC_PARSE" > ~/AgentWorkspace/tmp/crosscheck-result.md &
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
| 1 (→ L3) | opencode CLI | `~/.agent-gates/bin/oc-review run -m github-copilot/gpt-5.5 --dir <workdir> --format json "$(cat <prompt>)" 2>&1 \| eval "$OC_PARSE" > <result>` | Yes |
| 2 (→ L1) | codex CLI | `codex exec -s read-only --skip-git-repo-check -C <workdir> < <prompt-file>` (prompt via **stdin**) | Yes |
| 3 (→ L1) | OMC codex plugin | Via `codex:codex-rescue` agent or `/ask codex` | Yes |
| 4 | Paseo | `create_agent provider="codex/gpt-5.4" prompt="<review>" background=true` | Yes |
| 5 (→ L0) | Agent tool (ultimate fallback) | Claude Code Agent tool — same-model sub-agent | **No** |

Note: L0/L1/L2/L3 refer to capability levels set by `doctor.sh`, not route priority numbers. L3 = opencode + codex, L2 = opencode, L1 = codex or OMC plugin, L0 = none.

**Route 1 — use `oc-review`, not bare `opencode run`** (v1.8.0): `~/.agent-gates/bin/oc-review` wraps `opencode run` with **retry-on-empty** (opencode intermittently exits 0 with empty output — the "P2" flake). On persistent empty output it exits **75** with an `oc-review:`-prefixed stderr line → treat as route failure and fall through to route 2 (codex). It does NOT spawn or manage a shared server; per-run `opencode serve` leaks are swept separately by `~/.agent-gates/bin/oc-reaper --apply` (also surfaced by `doctor.sh` → `check_opencode_health`).

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

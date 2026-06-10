#!/usr/bin/env node
// memory-reminder.mjs — Cross-platform hook for agent-gates
// Two reminders, one hook:
//   1. Memory persistence — when a todo is marked completed.
//   2. Parallelism (v1.6.1) — when >=3 all-pending todos are created (plan time).
// Compatible with: OMC (Claude Code), OMO (OpenCode), OMX (Codex)
//
// Hook protocol:
//   - Reads JSON from stdin (event payload)
//   - Outputs JSON to stdout with hookSpecificOutput.additionalContext
//   - Must NOT print anything else to stdout (breaks protocol)
//
// Registered into platform config's .hooks.PostToolUse:
//   OMC: ~/.claude/settings.json (settings.json, NOT hooks.json)
//   OMX: ~/.codex/hooks.json
//   OMO: manual (deferred to v1.3.0+)
// Matcher: "TodoWrite|todowrite|TaskUpdate|TaskCreate"
// Source: https://github.com/mcdowell8023/agent-gates

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';

// NOTE on readFileSync(0, 'utf8'):
//   fd 0 = stdin. Hooks receive JSON payloads via stdin per platform protocol.
//   This is intentional — NOT reading a file path.

// NOTE on exit codes:
//   Always exit(0) regardless of parse errors or no-op results.
//   Non-zero exits would block the agent's tool pipeline (hooks are non-blocking by design).

// --- Config ---
const REMINDER_ZH = `你刚标记了一个 TODO 为已完成。请确认是否已用 Memory skill 保存关键产出：
- 已完成工作的摘要
- 关键决策点
- 下次需要恢复的上下文

示例调用: Memory skill → save(category="session", content="...")
或使用 PROGRESS.md 更新项目进度。`;

const REMINDER_EN = `You just marked a TODO as completed. Ensure you save key outputs via Memory skill:
- Summary of completed work
- Key decision points
- Context needed for session recovery

Example: Memory skill → save(category="session", content="...")
Or update PROGRESS.md with project progress.`;

// Parallelism reminder (v1.6.1): fires once at plan time, when >=3 all-pending
// todos are created. Teaches the A-vs-B distinction (batch tool calls vs sub-agents)
// so the agent picks the right parallelism mechanism instead of defaulting to serial.
const PARALLEL_MIN_TODOS = 3;

const PARALLEL_ZH = `你刚创建了多个 todo。动手前先按 agent-workflow-rules §18 判断哪些互相独立（不同文件、无依赖）：
- 独立的轻量操作（读/改不同文件、跑独立命令）→ 同一条消息里批量 tool call（机制 A）
- 独立的重工作流（各自要读多文件 + 跑验证 + 写一片代码）→ 并行派子 agent（机制 B）
- 有依赖链（A 的输出是 B 的输入）→ 才串行

别默认一件一件做。`;

const PARALLEL_EN = `You just created several todos. Before starting, classify which are independent (different files, no shared input) per agent-workflow-rules §18:
- Independent light ops (read/edit different files, run independent commands) → batch tool calls in ONE message (mechanism A)
- Independent heavy workstreams (each reads many files + runs verification + writes code) → dispatch parallel sub-agents (mechanism B)
- Dependency chain (A's output feeds B) → only then go serial

Do not default to doing them one at a time.`;

// --- Helpers ---
function safeParse(input) {
  try { return JSON.parse(input); } catch { return null; }
}

function detectTodoCompleted(payload) {
  if (!payload) return false;

  // OMO: EventTodoUpdated — type: "todo.updated", properties.todos array
  // v1.6.2: accept 'done' as well as 'completed' to match the OMC/OMX branch below.
  if (payload.type === 'todo.updated' && Array.isArray(payload.properties?.todos)) {
    return payload.properties.todos.some(t => t.status === 'completed' || t.status === 'done');
  }

  // OMC/OMX PostToolUse: tool_name matches todo-related tools
  const toolName = String(payload.tool_name || payload.tool || '').toLowerCase();
  if (/todo|todowrite|task/i.test(toolName)) {
    // Check specifically for status transitions to "completed"/"done"
    // Avoids false-positives from todo content containing these words
    const input = payload.tool_input || payload.input || {};
    const todos = input.todos || [];
    if (Array.isArray(todos)) {
      if (todos.some(t => t.status === 'completed' || t.status === 'done')) return true;
    }
    // Single-todo payload
    if (input.status === 'completed' || input.status === 'done') return true;
  }

  // Generic: check for status fields in nested structures
  if (payload.todo?.status === 'completed' || payload.todo?.status === 'done') {
    return true;
  }

  // Fallback: scan output text for completion signals.
  // Known false-positive: informational messages like "was already marked complete"
  // may trigger this. Acceptable as last-resort heuristic — better to over-remind
  // than miss a persistence checkpoint.
  const output = String(payload.tool_output || payload.output || '');
  if (/status.*completed|marked.*complete/i.test(output) && /todo/i.test(output)) {
    return true;
  }

  return false;
}

// Extract the todo array from a TodoWrite/TaskCreate payload, across platforms.
function extractTodos(payload) {
  if (!payload) return null;
  // OMO: todo.updated event
  if (payload.type === 'todo.updated' && Array.isArray(payload.properties?.todos)) {
    return payload.properties.todos;
  }
  // OMC/OMX PostToolUse: tool_input.todos
  const toolName = String(payload.tool_name || payload.tool || '').toLowerCase();
  if (/todo|todowrite|task/i.test(toolName)) {
    const input = payload.tool_input || payload.input || {};
    if (Array.isArray(input.todos)) return input.todos;
  }
  return null;
}

// Plan-time signal: >=3 todos, NOTHING completed yet, and at most one in_progress.
// This is the "work just laid out, barely started" fingerprint. We deliberately do
// NOT require all-pending: real-world plan writes commonly mark the first item
// in_progress in the same write (~64% of sampled real TodoWrite plan writes), so an
// all-pending gate would miss the majority of genuine plan moments. Once a second
// item goes in_progress or anything is completed, work is underway → stay quiet.
//
// Calibration note: thresholds tuned against real TodoWrite transcripts, not just
// synthetic fixtures — see v1.6.2. The status fingerprint to FIRE:
//   completed == 0  AND  in_progress <= 1  AND  >=1 explicit pending  AND  no unknown status
// Anything else (work underway, or unrecognized/malformed statuses) → no fire.
//
// We classify each status explicitly. Missing/empty/garbage status counts as
// "unknown" and BLOCKS firing (a well-formed TodoWrite always sets status), which
// preserves the v1.6.1 hardening against malformed payloads false-triggering.
//
// Statelessness note: the hook does NOT dedupe across calls. In practice a TodoWrite
// plan write is a single PostToolUse event, so this fires effectively once per plan.
function detectPlanTimeTodos(payload) {
  const todos = extractTodos(payload);
  if (!Array.isArray(todos) || todos.length < PARALLEL_MIN_TODOS) return false;
  let completed = 0, inProgress = 0, pending = 0, unknown = 0;
  for (const t of todos) {
    const s = String(t?.status || '').toLowerCase();
    if (s === 'completed' || s === 'done') completed++;
    else if (s === 'in_progress' || s === 'in-progress') inProgress++;
    else if (s === 'pending') pending++;
    else unknown++;
  }
  return completed === 0 && inProgress <= 1 && pending >= 1 && unknown === 0;
}

// Plan decision reminder (v1.11.0): fires when agent edits/writes a source file
// but `.agent/plans/` has no valid decision artifact (reviewed plan or approved skip).
const SRC_EXTENSIONS = /\.(ts|tsx|js|jsx|py|java|kt|go|rs|rb|swift|c|cpp|h|hpp)$/;
const TEST_PATTERNS = /(\.(test|spec)\.|_test\.|Test\.)/;

const PLAN_ZH = `你正在编辑源码文件，但 .agent/plans/ 下没有经过审查的方案或授权的豁免记录。动手前先做决策：
- 需要方案：写 .agent/plans/<topic>.md，然后跑 agent-gates-review --plan <plan>
- 不需要方案：跑 agent-gates-plan-decision skip --reason "<理由>" --topic <name>
- trivial 改动可忽略

门禁(CHECK 3)会在 commit 时验证决策痕迹。`;

const PLAN_EN = `You're editing source files but .agent/plans/ has no reviewed plan or approved skip record. Make a decision before continuing:
- Need a plan: write .agent/plans/<topic>.md, then run agent-gates-review --plan <plan>
- Skip plan: run agent-gates-plan-decision skip --reason "<reason>" --topic <name>
- Trivial changes can be ignored

The pre-commit gate (CHECK 3) will verify the decision artifact at commit time.`;

function detectSourceEditWithoutDecision(payload) {
  if (!payload) return false;
  const toolName = String(payload.tool_name || payload.tool || '').toLowerCase();
  if (!/^(edit|write)$/.test(toolName)) return false;

  const input = payload.tool_input || payload.input || {};
  const filePath = String(input.file_path || input.path || '');
  if (!filePath) return false;
  if (!SRC_EXTENSIONS.test(filePath)) return false;
  if (TEST_PATTERNS.test(filePath)) return false;

  // Find .agent/plans/ relative to the file being edited — walk up from filePath

  let dir = dirname(filePath);
  let plansDir = null;
  for (let i = 0; i < 10; i++) {
    const candidate = join(dir, '.agent', 'plans');
    if (existsSync(candidate)) { plansDir = candidate; break; }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }

  if (!plansDir) return false; // not an init'd project

  // Check for valid decision artifact
  try {
    const files = readdirSync(plansDir);

    // Reviewed plan: any .md (not .skip.md) with PLAN_REVIEW markers
    const hasReviewedPlan = files.some(f => {
      if (!f.endsWith('.md') || f.endsWith('.skip.md')) return false;
      try {
        const content = readFileSync(join(plansDir, f), 'utf8');
        return content.includes('PLAN_REVIEW:') && content.includes('PLAN_REVIEW_TOOL:') && content.includes('PLAN_REVIEW_MODEL:');
      } catch { return false; }
    });
    if (hasReviewedPlan) return false; // silent

    // Approved skip: .skip.md with GENERATED_BY
    const hasApprovedSkip = files.some(f => {
      if (!f.endsWith('.skip.md')) return false;
      try {
        const content = readFileSync(join(plansDir, f), 'utf8');
        return content.includes('GENERATED_BY: agent-gates');
      } catch { return false; }
    });
    if (hasApprovedSkip) return false; // silent

    return true; // no valid artifact → fire reminder
  } catch { return false; }
}

// --- Main ---
function main() {
  let stdin = '';
  try {
    stdin = readFileSync(0, 'utf8');
  } catch {
    // No stdin available — exit silently
    process.stdout.write(JSON.stringify({}));
    process.exit(0);
  }

  const payload = safeParse(stdin);

  // Two distinct triggers, checked in priority order. Memory persistence wins
  // when a todo just completed; otherwise check for plan-time parallelism nudge.
  let reminder = null;
  if (detectTodoCompleted(payload)) {
    reminder = `<system-reminder>
[AGENT-GATES: Memory Persistence Reminder]

${REMINDER_ZH}

---
${REMINDER_EN}
</system-reminder>`;
  } else if (detectSourceEditWithoutDecision(payload)) {
    reminder = `<system-reminder>
[AGENT-GATES: Plan Decision Reminder]

${PLAN_ZH}

---
${PLAN_EN}
</system-reminder>`;
  } else if (detectPlanTimeTodos(payload)) {
    reminder = `<system-reminder>
[AGENT-GATES: Parallelism Reminder]

${PARALLEL_ZH}

---
${PARALLEL_EN}
</system-reminder>`;
  } else {
    // Neither trigger — no-op
    process.stdout.write(JSON.stringify({}));
    process.exit(0);
  }

  // Emit hook output per Claude Code PostToolUse schema.
  // `hookEventName` is REQUIRED — Claude Code validates against it and
  // emits a non_blocking_error attachment when missing (reminder silently dropped).
  const output = {
    hookSpecificOutput: {
      hookEventName: 'PostToolUse',
      additionalContext: reminder
    }
  };

  process.stdout.write(JSON.stringify(output));
  process.exit(0);
}

main();

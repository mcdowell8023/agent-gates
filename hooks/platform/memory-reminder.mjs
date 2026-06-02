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

import { readFileSync } from 'node:fs';

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
  if (payload.type === 'todo.updated' && Array.isArray(payload.properties?.todos)) {
    return payload.properties.todos.some(t => t.status === 'completed');
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

// Plan-time signal: >=3 todos AND every one EXPLICITLY pending.
// "all-pending" is the initial-plan fingerprint, not a mid-stream status update,
// so the reminder fires during planning and goes quiet once work begins (the first
// in_progress/completed transition makes this return false).
//
// Statelessness note: the hook does NOT dedupe across calls — if the platform
// delivers the same all-pending payload more than once it will nudge each time.
// In practice a TodoWrite plan write is a single PostToolUse event, so this fires
// effectively once per plan. We require EXPLICIT status === 'pending' (missing or
// empty status does NOT count) so malformed/partial payloads can't false-trigger.
function detectPlanTimeTodos(payload) {
  const todos = extractTodos(payload);
  if (!Array.isArray(todos) || todos.length < PARALLEL_MIN_TODOS) return false;
  return todos.every(t => String(t?.status || '').toLowerCase() === 'pending');
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

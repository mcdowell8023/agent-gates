#!/usr/bin/env node
// memory-reminder.mjs — Cross-platform hook for agent-gates
// Reminds agents to save to Memory skill when todos are marked completed.
// Compatible with: OMC (Claude Code), OMO (OpenCode), OMX (Codex)
//
// Hook protocol:
//   - Reads JSON from stdin (event payload)
//   - Outputs JSON to stdout with hookSpecificOutput.additionalContext
//   - Must NOT print anything else to stdout (breaks protocol)
//
// Register via hooks.json → PostToolUse (matcher: "TodoWrite|todowrite")
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
  if (!detectTodoCompleted(payload)) {
    // Not a todo-completed event — no-op
    process.stdout.write(JSON.stringify({}));
    process.exit(0);
  }

  // Compose system reminder
  const reminder = `<system-reminder>
[AGENT-GATES: Memory Persistence Reminder]

${REMINDER_ZH}

---
${REMINDER_EN}
</system-reminder>`;

  // Emit hook output per OMC/OMO/OMX protocol
  const output = {
    hookSpecificOutput: {
      additionalContext: reminder
    }
  };

  process.stdout.write(JSON.stringify(output));
  process.exit(0);
}

main();

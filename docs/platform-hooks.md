# Platform Hooks

agent-gates uses platform-specific hooks to inject reminders into agent sessions. All three major platforms (OMC, OMO, OMX) share the same hooks.json schema.

## Hook Schema (Shared)

```json
{
  "EventName": [
    {
      "matcher": "pattern",
      "hooks": [
        {
          "type": "command",
          "command": "/path/to/script.mjs",
          "timeout": 5
        }
      ]
    }
  ]
}
```

## Events

| Event | When | Use Case |
|-------|------|----------|
| `SessionStart` | Session begins | Context restoration |
| `PreToolUse` | Before tool executes | Validation |
| `PostToolUse` | After tool completes | **Memory reminder** |
| `UserPromptSubmit` | User sends message | Context injection |
| `Stop` | Agent stops responding | Session-end checks |

## memory-reminder.mjs

Registered on `PostToolUse` with matcher `TodoWrite|todowrite`.

**Protocol:**
1. Receives JSON on stdin (tool call payload)
2. Detects if a todo was marked "completed"
3. If yes: outputs JSON with `hookSpecificOutput.additionalContext` containing a `<system-reminder>` block
4. If no: outputs `{}` (no-op)

## Registration Per Platform

### OMC (Claude Code)

File: `~/.claude/hooks.json` (or merge into existing)

```json
{
  "PostToolUse": [
    {
      "matcher": "TodoWrite|todowrite",
      "hooks": [
        {
          "type": "command",
          "command": "node ~/.agent-gates/hooks/platform/memory-reminder.mjs",
          "timeout": 5
        }
      ]
    }
  ]
}
```

### OMO (OpenCode)

File: `~/.claude/settings.json` (shared with Claude Code format)

Same JSON structure as OMC. OpenCode reads hooks from `~/.claude/settings.json` when `hooks: true` is enabled in oh-my-openagent config.

### OMX (Codex)

File: `~/.codex/hooks.json` (merge into existing)

Same JSON structure. OMX's `codex-native-hook.js` dispatches events to registered hooks.

## Payload Examples

### PostToolUse (TodoWrite)

```json
{
  "tool_name": "TodoWrite",
  "tool_input": {
    "todos": [
      {"content": "Implement auth", "status": "completed", "priority": "high"}
    ]
  },
  "tool_output": "Updated 1 todo(s)"
}
```

### OMO EventTodoUpdated (SSE)

```json
{
  "type": "todo.updated",
  "properties": {
    "sessionID": "ses_abc123",
    "todos": [
      {"id": "t1", "content": "Write tests", "status": "completed"}
    ]
  }
}
```

## Debugging

Enable debug logging (writes to file, not stdout):

```bash
AGENT_GATES_DEBUG=1 node ~/.agent-gates/hooks/platform/memory-reminder.mjs < payload.json
```

Test with sample payload:

```bash
echo '{"tool_name":"TodoWrite","tool_input":{"todos":[{"status":"completed"}]}}' | \
  node ~/.agent-gates/hooks/platform/memory-reminder.mjs | jq .
```

Expected output:
```json
{
  "hookSpecificOutput": {
    "additionalContext": "<system-reminder>..."
  }
}
```

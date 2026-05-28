# Platform Hooks

agent-gates registers a `PostToolUse` hook (`memory-reminder.mjs`) on each supported agent platform. Each platform's configuration file uses Claude Code's nested `.hooks.<EventType>[]` schema.

## Hook Schema (nested)

```json
{
  "hooks": {
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
}
```

Other top-level keys in the config file (e.g. `model`, `permissions`, `theme` in `settings.json`) are preserved unchanged by the installer.

## Events

| Event | When | Use Case |
|-------|------|----------|
| `SessionStart` | Session begins | Context restoration |
| `PreToolUse` | Before tool executes | Validation |
| `PostToolUse` | After tool completes | **Memory reminder** |
| `UserPromptSubmit` | User sends message | Context injection |
| `Stop` | Agent stops responding | Session-end checks |

## memory-reminder.mjs

Registered on `PostToolUse` with matcher `TodoWrite|todowrite|TaskUpdate|TaskCreate`. The four alternatives cover both the legacy `TodoWrite` tool name and Claude Code's current `TaskUpdate` / `TaskCreate` tools.

**Protocol:**
1. Receives JSON on stdin (tool call payload).
2. Detects if a todo was marked `completed` via `todos[].status` (status field check, not substring scan).
3. If yes: outputs JSON with `hookSpecificOutput.additionalContext` containing a `<system-reminder>` block marked `[AGENT-GATES: Memory Persistence Reminder]`.
4. If no: outputs `{}` (no-op).

## Registration Per Platform

### OMC (Claude Code)

File: `~/.claude/settings.json` → `.hooks.PostToolUse[]`

The installer requires `~/.claude/settings.json` to exist (start Claude Code once before running `install.sh`). It uses `jq` to merge into `.hooks.PostToolUse` without disturbing other top-level keys.

```json
{
  "model": "...",
  "permissions": { },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "TodoWrite|todowrite|TaskUpdate|TaskCreate",
        "hooks": [
          {
            "type": "command",
            "command": "node /Users/you/.agent-gates/hooks/platform/memory-reminder.mjs",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

> Claude Code reads `settings.json` at startup. After installing or upgrading, **start a new Claude Code session** for the hook to activate.

### OMO on Claude Code

[oh-my-openagent](https://github.com/Yeachan-Heo/oh-my-claudecode) (OMO) is a cross-platform orchestration layer that runs on Claude Code, OpenCode, Codex, and more. When OMO runs on Claude Code, it reads `~/.claude/settings.json` for PostToolUse hooks — the same file as OMC above. **No additional registration is needed.** The OMC entry already covers OMO-on-Claude-Code users.

OMO's own lifecycle hooks coexist with Claude Code native hooks. Skills are resolved dual-source: `~/.config/opencode/skills/` first, then `~/.claude/skills/`.

### OMO native (OpenCode)

File: `~/.config/opencode/hooks.json` → `.hooks.PostToolUse[]` (nested schema, same shape as OMC and OMX).

**v1.5.2 auto-registers** — when `install.sh` detects `~/.config/opencode/`, it writes the entry below to `~/.config/opencode/hooks.json` via the same `register_hook()` jq logic used for OMC/OMX (schema is identical). Falls back to printing the manual entry only if jq is unavailable. For reference, the equivalent manual JSON to add under `.hooks.PostToolUse[]`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "TodoWrite|todowrite|TaskUpdate|TaskCreate",
        "hooks": [
          {
            "type": "command",
            "command": "node /Users/you/.agent-gates/hooks/platform/memory-reminder.mjs",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

`doctor.sh` checks this exact path/schema via `check_omo_registration`; if it reports the OMO hook as missing, the fix is to re-run `install.sh --upgrade` so v1.5.2's auto-registration writes the entry. As a manual fallback (e.g. when jq is unavailable), add the JSON above by hand.

### OMX (Codex)

File: `~/.codex/hooks.json` → `.hooks.PostToolUse[]`

Same nested schema as OMC. OMX's `codex-native-hook.js` already lives in `.hooks.PostToolUse`; the installer appends our entry as a new array item without overwriting.

## Payload Examples

### PostToolUse — TaskUpdate (current Claude Code)

```json
{
  "tool_name": "TaskUpdate",
  "tool_input": {
    "taskId": "1",
    "status": "completed"
  }
}
```

### PostToolUse — TodoWrite (legacy)

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

Test with a sample payload (offline; does not register the hook):

```bash
echo '{"tool_name":"TaskUpdate","tool_input":{"status":"completed"}}' | \
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

For end-to-end verification, after running `install.sh`, **start a fresh agent session** and mark a todo completed — the system-reminder should appear in the next interaction.

## Project-level checks (v1.4)

`doctor.sh` (v1.4+) additionally inspects the **current working directory** for:

- `check_openspec_install` — detects `.opencode/skills/openspec-propose/`, `.claude/skills/openspec-propose/`, or `openspec/changes/` and reports which workflow path applies (A vs B).
- `check_bdd_features_dir` — counts `features/*.feature` files and WARNs if `features/` exists but is empty.

These checks are unrelated to the platform hook registration above. They run only when the cwd is a git repo and skip silently otherwise. See the README "Workflow Paths: A (OpenSpec) vs B (no OpenSpec)" section for the routing rationale.

## Removing the hook

`uninstall.sh` cleans both the current schema (`.hooks.PostToolUse`) and the legacy v1.0.0–v1.1.1 schema (root `.PostToolUse` in `~/.claude/hooks.json`). Other top-level keys in `settings.json` are preserved; pure dedicated `hooks.json` files become empty and are removed.

#!/usr/bin/env bash
# lib/hetero/dispatch.sh — v2.0.0 hetero-check dispatch + minimal lifecycle.
# Sourceable library. Provides hetero_spawn_pg, hetero_kill_tree,
# hetero_register_spawn, hetero_register_wall_watcher, _hetero_check_breaker,
# and hetero_dispatch.
#
# Requires: lib/hetero/config.sh (already sourced or will be sourced on demand).
# See design doc: docs/design/v2.0.0-hetero-check.md §3.1 §4.2-4.6

[[ -n "${_HETERO_DISPATCH_SOURCED:-}" ]] && return 0
_HETERO_DISPATCH_SOURCED=1

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _hetero_dispatch_lib_dir: directory of this file, used to find sibling libs.
_hetero_dispatch_lib_dir() {
  printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

# _hetero_ensure_config: source config.sh once.
_hetero_ensure_config() {
  local cfg
  cfg="$(_hetero_dispatch_lib_dir)/config.sh"
  if [[ -z "${_HETERO_CONFIG_SOURCED:-}" && -f "$cfg" ]]; then
    # shellcheck source=lib/hetero/config.sh
    source "$cfg"
  fi
  hetero_load_config 2>/dev/null || true
}

# _hetero_ensure_serve: source serve.sh once.
_hetero_ensure_serve() {
  local srv
  srv="$(_hetero_dispatch_lib_dir)/serve.sh"
  if [[ -z "${_OC_SERVE_SOURCED:-}" && -f "$srv" ]]; then
    # shellcheck source=lib/hetero/serve.sh
    source "$srv"
  fi
}

# _hetero_ensure_select: source select.sh functions once (is_high_risk_path, select_effort).
_hetero_ensure_select() {
  if ! declare -f select_effort >/dev/null 2>&1; then
    local sel
    fam="$(_hetero_dispatch_lib_dir)/family.sh"
    [[ -f "$fam" ]] && source "$fam"
    sel="$(_hetero_dispatch_lib_dir)/select.sh"
    [[ -f "$sel" ]] && source "$sel"
  fi
}

# ---------------------------------------------------------------------------
# hetero_spawn_pg <cmd...>
#
# Start <cmd...> in a new process group (setsid semantics).
# On macOS, setsid is not available; use bash job-control (set -m) as fallback.
#
# Sets globals:
#   HETERO_LAST_ROOT_PID  — PID of the root process launched
#   HETERO_LAST_PGID      — PGID of the new process group (== ROOT_PID after setsid)
# ---------------------------------------------------------------------------
hetero_spawn_pg() {
  local root_pid pgid

  # Try perl POSIX::setsid() — available on macOS and Linux.
  # This is the only reliable way to create a new process group in non-interactive
  # scripts; set -m is a no-op in non-interactive shells and must NOT be used as a
  # fallback (it inherits the caller's PGID, risking orchestrator kill-by-mistake).
  if command -v perl >/dev/null 2>&1 && perl -e 'use POSIX ()' 2>/dev/null; then
    # Wrap the command in perl that calls setsid before exec'ing.
    # The perl wrapper exits with the child's exit code.
    perl -e '
use POSIX ();
POSIX::setsid();
exec @ARGV or die "exec failed: $!\n";
' -- "$@" &
    root_pid=$!
  else
    # perl not available — cannot safely create a new process group.
    # Refuse to fall back to set -m (non-interactive no-op; inherits PGID).
    printf 'hetero_spawn_pg: perl with POSIX unavailable; cannot create new process group\n' >&2
    return 1
  fi

  # H5: poll for the child to establish a distinct PGID (up to 500ms).
  # Fail-closed: if the PGID never diverges from the caller's, return 1 so
  # the caller can skip this channel rather than risk kill-by-mistake.
  local caller_pgid pgid="" i
  caller_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  for i in $(seq 1 10); do
    sleep 0.05 2>/dev/null || true
    pgid=$(ps -o pgid= -p "$root_pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$pgid" && "$pgid" != "$caller_pgid" ]]; then
      break
    fi
    pgid=""
  done
  if [[ -z "$pgid" ]]; then
    return 1
  fi

  export HETERO_LAST_ROOT_PID="$root_pid"
  export HETERO_LAST_PGID="$pgid"
}

# ---------------------------------------------------------------------------
# hetero_kill_tree <pgid> [wait]
#
# Kill all processes in process group <pgid>.
#   SIGTERM → grace period → SIGKILL if still alive.
# <wait>: if non-zero, wait for the SIGTERM to propagate before SIGKILL check.
# ---------------------------------------------------------------------------
hetero_kill_tree() {
  local pgid="$1"
  local do_wait="${2:-1}"
  local grace_s="${HETERO_KILL_GRACE_S:-3}"

  [[ -z "$pgid" || "$pgid" == "0" ]] && return 0

  # Send SIGTERM to the entire process group
  kill -TERM -- "-${pgid}" 2>/dev/null || true

  if [[ "$do_wait" != "0" ]]; then
    sleep "$grace_s" 2>/dev/null || true
  else
    sleep 0.1 2>/dev/null || true
  fi

  # SIGKILL any survivors
  kill -KILL -- "-${pgid}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# hetero_register_spawn <key> <root_pid> <pgid>
#
# Write attribution JSON to $HETERO_LOCK_DIR/spawns/<key_safe>-<timestamp>.json
# ---------------------------------------------------------------------------
hetero_register_spawn() {
  local key="$1"
  local root_pid="$2"
  local pgid="$3"
  local lock_dir="${HETERO_LOCK_DIR:-/tmp/hetero-lock-$$}"
  local spawns_dir="$lock_dir/spawns"
  local started_at
  started_at=$(date +%s)
  local key_safe="${key//\//_}"

  mkdir -p "$spawns_dir"

  local file="$spawns_dir/${key_safe}-${started_at}.json"
  printf '{"key": "%s", "root_pid": %s, "pgid": %s, "started_at": %s}\n' \
    "$key" "$root_pid" "$pgid" "$started_at" > "$file"
}

# ---------------------------------------------------------------------------
# hetero_register_wall_watcher <pgid> <wall_s> <key> <root_pid> <started_at>
#
# Register a one-shot wall-clock watcher in the background.
# After <wall_s> seconds, kills the process group <pgid> and records exit 137.
# Sets HETERO_LAST_WATCHER_PID for cleanup by the caller.
# ---------------------------------------------------------------------------
hetero_register_wall_watcher() {
  local pgid="$1"
  local wall_s="$2"
  local key="${3:-}"
  local root_pid="${4:-0}"
  local started_at="${5:-0}"
  local grace_s="${HETERO_KILL_GRACE_S:-3}"
  local _lib_dir
  _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Launch background watcher. Do NOT disown — keep the PID so the caller
  # (or the janitor via the dispatch artifact) can kill it when the agent
  # finishes normally, preventing an orphaned sleep process.
  # F4 fix: record HETERO_LAST_WATCHER_PID without disowning; watcher_pid is
  # written into the dispatch JSON so callers can clean up on normal exit.
  nohup bash -c "
sleep ${wall_s}
kill -TERM -- -${pgid} 2>/dev/null || true
sleep ${grace_s}
kill -KILL -- -${pgid} 2>/dev/null || true
source \"${_lib_dir}/janitor.sh\" 2>/dev/null || true
janitor_record_exit \"${key}\" \"${root_pid}\" \"${pgid}\" 137 \"${started_at}\" 2>/dev/null || true
" >/dev/null 2>&1 &
  export HETERO_LAST_WATCHER_PID=$!
  # Intentionally NOT disowning: caller receives HETERO_LAST_WATCHER_PID and
  # can kill it on normal completion via: kill "$HETERO_LAST_WATCHER_PID" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _hetero_check_breaker <key>
#
# Read exit records from $HETERO_LOCK_DIR/exits/<key_safe>.<ts>.json
# Returns 1 (breaker tripped) if the last CRASH_LOOP_MAX exits were all
# "cold start deaths" (runtime < COLD_START_S and non-zero exit code).
# Returns 0 otherwise.
# ---------------------------------------------------------------------------
_hetero_check_breaker() {
  local key="$1"
  local lock_dir="${HETERO_LOCK_DIR:-/tmp/hetero-lock-$$}"
  local exits_dir="$lock_dir/exits"
  local key_safe="${key//\//_}"
  local crash_loop_max="${HETERO_CRASH_LOOP_MAX:-3}"
  local cold_start_s="${HETERO_COLD_START_S:-10}"
  local cooldown_s="${HETERO_COOLDOWN_S:-300}"

  [[ -d "$exits_dir" ]] || return 0

  # Gather all exit records for this key, sorted by started_at descending
  local files
  files=$(ls "$exits_dir"/${key_safe}.*.json 2>/dev/null | sort -t. -k2 -rn)
  [[ -z "$files" ]] && return 0

  local now
  now=$(date +%s)
  local consecutive=0

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue

    local exit_code started_at exited_at
    exit_code=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('exit_code',0))
" "$file" 2>/dev/null)
    started_at=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('started_at',0))
" "$file" 2>/dev/null)
    exited_at=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('exited_at',0))
" "$file" 2>/dev/null)

    [[ -z "$exit_code" || -z "$started_at" || -z "$exited_at" ]] && break

    # Check cooldown: if this record is older than cooldown_s from now, reset
    local age=$(( now - exited_at ))
    if (( age > cooldown_s )); then
      break
    fi

    # exit_code == -1: unknown (non-child process); skip without affecting streak
    if (( exit_code == -1 )); then
      continue
    fi
    # Is this a cold-start death?
    local runtime=$(( exited_at - started_at ))
    if (( exit_code != 0 && runtime < cold_start_s )); then
      consecutive=$(( consecutive + 1 ))
      if (( consecutive >= crash_loop_max )); then
        return 1  # breaker tripped
      fi
    else
      # Not a cold-start death: reset consecutive count
      break
    fi
  done <<< "$files"

  return 0
}

# ---------------------------------------------------------------------------
# _hetero_gen_verify_run_id
#
# Generate a unique verify_run_id like <date>-<shorthash>
# ---------------------------------------------------------------------------
_hetero_gen_verify_run_id() {
  local date_part
  date_part=$(date +%Y%m%d-%H%M%S)
  local hash_part
  hash_part=$(head -c 8 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | head -c 6 || echo "$(date +%N | head -c 6)")
  printf '%s-%s' "$date_part" "$hash_part"
}

# ---------------------------------------------------------------------------
# _hetero_capability_for <reviewer-model>
#
# capability answers exactly one question: did the dispatch layer record a reviewer whose
# model family PROVABLY differs from the implementer's?
#
# It used to answer "was the paseo channel used", which was broken in a way nothing caught:
# the paseo branch hardcoded `--provider claude/opus`, so the only channel able to award
# FULL was dispatching a SAME-FAMILY reviewer (the main session is Claude), while pi and
# opencode — explicitly configured with a heterogeneous model — could never get above
# EVIDENCE_ONLY. The grading was inverted.
#
# ⚠️ This is deliberately NOT a claim that the review text came from that model. Nothing at
# this layer can establish that, and the old FULL did not either. It records a checkable
# fact about the dispatch, nothing more.
#
# fail-closed: no declared implementer family, or either side unresolvable -> EVIDENCE_ONLY.
_hetero_capability_for() {
  local reviewer="${1:-}" implementer="${HETERO_IMPLEMENTER_FAMILY:-}"
  [[ -z "$implementer" ]] && { echo EVIDENCE_ONLY; return 0; }
  if declare -f hetero_families_differ >/dev/null 2>&1 \
     && hetero_families_differ "$reviewer" "$implementer"; then
    echo FULL
  else
    echo EVIDENCE_ONLY
  fi
}

# hetero_dispatch <role> <prompt> [supervised]
#
# Six-channel dispatch:
#   paseo → pi → opencode (fail-closed) → codex → codebuddy → echo-fallback
#
# Sets globals after dispatch:
#   HETERO_DISPATCH_CHANNEL       — channel used (paseo/pi/opencode/codex/codebuddy/exhausted)
#   HETERO_DISPATCH_CAPABILITY    — FULL or EVIDENCE_ONLY
#   HETERO_DISPATCH_VERIFY_RUN_ID — unique ID for this dispatch run
#   HETERO_DISPATCH_DISPATCH_JSON — path to the dispatch artifact JSON
# ---------------------------------------------------------------------------
hetero_dispatch() {
  local role="$1"
  local prompt="$2"
  local supervised="${3:-0}"

  _hetero_ensure_config
  _hetero_ensure_serve
  _hetero_ensure_select

  # Determine effort level: read risk tier then resolve config/env/default.
  local _hr_val
  _hr_val=$(is_high_risk_path 2>/dev/null)
  local effort
  effort=$(select_effort "$role" "${_hr_val:-0}" 2>/dev/null)
  effort="${effort:-medium}"

  # Generate verify_run_id
  local verify_run_id
  verify_run_id=$(_hetero_gen_verify_run_id)
  export HETERO_DISPATCH_VERIFY_RUN_ID="$verify_run_id"

  # F7 fix: pre-compute the evidence file path so opencode stdout can be captured.
  local verify_dir=".agent/verify"
  mkdir -p "$verify_dir"
  local evidence_path="${verify_dir}/${verify_run_id}.evidence.json"

  # Gather git context for dispatch artifact
  local head_sha staged_diff_hash started_at
  started_at=$(date +%s)
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  staged_diff_hash=$(git diff --cached -- ':!.agent/verify' 2>/dev/null | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } 2>/dev/null | awk '{print $1}' || echo "unknown")

  # Determine channel
  local channel="exhausted"
  local capability="EVIDENCE_ONLY"
  local agent_pid="" agent_pgid=""

  # --- Channel 1: Paseo ---
  local paseo_bin="${HETERO_BIN_PASEO:-paseo}"
  # v2.1.0: on macOS the `paseo` on PATH is normally a symlink into Paseo.app's Electron
  # binary. Run headless it dies with "FATAL: Unable to find helper app" (exit 133) — but
  # hetero_spawn_pg backgrounds the process and never waits for an exit code, and stderr
  # went to /dev/null, so the dispatch record cheerfully recorded capability=FULL for an
  # agent that never existed. Callers then waited for evidence that could never arrive.
  # Detect the bundle and skip the channel rather than manufacture a receipt.
  local _paseo_real=""
  if command -v "$paseo_bin" >/dev/null 2>&1; then
    _paseo_real=$(readlink -f "$(command -v "$paseo_bin")" 2>/dev/null || command -v "$paseo_bin")
  fi
  if [[ -n "$_paseo_real" && "$_paseo_real" == *".app/Contents/MacOS"* ]]; then
    echo "hetero: skipping paseo channel — '$paseo_bin' resolves into an app bundle ($_paseo_real), which cannot dispatch headless. Have the calling agent create the Paseo agent over MCP instead." >&2
  elif [[ "${HETERO_CHAN_PASEO:-1}" == "1" ]] && [[ -n "$_paseo_real" ]]; then
    if _hetero_check_breaker "paseo/${role}"; then
      # F2: register-before-spawn — placeholder with PID=0/PGID=0 first
      hetero_register_spawn "paseo/${role}" 0 0
      # Model is configurable. The old hardcoded claude/opus meant this channel dispatched
      # a same-family reviewer while recording FULL; the default is kept for backward
      # compatibility, but capability is now decided by family, so the default no longer
      # earns FULL when the implementer is also Claude.
      local paseo_model="${HETERO_PASEO_MODEL:-claude/opus}"
      if hetero_spawn_pg "$paseo_bin" run --detach --provider "$paseo_model" --mode auto \
        --title "hetero-dispatch-${role}" --thinking "$effort" "$prompt" 2>/dev/null; then
        # For paseo, we just mark channel (actual agent startup is async)
        channel="paseo"
        # ⛔ Capped at EVIDENCE_ONLY regardless of model family. hetero_spawn_pg reports
        # only whether the SPAWN succeeded; this channel is fire-and-forget, so at this
        # moment nothing here knows whether an agent was actually created. Measured
        # 2026-08-24 with the same binary and got opposite outcomes — `hetero_dispatch`
        # returned success with no matching agent in `paseo agent ls`, while a hand-run
        # spawn of the identical command did create one. Grading FULL on an unverified
        # spawn is precisely the "receipt for an agent that never existed" that the comment
        # above this channel warns about.
        #
        # To earn FULL through Paseo, use the path that actually verifies:
        #   agent-gates-review --route paseo --dispatch-out <file>
        #   agent-gates-review --import-result <md> --token <t> --paseo-agent <id>
        # That one calls `paseo agent inspect` and checks the agent exists, its provider,
        # and that it was created after dispatch.
        capability="EVIDENCE_ONLY"
        agent_pid="${HETERO_LAST_ROOT_PID:-}"
        agent_pgid="${HETERO_LAST_PGID:-}"
        # Update registration with real PID/PGID now that spawn succeeded
        hetero_register_spawn "paseo/${role}" "${agent_pid}" "${agent_pgid:-$agent_pid}"
      else
        echo "spawn failed for paseo/${role}" >&2
      fi
    fi
  fi

  # --- Channel 2: pi (one-shot; preferred over opencode) ---
  # pi has no serve/daemon/port subcommand at all — `-p` processes the prompt and exits,
  # measured at ~200MB peak RSS with zero residue. opencode needs a long-lived
  # `opencode serve`, and when Paseo drives it every agent gets its OWN: measured at
  # 1-1.5GB RSS each and not reclaimed when the agent goes idle. On 2026-08-20 three such
  # serves were burning 52-86% CPU with no work in flight, on a machine down to 70MB free.
  # That is why pi is tried first.
  if [[ "$channel" == "exhausted" ]]; then
    local pi_bin="${HETERO_BIN_PI:-pi}"
    local pi_model="${HETERO_PI_MODEL:-}"
    if [[ "${HETERO_CHAN_PI:-1}" != "1" ]]; then
      :  # explicitly disabled
    elif [[ -z "$pi_model" ]]; then
      # Not configured -> step aside quietly. Adding a channel must not change existing
      # routing, so with no model set opencode handles this exactly as before. (Note the
      # contrast with the empty-HETERO_OC_MODEL bug: there an unset model produced
      # `opencode run -m ""`, which HANGS rather than failing fast. Skipping is the fix.)
      :
    elif [[ "$pi_model" != */* || -z "${pi_model%%/*}" || -z "${pi_model#*/}" ]]; then
      # A slash alone is not enough. 'github-copilot/' and '/gpt-5.4' both satisfy `*/*`
      # yet leave one side empty, producing `--model ""` or `--provider ""` — the very
      # empty-flag hang this guard exists to prevent (found by cross-review 2026-08-20).
      echo "hetero: skipping pi channel — HETERO_PI_MODEL='$pi_model' is not a valid '<provider>/<model>' pair (both sides must be non-empty), e.g. github-copilot/gpt-5.4 or volcengine-coding/deepseek-v4-flash." >&2
    elif command -v "$pi_bin" >/dev/null 2>&1; then
      if _hetero_check_breaker "pi/${role}"; then
        local pi_provider="${pi_model%%/*}" pi_id="${pi_model#*/}"
        hetero_register_spawn "pi/${role}" 0 0
        # Same contract as the opencode channel: stdout lands in the evidence file.
        if hetero_spawn_pg bash -c \
          '"$1" -p --provider "$2" --model "$3" "$4" >"$5" 2>/dev/null' \
          -- "$pi_bin" "$pi_provider" "$pi_id" "$prompt" "$evidence_path"; then
          channel="pi"
          capability=$(_hetero_capability_for "$pi_model")
          agent_pid="${HETERO_LAST_ROOT_PID:-}"
          agent_pgid="${HETERO_LAST_PGID:-}"
          hetero_register_spawn "pi/${role}" "${agent_pid}" "${agent_pgid:-$agent_pid}"
        else
          echo "spawn failed for pi/${role}" >&2
        fi
      fi
    fi
  fi

  # --- Channel 3: opencode (fail-closed) ---
  if [[ "$channel" == "exhausted" ]]; then
    local oc_bin="${HETERO_BIN_OPENCODE:-opencode}"
    # v2.1.0: an empty model is worse than a missing binary. `opencode run -m ""` does not
    # fail fast — it hangs, so the evidence file is created and stays 0 bytes while the
    # caller polls for a result that never comes. HETERO_OC_MODEL had no definition in
    # config.sh at all, so this was the default state of the verify channel.
    local oc_model="${HETERO_OC_MODEL:-}"
    if [[ "${HETERO_CHAN_OPENCODE:-0}" == "1" ]] && [[ -z "$oc_model" ]]; then
      echo "hetero: skipping opencode channel — no model configured. Set HETERO_OC_MODEL, or hetero_models.primary / review_models.primary in the capability file." >&2
    elif [[ "${HETERO_CHAN_OPENCODE:-0}" == "1" ]] && command -v "$oc_bin" >/dev/null 2>&1; then
      if _hetero_check_breaker "opencode/${role}"; then
        # fail-closed: must get OC_SERVE_URL from oc_serve_ensure, otherwise skip
        local serve_ok=0
        if oc_serve_ensure 2>/dev/null; then
          serve_ok=1
        fi

        if [[ "$serve_ok" == "1" ]]; then
          # F2: register-before-spawn — placeholder with PID=0/PGID=0 first
          hetero_register_spawn "opencode/${role}" 0 0
          # F7 fix: redirect opencode stdout to evidence file so EVIDENCE_ONLY output
          # is not discarded. Wrap in a shell so the redirect applies before exec.
          if hetero_spawn_pg bash -c \
            '"$1" run --attach "$2" --pure -m "$3" --dir "$4" --format json --variant "$7" "$5" >"$6" 2>/dev/null' \
            -- "$oc_bin" "$OC_SERVE_URL" "$oc_model" "${PWD}" "$prompt" "$evidence_path" "$effort"; then
            channel="opencode"
            capability=$(_hetero_capability_for "$oc_model")
            agent_pid="${HETERO_LAST_ROOT_PID:-}"
            agent_pgid="${HETERO_LAST_PGID:-}"
            # Update registration with real PID/PGID
            hetero_register_spawn "opencode/${role}" "${agent_pid}" "${agent_pgid:-$agent_pid}"
          else
            echo "spawn failed for opencode/${role}" >&2
          fi
        fi
        # else: serve not available, fail-closed → skip, channel stays exhausted
      fi
    fi
  fi

  # --- Channel 4: codex ---
  if [[ "$channel" == "exhausted" ]]; then
    local codex_bin="${HETERO_BIN_CODEX:-codex}"
    if [[ "${HETERO_CHAN_CODEX:-1}" == "1" ]] && command -v "$codex_bin" >/dev/null 2>&1; then
      if _hetero_check_breaker "codex/${role}"; then
        # F2: register-before-spawn — placeholder with PID=0/PGID=0 first
        hetero_register_spawn "codex/${role}" 0 0
        if hetero_spawn_pg "$codex_bin" exec -c "model_reasoning_effort=$effort" "$prompt" 2>/dev/null; then
          channel="codex"
          capability="EVIDENCE_ONLY"
          agent_pid="${HETERO_LAST_ROOT_PID:-}"
          agent_pgid="${HETERO_LAST_PGID:-}"
          # Update registration with real PID/PGID
          hetero_register_spawn "codex/${role}" "${agent_pid}" "${agent_pgid:-$agent_pid}"
        else
          echo "spawn failed for codex/${role}" >&2
        fi
      fi
    fi
  fi

  # --- Channel 5: codebuddy ---
  if [[ "$channel" == "exhausted" ]]; then
    local codebuddy_bin="${HETERO_BIN_CODEBUDDY:-codebuddy}"
    if [[ "${HETERO_CHAN_CODEBUDDY:-1}" == "1" ]] && command -v "$codebuddy_bin" >/dev/null 2>&1; then
      if _hetero_check_breaker "codebuddy/${role}"; then
        # F2: register-before-spawn — placeholder with PID=0/PGID=0 first
        hetero_register_spawn "codebuddy/${role}" 0 0
        # codebuddy: no effort flag supported; skip effort injection.
        if hetero_spawn_pg "$codebuddy_bin" -p "$prompt" 2>/dev/null; then
          channel="codebuddy"
          capability="EVIDENCE_ONLY"
          agent_pid="${HETERO_LAST_ROOT_PID:-}"
          agent_pgid="${HETERO_LAST_PGID:-}"
          # Update registration with real PID/PGID
          hetero_register_spawn "codebuddy/${role}" "${agent_pid}" "${agent_pgid:-$agent_pid}"
        else
          echo "spawn failed for codebuddy/${role}" >&2
        fi
      fi
    fi
  fi

  # --- Channel 5: echo fallback (exhausted) ---
  # channel stays "exhausted" if nothing else worked

  export HETERO_DISPATCH_CHANNEL="$channel"
  # Say what is missing rather than silently downgrading. Which specific model reviews is
  # the caller's choice — the tool only checks that the families differ, so it cannot guess
  # the implementer side and must be told.
  if [[ "$capability" == "EVIDENCE_ONLY" && "$channel" != "exhausted" && -z "${HETERO_IMPLEMENTER_FAMILY:-}" ]]; then
    echo "hetero: capability=EVIDENCE_ONLY because HETERO_IMPLEMENTER_FAMILY is unset. Declare the implementing model family (e.g. HETERO_IMPLEMENTER_FAMILY=anthropic) so the heterogeneity check can run. Heterogeneity is the requirement; picking the specific reviewer model is up to you." >&2
  fi

  export HETERO_DISPATCH_CAPABILITY="$capability"

  # Wall-clock watcher for successfully spawned channels
  local watcher_pid=""
  if [[ "$channel" != "exhausted" && -n "${agent_pid:-}" ]]; then
    # Register wall-clock watcher; HETERO_LAST_WATCHER_PID set by the function.
    local wall_s="${HETERO_AGENT_MAX_WALL_S:-600}"
    hetero_register_wall_watcher "${agent_pgid:-$agent_pid}" "$wall_s" "${channel}/${role}" "${agent_pid}" "$started_at"
    watcher_pid="${HETERO_LAST_WATCHER_PID:-}"
  fi

  # Write dispatch artifact (atomic: tmp → mv).
  # verify_dir was pre-computed above (for F7 evidence_path); reuse it here.
  local dispatch_json="${verify_dir}/${verify_run_id}.dispatch.json"
  local tmp_json="${dispatch_json}.tmp.$$"

  local ended_at
  ended_at=$(date +%s)
  local wall_elapsed=$(( ended_at - started_at ))

  # F4 fix: include watcher_pid so caller/janitor can kill it on normal agent exit.
  # F7 fix: include evidence_path so caller knows where opencode stdout was captured.
  python3 - <<PYEOF > "$tmp_json" 2>/dev/null
import json
print(json.dumps({
    "verify_run_id": "${verify_run_id}",
    "channel": "${channel}",
    "capability": "${capability}",
    "started_at": ${started_at},
    "wall_s": ${wall_elapsed},
    "HEAD": "${head_sha}",
    "staged_diff_hash": "${staged_diff_hash}",
    "watcher_pid": ${watcher_pid:-0},
    "evidence_path": "${evidence_path:-}"
}))
PYEOF

  mv "$tmp_json" "$dispatch_json" 2>/dev/null || {
    # Fallback: write directly if mv fails
    cat > "$dispatch_json" <<JSON
{"verify_run_id": "${verify_run_id}", "channel": "${channel}", "capability": "${capability}", "started_at": ${started_at}, "wall_s": ${wall_elapsed}, "HEAD": "${head_sha}", "staged_diff_hash": "${staged_diff_hash}", "watcher_pid": ${watcher_pid:-0}, "evidence_path": "${evidence_path:-}"}
JSON
  }

  export HETERO_DISPATCH_DISPATCH_JSON="$dispatch_json"
}

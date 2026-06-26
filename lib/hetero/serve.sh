#!/usr/bin/env bash
# lib/hetero/serve.sh — shared opencode serve management (v1.13.0).
# Sourceable library. Manages a persistent `opencode serve --pure --port $PORT`
# so all review runs can --attach to it, eliminating per-run serve stacking.

[[ -n "${_OC_SERVE_SOURCED:-}" ]] && return 0
_OC_SERVE_SOURCED=1

OC_SERVE_PORT="${OC_SERVE_PORT:-${OC_REVIEW_PORT:-4096}}"
OC_SERVE_URL="http://127.0.0.1:${OC_SERVE_PORT}"
OC_SERVE_LOCK_DIR="${OC_SERVE_LOCK_DIR:-/tmp/oc-serve-lock}"
OC_SERVE_START_RETRIES="${OC_SERVE_START_RETRIES:-20}"
OC_SERVE_OPENCODE="${OC_SERVE_OPENCODE:-opencode}"

oc_serve_acquire_lock() {
  if mkdir "$OC_SERVE_LOCK_DIR" 2>/dev/null; then
    echo $$ > "$OC_SERVE_LOCK_DIR/pid"
    return 0
  fi
  local lock_pid
  lock_pid=$(cat "$OC_SERVE_LOCK_DIR/pid" 2>/dev/null) || return 1
  if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
    rm -rf "$OC_SERVE_LOCK_DIR"
    if mkdir "$OC_SERVE_LOCK_DIR" 2>/dev/null; then
      echo $$ > "$OC_SERVE_LOCK_DIR/pid"
      return 0
    fi
  fi
  return 1
}

oc_serve_release_lock() {
  local lock_pid
  lock_pid=$(cat "$OC_SERVE_LOCK_DIR/pid" 2>/dev/null) || return 0
  if [[ "$lock_pid" == "$$" ]]; then
    rm -rf "$OC_SERVE_LOCK_DIR"
  fi
}

oc_serve_health_check() {
  curl -sf -m 2 "${OC_SERVE_URL}" >/dev/null 2>&1
}

oc_serve_has_live_clients() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$OC_SERVE_PORT" -sTCP:ESTABLISHED >/dev/null 2>&1 && return 0
  fi
  pgrep -f "opencode run.*attach.*:${OC_SERVE_PORT}" >/dev/null 2>&1 && return 0
  return 1
}

oc_serve_restart() {
  if oc_serve_has_live_clients; then
    return 1
  fi
  local serve_pid
  serve_pid=$(pgrep -f "opencode serve.*port ${OC_SERVE_PORT}" 2>/dev/null | head -1)
  if [[ -n "$serve_pid" ]]; then
    local _oc_serve_lib_dir
    _oc_serve_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! declare -f janitor_draining_lock >/dev/null 2>&1; then
      [[ -f "${_oc_serve_lib_dir}/janitor.sh" ]] && source "${_oc_serve_lib_dir}/janitor.sh"
    fi
    if ! declare -f hetero_kill_tree >/dev/null 2>&1; then
      [[ -f "${_oc_serve_lib_dir}/dispatch.sh" ]] && source "${_oc_serve_lib_dir}/dispatch.sh"
    fi
    if ! janitor_draining_lock "$OC_SERVE_LOCK_DIR" acquire 2>/dev/null; then
      return 1
    fi
    trap 'janitor_draining_lock "$OC_SERVE_LOCK_DIR" release 2>/dev/null; trap - RETURN' RETURN
    local serve_pgid
    serve_pgid=$(ps -o pgid= -p "$serve_pid" 2>/dev/null | tr -d ' ')
    hetero_kill_tree "${serve_pgid:-$serve_pid}"
    sleep 1
  fi
  _oc_serve_start
}

_oc_serve_start() {
  /usr/bin/nohup "$OC_SERVE_OPENCODE" serve --pure --port "$OC_SERVE_PORT" >/dev/null 2>&1 &
  local i
  for ((i=0; i<OC_SERVE_START_RETRIES; i++)); do
    if oc_serve_health_check; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

oc_serve_ensure() {
  [[ -d "$OC_SERVE_LOCK_DIR/.draining" ]] && return 1
  if oc_serve_health_check; then
    return 0
  fi
  if ! oc_serve_acquire_lock; then
    local i
    for ((i=0; i<OC_SERVE_START_RETRIES; i++)); do
      if oc_serve_health_check; then
        return 0
      fi
      sleep 0.5
    done
    return 1
  fi
  local rc=0
  _oc_serve_start || rc=1
  oc_serve_release_lock
  if [[ $rc -eq 0 ]] && oc_serve_health_check; then
    return 0
  fi
  return 1
}

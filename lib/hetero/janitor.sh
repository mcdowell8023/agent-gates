#!/usr/bin/env bash
# lib/hetero/janitor.sh — v2.0.0 hetero-check janitor measurement functions.
# Sourceable library. Provides three lightweight metrics used by the janitor
# to decide whether a long-running channel (opencode serve, agent process) should
# be reaped or allowed to continue.
#
# Functions:
#   janitor_measure_rss_tree  <root_pid>  — sum RSS (KB) for entire process tree
#   janitor_measure_age       <pid>       — process uptime in seconds
#   janitor_measure_runs      <lock_dir>  — consecutive run count from lock file

[[ -n "${_HETERO_JANITOR_SOURCED:-}" ]] && return 0
_HETERO_JANITOR_SOURCED=1

# ──────────────────────────────────────────────────────────────────────────────
# janitor_measure_rss_tree <root_pid>
#
# Walk the full process tree rooted at root_pid (parent → child → grandchild …)
# and return the sum of their RSS values in KB.
#
# Uses python3 to build the tree from `ps -o pid,ppid,rss` output.
# Falls back to a single-process `ps -o rss=` query when python3 is absent.
#
# Output: a single integer (KB) on stdout.
# ──────────────────────────────────────────────────────────────────────────────
janitor_measure_rss_tree() {
  local root_pid="${1:-}"
  if [[ -z "$root_pid" ]]; then
    echo "janitor_measure_rss_tree: missing root_pid" >&2
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    # Capture full process table: pid ppid rss (skip header with tail -n +2)
    local ps_out
    ps_out=$(ps -eo pid,ppid,rss 2>/dev/null || ps -o pid,ppid,rss 2>/dev/null) || true

    python3 - "$root_pid" <<'PYEOF'
import sys, collections

root = int(sys.argv[1])

children = collections.defaultdict(list)
rss_map   = {}

import subprocess
# Re-read inside python for reliable column parsing
try:
    out = subprocess.check_output(
        ["ps", "-eo", "pid,ppid,rss"],
        stderr=subprocess.DEVNULL,
        text=True,
    )
except subprocess.CalledProcessError:
    # macOS fallback: no -e flag
    try:
        out = subprocess.check_output(
            ["ps", "-ax", "-o", "pid,ppid,rss"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except subprocess.CalledProcessError:
        print(0)
        sys.exit(0)

for line in out.splitlines()[1:]:   # skip header
    parts = line.split()
    if len(parts) < 3:
        continue
    try:
        pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2])
    except ValueError:
        continue
    rss_map[pid] = rss
    children[ppid].append(pid)

total = 0
stack = [root]
while stack:
    pid = stack.pop()
    total += rss_map.get(pid, 0)
    stack.extend(children.get(pid, []))

print(total)
PYEOF
  else
    # Fallback: measure only the root process (imprecise but safe)
    ps -o rss= -p "$root_pid" 2>/dev/null | tr -d '[:space:]' || echo 0
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# janitor_measure_age <pid>
#
# Return how many seconds the process has been running.
# Parses `ps -o etime=` output which uses the format: [[DD-]HH:]MM:SS
#
# Output: a single integer (seconds) on stdout.
# ──────────────────────────────────────────────────────────────────────────────
janitor_measure_age() {
  local pid="${1:-}"
  if [[ -z "$pid" ]]; then
    echo "janitor_measure_age: missing pid" >&2
    return 1
  fi

  local etime
  etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d '[:space:]') || true

  if [[ -z "$etime" ]]; then
    echo 0
    return 0
  fi

  # Parse [[DD-]HH:]MM:SS  →  total seconds
  # Examples: "00:05"  "01:23:45"  "2-03:04:05"
  local days=0 hours=0 mins=0 secs=0
  local rest="$etime"

  # Strip days component (DD-)
  if [[ "$rest" == *-* ]]; then
    days="${rest%%-*}"
    rest="${rest#*-}"
  fi

  # Count colons to determine HH:MM:SS vs MM:SS
  local colon_count
  colon_count=$(echo "$rest" | tr -cd ':' | wc -c | tr -d '[:space:]')

  if [[ "$colon_count" -ge 2 ]]; then
    # HH:MM:SS
    hours="${rest%%:*}"; rest="${rest#*:}"
    mins="${rest%%:*}";  secs="${rest#*:}"
  else
    # MM:SS
    mins="${rest%%:*}"; secs="${rest#*:}"
  fi

  # Strip leading zeros to avoid octal interpretation
  days="${days#0}";  days="${days:-0}"
  hours="${hours#0}"; hours="${hours:-0}"
  mins="${mins#0}";  mins="${mins:-0}"
  secs="${secs#0}";  secs="${secs:-0}"

  echo $(( days * 86400 + hours * 3600 + mins * 60 + secs ))
}

# ──────────────────────────────────────────────────────────────────────────────
# janitor_measure_runs <lock_dir>
#
# Read the integer stored in $lock_dir/run_count.
# Returns 0 if the file does not exist or is empty.
#
# Output: a single integer on stdout.
# ──────────────────────────────────────────────────────────────────────────────
janitor_measure_runs() {
  local lock_dir="${1:-}"
  if [[ -z "$lock_dir" ]]; then
    echo 0
    return 0
  fi

  local count_file="$lock_dir/run_count"
  if [[ ! -f "$count_file" ]]; then
    echo 0
    return 0
  fi

  local val
  val=$(cat "$count_file" 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$val" || ! "$val" =~ ^[0-9]+$ ]]; then
    echo 0
    return 0
  fi

  echo "$val"
}

# ──────────────────────────────────────────────────────────────────────────────
# janitor_check_budget <root_pid> <lock_dir>
#
# Compare current RSS/age/runs against configured limits.
# Sources config.sh if not already loaded; env vars take priority over config.
#
# Returns 0 when all metrics are within budget; returns 1 when any limit is exceeded.
# Prints one human-readable line on stdout ("budget OK" or "budget EXCEEDED: …").
# ──────────────────────────────────────────────────────────────────────────────
janitor_check_budget() {
  local root_pid="${1:-}"
  local lock_dir="${2:-}"

  if [[ -z "$root_pid" || -z "$lock_dir" ]]; then
    echo "janitor_check_budget: missing root_pid or lock_dir" >&2
    return 1
  fi

  # Load config (env overrides respected via _hetero_resolve priority).
  local _jcb_lib_dir
  _jcb_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -z "${_HETERO_CONFIG_SOURCED:-}" && -f "${_jcb_lib_dir}/config.sh" ]]; then
    # shellcheck source=lib/hetero/config.sh
    source "${_jcb_lib_dir}/config.sh"
  fi
  if declare -f hetero_load_config >/dev/null 2>&1; then
    hetero_load_config 2>/dev/null || true
  fi

  local max_mb="${HETERO_OC_RSS_MAX_MB:-1500}"
  local max_age="${HETERO_OC_MAX_AGE_S:-7200}"
  local max_runs="${HETERO_OC_MAX_RUNS:-50}"
  local max_kb=$(( max_mb * 1024 ))

  local rss age runs
  rss=$(janitor_measure_rss_tree "$root_pid"); rss="${rss:-0}"
  age=$(janitor_measure_age      "$root_pid"); age="${age:-0}"
  runs=$(janitor_measure_runs    "$lock_dir"); runs="${runs:-0}"

  if (( rss > max_kb )); then
    local rss_mb=$(( rss / 1024 ))
    echo "budget EXCEEDED: rss=${rss_mb}MB>${max_mb}MB"
    return 1
  fi
  if (( age > max_age )); then
    echo "budget EXCEEDED: age=${age}s>${max_age}s"
    return 1
  fi
  if (( runs > max_runs )); then
    echo "budget EXCEEDED: runs=${runs}>${max_runs}"
    return 1
  fi

  echo "budget OK"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# janitor_draining_lock <lock_dir> <action>
#
# Manage a $lock_dir/.draining directory-based mutex.
#
#   acquire  mkdir atomically; returns 0 on success, 1 if already held.
#   release  rm -rf the lock directory.
#   check    returns 0 if the lock exists, 1 if it does not.
# ──────────────────────────────────────────────────────────────────────────────
janitor_draining_lock() {
  local lock_dir="${1:-}"
  local action="${2:-check}"

  case "$action" in
    acquire)
      mkdir -p "${lock_dir}" 2>/dev/null
      mkdir "${lock_dir}/.draining" 2>/dev/null && return 0 || return 1
      ;;
    release)
      rm -rf "${lock_dir}/.draining"
      return 0
      ;;
    check)
      [[ -d "${lock_dir}/.draining" ]] && return 0 || return 1
      ;;
    *)
      echo "janitor_draining_lock: unknown action '$action'" >&2
      return 1
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# janitor_recycle_serve <lock_dir>
#
# Safely drain and kill the shared opencode serve process.
#
# Flow:
#   1. Acquire .draining lock (fail → return 1; another recycler is active).
#   2. Wait up to 30 s (2-s intervals) for live clients to disconnect.
#      Timeout with clients still present → release lock + return 1 (no force-kill).
#   3. Read serve PID from $lock_dir/serve_pid → hetero_kill_tree.
#   4. Release .draining lock → return 0.
#
# Dependencies (serve.sh / dispatch.sh) are sourced lazily only when the
# required functions are not already defined, preserving test-mock overrides.
# ──────────────────────────────────────────────────────────────────────────────
janitor_recycle_serve() {
  local lock_dir="${1:-}"

  if [[ -z "$lock_dir" ]]; then
    echo "janitor_recycle_serve: missing lock_dir" >&2
    return 1
  fi

  # Lazy-source serve.sh / dispatch.sh only when functions are absent
  # (keeps test mocks intact when they are pre-defined).
  local _jrs_lib_dir
  _jrs_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if ! declare -f oc_serve_has_live_clients >/dev/null 2>&1; then
    local _srv="${_jrs_lib_dir}/serve.sh"
    [[ -f "$_srv" ]] && source "$_srv"
  fi
  if ! declare -f hetero_kill_tree >/dev/null 2>&1; then
    local _dsp="${_jrs_lib_dir}/dispatch.sh"
    [[ -f "$_dsp" ]] && source "$_dsp"
  fi

  # Step 1: acquire draining lock.
  if ! janitor_draining_lock "$lock_dir" "acquire"; then
    return 1
  fi

  # Step 2: wait for live clients to disconnect (max 30 s).
  local waited=0 timed_out=0
  while oc_serve_has_live_clients 2>/dev/null; do
    if (( waited >= 30 )); then
      timed_out=1
      break
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done

  if (( timed_out )); then
    janitor_draining_lock "$lock_dir" "release"
    return 1
  fi

  # Step 3: kill serve process group.
  local serve_pid
  serve_pid=$(cat "${lock_dir}/serve_pid" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$serve_pid" ]]; then
    local serve_pgid
    serve_pgid=$(ps -o pgid= -p "$serve_pid" 2>/dev/null | tr -d ' ')
    hetero_kill_tree "${serve_pgid:-$serve_pid}"
  fi

  # Step 4: release draining lock.
  janitor_draining_lock "$lock_dir" "release"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# janitor_record_exit <key> <root_pid> <pgid> <exit_code> <started_at>
#
# Write an exit record to $HETERO_LOCK_DIR/exits/<key_safe>.<started_at>.json
# (key_safe: / and . replaced with _).  Atomic write via tmp+mv.
#
# JSON: {"key":"...","root_pid":N,"pgid":N,"exit_code":N,
#        "started_at":N,"exited_at":N,"rss_peak":N}
# ──────────────────────────────────────────────────────────────────────────────
janitor_record_exit() {
  local key="${1:-}"
  local root_pid="${2:-}"
  local pgid="${3:-}"
  local exit_code="${4:-0}"
  local started_at="${5:-0}"
  local lock_dir="${HETERO_LOCK_DIR:-/tmp/hetero-lock-$$}"
  local exits_dir="$lock_dir/exits"

  if [[ -z "$key" || -z "$root_pid" ]]; then
    echo "janitor_record_exit: missing key or root_pid" >&2
    return 1
  fi

  local exited_at
  exited_at=$(date +%s)

  local rss_peak
  rss_peak=$(janitor_measure_rss_tree "$root_pid" 2>/dev/null) || true
  rss_peak="${rss_peak:-0}"
  [[ "$rss_peak" =~ ^[0-9]+$ ]] || rss_peak=0

  local key_safe="${key//\//_}"
  key_safe="${key_safe//./_}"

  mkdir -p "$exits_dir"

  local file="$exits_dir/${key_safe}.${started_at}.json"
  local tmp_file="${file}.tmp.$$"

  printf '{"key":"%s","root_pid":%s,"pgid":%s,"exit_code":%s,"started_at":%s,"exited_at":%s,"rss_peak":%s}\n' \
    "$key" "$root_pid" "$pgid" "$exit_code" "$started_at" "$exited_at" "$rss_peak" \
    > "$tmp_file"
  mv "$tmp_file" "$file"
}

# ──────────────────────────────────────────────────────────────────────────────
# janitor_sweep <lock_dir>
#
# Scan all attribution records in <lock_dir>/spawns/.
#   alive  → check budget; if exceeded and no live clients → hetero_kill_tree
#   dead   → janitor_record_exit + rm spawn file
#
# Prints: "sweep: N alive, M reaped, K budget-killed"
# ──────────────────────────────────────────────────────────────────────────────
janitor_sweep() {
  local lock_dir="${1:-${HETERO_LOCK_DIR:-/tmp/hetero-lock-$$}}"
  local spawns_dir="$lock_dir/spawns"

  local _jsw_lib_dir
  _jsw_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if ! declare -f hetero_kill_tree >/dev/null 2>&1; then
    local _dsp="${_jsw_lib_dir}/dispatch.sh"
    [[ -f "$_dsp" ]] && source "$_dsp"
  fi

  local alive=0 reaped=0 budget_killed=0

  if [[ ! -d "$spawns_dir" ]]; then
    printf 'sweep: %d alive, %d reaped, %d budget-killed\n' "$alive" "$reaped" "$budget_killed"
    return 0
  fi

  local spawn_file
  while IFS= read -r spawn_file; do
    [[ -f "$spawn_file" ]] || continue

    local parsed key root_pid pgid started_at
    parsed=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('key', ''))
    print(d.get('root_pid', 0))
    print(d.get('pgid', 0))
    print(d.get('started_at', 0))
except Exception:
    print('')
    print(0)
    print(0)
    print(0)
" "$spawn_file" 2>/dev/null) || true
    key=$(printf '%s\n' "$parsed" | sed -n '1p')
    root_pid=$(printf '%s\n' "$parsed" | sed -n '2p')
    pgid=$(printf '%s\n' "$parsed" | sed -n '3p')
    started_at=$(printf '%s\n' "$parsed" | sed -n '4p')

    [[ -z "$key" || -z "$root_pid" ]] && continue
    [[ "$root_pid" == "0" ]] && continue

    if kill -0 "$root_pid" 2>/dev/null; then
      alive=$(( alive + 1 ))
      if ! janitor_check_budget "$root_pid" "$lock_dir" >/dev/null 2>&1; then
        local has_clients=0
        if declare -f oc_serve_has_live_clients >/dev/null 2>&1; then
          oc_serve_has_live_clients 2>/dev/null && has_clients=1 || has_clients=0
        fi
        if [[ "$has_clients" == "0" ]]; then
          hetero_kill_tree "${pgid:-$root_pid}"
          budget_killed=$(( budget_killed + 1 ))
          alive=$(( alive - 1 ))
          rm -f "$spawn_file"
        fi
      fi
    else
      local rc=-1
      janitor_record_exit "$key" "$root_pid" "${pgid:-$root_pid}" "$rc" "${started_at:-0}"
      rm -f "$spawn_file"
      reaped=$(( reaped + 1 ))
    fi

  done < <(find "$spawns_dir" -maxdepth 1 -name "*.json" -type f 2>/dev/null | sort)

  printf 'sweep: %d alive, %d reaped, %d budget-killed\n' "$alive" "$reaped" "$budget_killed"
}

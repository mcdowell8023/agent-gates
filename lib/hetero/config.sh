#!/usr/bin/env bash
# lib/hetero/config.sh — v2.0.0 hetero-check configuration loader.
# Sourceable library. Reads $AGENT_GATES_DIR/hetero-check.json (falls back to
# review-capability.json dual-read for v1.x compatibility) and applies env overrides.
#
# Override priority: env > hetero-check.json > review-capability.json (legacy) > builtin default.
#
# Exports (after hetero_load_config):
#   HETERO_OC_RSS_MAX_MB     opencode serve tree-RSS limit (MB)
#   HETERO_OC_MAX_AGE_S      opencode serve max age (seconds)
#   HETERO_OC_MAX_RUNS       opencode serve max run count
#   HETERO_AGENT_MAX_WALL_S  wall-clock limit for any agent channel (seconds)
#   HETERO_CRASH_LOOP_MAX    consecutive cold-start deaths before breaker trips
#   HETERO_COLD_START_S      threshold below which a non-zero exit counts as "cold start"
#   HETERO_COOLDOWN_S        after this many seconds since last failure, breaker count resets
#   HETERO_CHAN_PASEO        1 = channel enabled (default), 0 = skip
#   HETERO_CHAN_OPENCODE
#   HETERO_CHAN_CODEX
#   HETERO_CHAN_CODEBUDDY

[[ -n "${_HETERO_CONFIG_SOURCED:-}" ]] && return 0
_HETERO_CONFIG_SOURCED=1

# Builtin defaults (lowest priority). Mirrors design §7 schema.
_HETERO_DEFAULT_OC_RSS_MAX_MB=1500
_HETERO_DEFAULT_OC_MAX_AGE_S=7200
_HETERO_DEFAULT_OC_MAX_RUNS=50
_HETERO_DEFAULT_AGENT_MAX_WALL_S=600
_HETERO_DEFAULT_CRASH_LOOP_MAX=3
_HETERO_DEFAULT_COLD_START_S=10
_HETERO_DEFAULT_COOLDOWN_S=300
# v2.1.0: this had no definition at all, so dispatch.sh ran `opencode run -m ""`, which
# hangs instead of failing fast and leaves a 0-byte evidence file. The verify channel was
# therefore never functional unless the caller happened to export HETERO_OC_MODEL by hand.
_HETERO_DEFAULT_OC_MODEL="github-copilot/gpt-5.5"

# Path to the gates config dir (mirrors bin/agent-gates-review convention).
_hetero_gates_dir() {
  printf '%s' "${AGENT_GATES_DIR:-$HOME/.agent-gates}"
}

# Read a JSON field via python3; returns empty string on any failure.
# Usage: _hetero_json_get <file> <dotted.path>
# Example: _hetero_json_get "$file" lifecycle.opencode.rss_max_mb
_hetero_json_get() {
  local file="$1" path="$2"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$path" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
node = d
for part in sys.argv[2].split('.'):
    if not isinstance(node, dict) or part not in node:
        sys.exit(0)
    node = node[part]
if isinstance(node, bool):
    print('1' if node else '0')
elif node is None:
    sys.exit(0)
else:
    print(node)
PYEOF
}

# Resolve a single config value with priority: env > json (new) > json (legacy) > default.
# Usage: _hetero_resolve <env_var> <new_json_path> <legacy_json_path> <default>
# Sets the named env var (exports it) if not already set by the caller.
_hetero_resolve() {
  local env_var="$1" new_path="$2" legacy_path="$3" default="$4"
  # Already set by env — env wins.
  if [[ -n "${!env_var:-}" ]]; then
    export "$env_var"
    return 0
  fi
  local file
  file="$(_hetero_gates_dir)/hetero-check.json"
  local val
  val=$(_hetero_json_get "$file" "$new_path")
  if [[ -z "$val" ]]; then
    file="$(_hetero_gates_dir)/review-capability.json"
    val=$(_hetero_json_get "$file" "$legacy_path")
  fi
  if [[ -z "$val" ]]; then
    val="$default"
  fi
  export "$env_var=$val"
}

# Resolve a channel enable flag: env > hetero-check.json.channels.<name>.enabled > default.
# Usage: _hetero_resolve_chan <env_var> <channel_name> [default=1]
_hetero_resolve_chan() {
  local env_var="$1" chan="$2" default="${3:-1}"
  if [[ -n "${!env_var:-}" ]]; then
    export "$env_var"
    return 0
  fi
  local file val
  file="$(_hetero_gates_dir)/hetero-check.json"
  val=$(_hetero_json_get "$file" "channels.${chan}.enabled")
  if [[ -z "$val" ]]; then
    val="$default"
  fi
  export "$env_var=$val"
}

hetero_load_config() {
  _hetero_resolve HETERO_OC_RSS_MAX_MB   lifecycle.opencode.rss_max_mb  lifecycle.opencode.rss_max_mb  "$_HETERO_DEFAULT_OC_RSS_MAX_MB"
  _hetero_resolve HETERO_OC_MAX_AGE_S    lifecycle.opencode.max_age_s   lifecycle.opencode.max_age_s   "$_HETERO_DEFAULT_OC_MAX_AGE_S"
  _hetero_resolve HETERO_OC_MAX_RUNS     lifecycle.opencode.max_runs    lifecycle.opencode.max_runs    "$_HETERO_DEFAULT_OC_MAX_RUNS"
  _hetero_resolve HETERO_AGENT_MAX_WALL_S lifecycle.agent_max_wall_s    lifecycle.agent_max_wall_s     "$_HETERO_DEFAULT_AGENT_MAX_WALL_S"
  _hetero_resolve HETERO_CRASH_LOOP_MAX  lifecycle.crash_loop_max       lifecycle.crash_loop_max       "$_HETERO_DEFAULT_CRASH_LOOP_MAX"
  _hetero_resolve HETERO_COLD_START_S    lifecycle.cold_start_s         lifecycle.cold_start_s         "$_HETERO_DEFAULT_COLD_START_S"
  _hetero_resolve HETERO_COOLDOWN_S      lifecycle.cooldown_s           lifecycle.cooldown_s           "$_HETERO_DEFAULT_COOLDOWN_S"
  # Same model the review side uses, so verify and review stay on one configured reviewer.
  _hetero_resolve      HETERO_OC_MODEL   hetero_models.primary  review_models.primary  "$_HETERO_DEFAULT_OC_MODEL"
  # pi channel model — deliberately NO default. An unconfigured pi channel must step aside
  # so that adding it cannot silently re-route existing installs. Resolved from
  # pi_models.primary only; it must NOT fall back to review_models.primary, which would
  # auto-enable pi for everyone who already configured a reviewer.
  _hetero_resolve      HETERO_PI_MODEL   pi_models.primary      pi_models.primary      ""
  # The implementer family must be configurable, not env-only. Requiring every agent to
  # export it by hand is how it ends up unset — and unset means EVIDENCE_ONLY on every
  # high-risk path, i.e. an ACK every single time. No default: fail-closed stands.
  _hetero_resolve      HETERO_IMPLEMENTER_FAMILY implementer_family implementer_family ""
  _hetero_resolve_chan HETERO_CHAN_PASEO     paseo
  _hetero_resolve_chan HETERO_CHAN_PI        pi
  # opencode defaults OFF as a review channel (2026-08-26). Measured repeatedly timing out
  # — 120s through agent-gates-review, 200s through a manual `--attach`, and that was with a
  # minimal prompt — while pi returns in ~7s. It also needs a long-lived `opencode serve`,
  # observed at 4 days uptime and 133 minutes of CPU with no client anywhere on the machine.
  # Sessions were being blocked on review rather than on development.
  # ⛔ The channel is NOT removed: others may still depend on it, so it stays one flag away
  # (channels.opencode.enabled=true, or HETERO_CHAN_OPENCODE=1).
  _hetero_resolve_chan HETERO_CHAN_OPENCODE  opencode  0
  _hetero_resolve_chan HETERO_CHAN_CODEX     codex
  _hetero_resolve_chan HETERO_CHAN_CODEBUDDY codebuddy
}

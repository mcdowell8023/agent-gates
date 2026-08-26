#!/usr/bin/env bash
# Tests for per-channel default enablement.
#
# Why opencode defaults to OFF as a review channel (2026-08-26): measured repeatedly timing
# out — 120s through agent-gates-review, 200s through a manual `--attach`, and that was with
# a minimal prompt — while pi returns in ~7s. It also requires a long-lived `opencode serve`,
# observed at 4 days uptime / 133 minutes of CPU with no client anywhere on the machine.
# Sessions were blocked on review, not on development.
#
# The channel is NOT removed: others may still rely on it, so it stays one config flag away.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_LIB="$SCRIPT_DIR/../lib/hetero/config.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

load_fresh() {   # load_fresh [json-body]
  _HETERO_CONFIG_SOURCED=""
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  [[ -n "${1:-}" ]] && printf '%s\n' "$1" > "$AGENT_GATES_DIR/hetero-check.json"
  unset HETERO_CHAN_PASEO HETERO_CHAN_PI HETERO_CHAN_OPENCODE HETERO_CHAN_CODEX HETERO_CHAN_CODEBUDDY
  source "$CONFIG_LIB"
  hetero_load_config
}

echo "=== hetero channel default tests ==="
echo

echo "D1: 无配置时 opencode 默认关闭，其余默认开启"
( load_fresh
  assert "opencode 默认 0 (实际 ${HETERO_CHAN_OPENCODE:-?})" "$([[ "${HETERO_CHAN_OPENCODE:-}" == 0 ]] && echo true || echo false)"
  assert "pi 默认 1 (实际 ${HETERO_CHAN_PI:-?})"           "$([[ "${HETERO_CHAN_PI:-}" == 1 ]] && echo true || echo false)"
  assert "paseo 默认 1 (实际 ${HETERO_CHAN_PASEO:-?})"     "$([[ "${HETERO_CHAN_PASEO:-}" == 1 ]] && echo true || echo false)"
  assert "codebuddy 默认 1"                                "$([[ "${HETERO_CHAN_CODEBUDDY:-}" == 1 ]] && echo true || echo false)"
  rm -rf "$AGENT_GATES_DIR" )

echo "D2: 配置可显式恢复 opencode（没有被删掉，只是默认不用）"
( load_fresh '{"channels":{"opencode":{"enabled":true}}}'
  assert "配置 enabled=true 后为 1 (实际 ${HETERO_CHAN_OPENCODE:-?})" "$([[ "${HETERO_CHAN_OPENCODE:-}" == 1 ]] && echo true || echo false)"
  rm -rf "$AGENT_GATES_DIR" )

echo "D3: env 优先于配置与默认"
( load_fresh '{"channels":{"opencode":{"enabled":false}}}'
  _HETERO_CONFIG_SOURCED=""; export HETERO_CHAN_OPENCODE=1
  source "$CONFIG_LIB"; hetero_load_config
  assert "env=1 覆盖配置的 false" "$([[ "${HETERO_CHAN_OPENCODE:-}" == 1 ]] && echo true || echo false)"
  unset HETERO_CHAN_OPENCODE; rm -rf "$AGENT_GATES_DIR" )

echo "D4: 配置可关闭默认开启的通道（对称性）"
( load_fresh '{"channels":{"pi":{"enabled":false}}}'
  assert "pi 可被配置关闭" "$([[ "${HETERO_CHAN_PI:-}" == 0 ]] && echo true || echo false)"
  rm -rf "$AGENT_GATES_DIR" )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]

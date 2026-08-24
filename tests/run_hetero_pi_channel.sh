#!/usr/bin/env bash
# Tests for the `pi` dispatch channel (added 2026-08-20).
#
# Why pi is placed BEFORE opencode: pi is one-shot (no serve/daemon/port subcommand at
# all — `-p` processes and exits). opencode needs a long-lived `opencode serve`; when
# Paseo drives it, each agent gets its OWN serve, measured at 1-1.5GB RSS and not
# reclaimed when the agent goes idle — three of them burning 52-86% CPU each was what
# prompted this channel (2026-08-20).
#
# Why a missing HETERO_PI_MODEL must SKIP rather than default: adding a channel must not
# silently change existing routing. With no model configured the channel steps aside and
# opencode keeps handling the request exactly as before.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_LIB="$SCRIPT_DIR/../lib/hetero/dispatch.sh"
CONFIG_LIB="$SCRIPT_DIR/../lib/hetero/config.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

# Fail-safe, set at file scope: a bug inside a per-test helper must not be able to reach
# the real paseo/codex/codebuddy. Learned the hard way — `fd=$(prep ok)` ran its exports
# in a command-substitution subshell, so HETERO_BIN_PASEO never took effect and the test
# created a real Paseo claude agent.
export HETERO_BIN_PASEO=/nonexistent-paseo
export HETERO_BIN_CODEX=/nonexistent-codex
export HETERO_BIN_CODEBUDDY=/nonexistent-codebuddy

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

source_dispatch() {
  _HETERO_CONFIG_SOURCED=""
  _HETERO_DISPATCH_SOURCED=""
  _OC_SERVE_SOURCED=""
  HETERO_LOCK_DIR=$(mktemp -d)
  export HETERO_LOCK_DIR
  # Isolate from the machine's real hetero-check.json: channel selection and capability are
  # both configurable, so without this the result depends on the user's config. Observed
  # 2026-08-24 — a real config with pi_models.primary + implementer_family made pi win the
  # dispatch and earn FULL, failing five assertions that assumed opencode/EVIDENCE_ONLY.
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  unset HETERO_IMPLEMENTER_FAMILY HETERO_PI_MODEL HETERO_PASEO_MODEL
  source "$CONFIG_LIB"
  source "$DISPATCH_LIB"
}

setup_mock_repo() {
  MOCK_REPO=$(mktemp -d)
  cd "$MOCK_REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  echo init > README.md; git add README.md; git commit -q -m init
}
teardown_mock_repo() { cd /; [[ -n "${MOCK_REPO:-}" && -d "$MOCK_REPO" ]] && rm -rf "$MOCK_REPO"; }

# fake pi — records argv so the test can assert --provider/--model were split correctly.
make_fake_pi() {
  local mode="$1" fake_dir="$2"
  cat > "$fake_dir/pi" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$fake_dir/pi_argv.txt"
[[ "$mode" == "fail" ]] && exit 1
echo "pi review body — VERDICT: PASS"
exit 0
FAKE
  chmod +x "$fake_dir/pi"
}
make_fake_opencode() {
  local fake_dir="$1"
  cat > "$fake_dir/opencode" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  serve) exit 0 ;;
  run)   echo "opencode body — VERDICT: PASS"; exit 0 ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$fake_dir/opencode"
}
make_fake_curl() { printf '#!/usr/bin/env bash\nexit 0\n' > "$1/curl"; chmod +x "$1/curl"; }
make_fake_nohup() { printf '#!/usr/bin/env bash\nexec "$@"\n' > "$1/nohup"; chmod +x "$1/nohup"; }

# Sets FAKE_DIR in the CALLER's shell. Must not be invoked via $(...) — a command
# substitution would run every export in a subshell and silently discard it.
prep() {
  FAKE_DIR=$(mktemp -d)
  make_fake_pi "${1:-ok}" "$FAKE_DIR"; make_fake_opencode "$FAKE_DIR"
  make_fake_curl "$FAKE_DIR"; make_fake_nohup "$FAKE_DIR"
  export PATH="$FAKE_DIR:$PATH"
}

echo "=== hetero pi channel tests ==="
echo

# P1: pi available + model configured -> pi channel
echo "P1: pi 可用 + 模型已配 → 走 pi 通道"
(
  setup_mock_repo; source_dispatch
  prep ok; fd="$FAKE_DIR"
  export HETERO_PI_MODEL="github-copilot/gpt-5.4"
  hetero_dispatch "reviewer" "test prompt" 0 2>/dev/null
  assert "channel == pi (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == "pi" ]] && echo true || echo false)"
  assert "capability == EVIDENCE_ONLY" "$([[ "${HETERO_DISPATCH_CAPABILITY:-}" == "EVIDENCE_ONLY" ]] && echo true || echo false)"
  # provider/model must be split into two flags, not passed as one "provider/model" string.
  # hetero_spawn_pg backgrounds the process, so wait for the fake to write its argv.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$fd/pi_argv.txt" ]] && break; sleep 0.2; done
  argv=$(cat "$fd/pi_argv.txt" 2>/dev/null | tr '\n' ' ')
  assert "argv 含 --provider github-copilot" "$([[ "$argv" == *"--provider github-copilot"* ]] && echo true || echo false)"
  assert "argv 含 --model gpt-5.4（已拆分）" "$([[ "$argv" == *"--model gpt-5.4"* ]] && echo true || echo false)"
  assert "argv 不含未拆分的 github-copilot/gpt-5.4" "$([[ "$argv" != *"github-copilot/gpt-5.4"* ]] && echo true || echo false)"
  rm -rf "$fd" "$HETERO_LOCK_DIR"; teardown_mock_repo
)

# P2: both pi and opencode available -> pi wins (it does not spawn a serve)
echo "P2: pi 与 opencode 都可用 → 选 pi（优先级在 opencode 之前）"
(
  setup_mock_repo; source_dispatch
  prep ok; fd="$FAKE_DIR"
  export HETERO_PI_MODEL="volcengine-coding/deepseek-v4-flash"
  export HETERO_OC_MODEL="github-copilot/gpt-5.5"
  hetero_dispatch "reviewer" "test prompt" 0 2>/dev/null
  assert "channel == pi 而非 opencode (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == "pi" ]] && echo true || echo false)"
  rm -rf "$fd" "$HETERO_LOCK_DIR"; teardown_mock_repo
)

# P3: no model configured -> skip pi, fall through to opencode (existing routing intact)
echo "P3: HETERO_PI_MODEL 未设 → 跳过 pi，落 opencode（不改变既有路由）"
(
  setup_mock_repo; source_dispatch
  prep ok; fd="$FAKE_DIR"
  unset HETERO_PI_MODEL
  export HETERO_OC_MODEL="github-copilot/gpt-5.5"
  hetero_dispatch "reviewer" "test prompt" 0 2>/dev/null
  assert "channel == opencode (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == "opencode" ]] && echo true || echo false)"
  rm -rf "$fd" "$HETERO_LOCK_DIR"; teardown_mock_repo
)

# P4: model without a provider prefix -> skip with a diagnostic, do not guess
echo "P4: HETERO_PI_MODEL 缺 provider 前缀 → 跳过并报错（不猜）"
(
  setup_mock_repo; source_dispatch
  prep ok; fd="$FAKE_DIR"
  export HETERO_PI_MODEL="gpt-5.4"
  export HETERO_OC_MODEL="github-copilot/gpt-5.5"
  # Not `err=$(hetero_dispatch ...)`: a command substitution runs in a subshell, so
  # HETERO_DISPATCH_CHANNEL would be lost. Capture stderr to a file instead.
  hetero_dispatch "reviewer" "test prompt" 0 2>"$fd/err.txt" >/dev/null
  err=$(cat "$fd/err.txt" 2>/dev/null)
  assert "channel 落回 opencode (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == "opencode" ]] && echo true || echo false)"
  assert "stderr 说明原因" "$([[ "$err" == *"pi"* && "$err" == *"provider"* ]] && echo true || echo false)"
  rm -rf "$fd" "$HETERO_LOCK_DIR"; teardown_mock_repo
)

# P4b: a slash is not enough — an empty provider or model must also be rejected.
# `github-copilot/` passes `!= */*` yet yields `--model ""`, which is exactly the
# empty-flag hang the guard exists to prevent (found by cross-review, 2026-08-20).
echo "P4b: provider 或 model 为空 → 跳过并报错"
for bad in "github-copilot/" "/gpt-5.4" "/"; do
(
  setup_mock_repo; source_dispatch
  prep ok; fd="$FAKE_DIR"
  export HETERO_PI_MODEL="$bad"
  export HETERO_OC_MODEL="github-copilot/gpt-5.5"
  hetero_dispatch "reviewer" "test prompt" 0 2>"$fd/err.txt" >/dev/null
  err=$(cat "$fd/err.txt" 2>/dev/null)
  assert "HETERO_PI_MODEL='$bad' → 落回 opencode (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == "opencode" ]] && echo true || echo false)"
  assert "HETERO_PI_MODEL='$bad' → stderr 说明原因" "$([[ "$err" == *"pi"* ]] && echo true || echo false)"
  rm -rf "$fd" "$HETERO_LOCK_DIR"; teardown_mock_repo
)
done

# P5: explicit disable
echo "P5: HETERO_CHAN_PI=0 → 显式禁用"
(
  setup_mock_repo; source_dispatch
  prep ok; fd="$FAKE_DIR"
  export HETERO_PI_MODEL="github-copilot/gpt-5.4"
  export HETERO_OC_MODEL="github-copilot/gpt-5.5"
  export HETERO_CHAN_PI=0
  hetero_dispatch "reviewer" "test prompt" 0 2>/dev/null
  assert "channel == opencode (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == "opencode" ]] && echo true || echo false)"
  rm -rf "$fd" "$HETERO_LOCK_DIR"; teardown_mock_repo
)

# P6: pi stdout must land in the evidence file, same contract as the opencode channel
echo "P6: pi 输出写入 evidence 文件"
(
  setup_mock_repo; source_dispatch
  prep ok; fd="$FAKE_DIR"
  export HETERO_PI_MODEL="github-copilot/gpt-5.4"
  hetero_dispatch "reviewer" "test prompt" 0 2>/dev/null
  # evidence_path is not exported as an env var; it is recorded in the dispatch JSON.
  dj="${HETERO_DISPATCH_DISPATCH_JSON:-}"
  assert "dispatch JSON 路径已设" "$([[ -n "$dj" && -f "$dj" ]] && echo true || echo false)"
  ev=$(sed -n 's/.*"evidence_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dj" 2>/dev/null | head -1)
  assert "dispatch JSON 含 evidence_path" "$([[ -n "$ev" ]] && echo true || echo false)"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$ev" ]] && break; sleep 0.2; done
  assert "evidence 文件含 pi 输出" "$([[ -s "$ev" ]] && grep -q 'pi review body' "$ev" 2>/dev/null && echo true || echo false)"
  rm -rf "$fd" "$HETERO_LOCK_DIR"; teardown_mock_repo
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]

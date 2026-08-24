#!/usr/bin/env bash
# Tests for capability resolution — FULL vs EVIDENCE_ONLY.
#
# What capability used to mean: "the paseo channel was used". That was broken in a way
# nothing detected — dispatch.sh hardcoded `paseo run --provider claude/opus`, so the ONLY
# channel able to award FULL was dispatching a SAME-FAMILY reviewer (the main session is
# Claude). Meanwhile pi/opencode, which are explicitly configured with a heterogeneous
# model, could only ever get EVIDENCE_ONLY. The grading was inverted.
#
# What it means now: the dispatch layer recorded a reviewer whose model family PROVABLY
# differs from the implementer's. This is deliberately not a claim that the review text
# came from that model — nothing at this layer can prove that, and the old FULL did not
# either.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_LIB="$SCRIPT_DIR/../lib/hetero/dispatch.sh"
CONFIG_LIB="$SCRIPT_DIR/../lib/hetero/config.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

# fail-safe at file scope: no test may reach a real CLI.
export HETERO_BIN_CODEX=/nonexistent-codex
export HETERO_BIN_CODEBUDDY=/nonexistent-codebuddy

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

source_dispatch() {
  _HETERO_CONFIG_SOURCED=""; _HETERO_DISPATCH_SOURCED=""; _OC_SERVE_SOURCED=""
  _HETERO_FAMILY_SOURCED=""; _HETERO_FAMILY_CACHE=""
  HETERO_LOCK_DIR=$(mktemp -d); export HETERO_LOCK_DIR
  # Isolate from the machine's real hetero-check.json. These cases assert on channel
  # selection and capability, and BOTH are configurable — so without isolation the results
  # depend on whatever the user happens to have configured. Observed 2026-08-24: a real
  # config carrying implementer_family + channels.paseo.enabled=false flipped seven
  # assertions at once, which reads like a code regression and is not one.
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  unset HETERO_IMPLEMENTER_FAMILY HETERO_PI_MODEL HETERO_PASEO_MODEL \
        HETERO_CHAN_PASEO HETERO_CHAN_PI HETERO_CHAN_OPENCODE
  source "$CONFIG_LIB"; source "$DISPATCH_LIB"
}
setup_repo() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  echo x > a.txt; git add a.txt; git commit -q -m init
}
teardown_repo() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; }

mkfakes() {
  FAKE_DIR=$(mktemp -d)
  printf '#!/usr/bin/env bash\necho "body VERDICT: PASS"\nexit 0\n' > "$FAKE_DIR/pi"
  printf '#!/usr/bin/env bash\necho agent-id-123\nexit 0\n'          > "$FAKE_DIR/paseo"
  chmod +x "$FAKE_DIR/pi" "$FAKE_DIR/paseo"
  export PATH="$FAKE_DIR:$PATH"
}

cap() { echo "${HETERO_DISPATCH_CAPABILITY:-}"; }

echo "=== hetero capability tests ==="
echo

echo "C1: pi 派 deepseek + 实施族 anthropic → FULL"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_BIN_PASEO=/nonexistent-paseo
  export HETERO_PI_MODEL="volcengine-coding/deepseek-v4-flash"
  export HETERO_IMPLEMENTER_FAMILY="anthropic"
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "channel=pi capability=FULL (实际 ${HETERO_DISPATCH_CHANNEL:-}/$(cap))" \
    "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == pi && "$(cap)" == FULL ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

echo "C2: pi 派同族（claude）+ 实施族 anthropic → EVIDENCE_ONLY"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_BIN_PASEO=/nonexistent-paseo
  export HETERO_PI_MODEL="github-copilot/claude-sonnet-4.6"
  export HETERO_IMPLEMENTER_FAMILY="anthropic"
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "同族 → EVIDENCE_ONLY (实际 $(cap))" "$([[ "$(cap)" == EVIDENCE_ONLY ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

echo "C3: 未声明实施族 → EVIDENCE_ONLY（fail-closed，无法证明异构）"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_BIN_PASEO=/nonexistent-paseo
  export HETERO_PI_MODEL="volcengine-coding/deepseek-v4-flash"
  unset HETERO_IMPLEMENTER_FAMILY
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "未声明 → EVIDENCE_ONLY (实际 $(cap))" "$([[ "$(cap)" == EVIDENCE_ONLY ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

echo "C4: 实施族无法解析 → EVIDENCE_ONLY"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_BIN_PASEO=/nonexistent-paseo
  export HETERO_PI_MODEL="volcengine-coding/deepseek-v4-flash"
  export HETERO_IMPLEMENTER_FAMILY="some-unknown-vendor-x"
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "unknown → EVIDENCE_ONLY (实际 $(cap))" "$([[ "$(cap)" == EVIDENCE_ONLY ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

echo "C5: ⭐ paseo 默认派 claude/opus + 实施族 anthropic → EVIDENCE_ONLY（旧行为错给 FULL）"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_IMPLEMENTER_FAMILY="anthropic"
  unset HETERO_PASEO_MODEL
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "channel=paseo (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == paseo ]] && echo true || echo false)"
  assert "同族自审不再给 FULL (实际 $(cap))" "$([[ "$(cap)" == EVIDENCE_ONLY ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

# C6 previously asserted that configuring a heterogeneous model for the paseo channel
# earned FULL. Overturned 2026-08-24: hetero_spawn_pg reports only whether the SPAWN
# succeeded, and this channel is fire-and-forget — at that moment nothing knows whether an
# agent was created. Measured twice with the same binary and got opposite outcomes
# (`hetero_dispatch reviewer` produced no agent in `paseo agent ls`; a hand-run spawn did).
# Grading FULL on an unverified spawn is the "receipt for an agent that never existed"
# that dispatch.sh's own comment warns about.
echo "C6: ⛔ paseo 通道即使配了异构模型也不得给 FULL（spawn 成功 ≠ agent 存在）"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_IMPLEMENTER_FAMILY="anthropic"
  export HETERO_PASEO_MODEL="opencode/volcengine-coding/deepseek-v4-flash"
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "channel=paseo (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == paseo ]] && echo true || echo false)"
  assert "未核实的 spawn 不给 FULL (实际 $(cap))" "$([[ "$(cap)" == EVIDENCE_ONLY ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

echo "C6b: 对比——pi 通道同样条件下仍可拿 FULL（限制只针对无法核实的 paseo）"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_BIN_PASEO=/nonexistent-paseo
  export HETERO_IMPLEMENTER_FAMILY="anthropic"
  export HETERO_PI_MODEL="volcengine-coding/deepseek-v4-flash"
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "pi 仍给 FULL (实际 ${HETERO_DISPATCH_CHANNEL:-}/$(cap))" \
    "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == pi && "$(cap)" == FULL ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

echo "C7: 未声明实施族时必须明确提示（否则 agent 不知道少了什么）"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_BIN_PASEO=/nonexistent-paseo
  export HETERO_PI_MODEL="volcengine-coding/deepseek-v4-flash"
  unset HETERO_IMPLEMENTER_FAMILY
  hetero_dispatch reviewer "p" 0 2>"$FAKE_DIR/err.txt" >/dev/null
  err=$(cat "$FAKE_DIR/err.txt" 2>/dev/null)
  assert "stderr 提到 HETERO_IMPLEMENTER_FAMILY" "$([[ "$err" == *HETERO_IMPLEMENTER_FAMILY* ]] && echo true || echo false)"
  assert "stderr 说明异构才是要求（不是某个具体模型）" "$([[ "$err" == *heterogene* || "$err" == *异构* ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

# C8: the implementer family must be configurable, not env-only. Requiring every agent to
# export it by hand is how it ends up unset — and unset means EVIDENCE_ONLY for every
# high-risk path, i.e. an ack every time.
echo "C8: implementer_family 可从配置文件读（不必每个 agent 自己 export）"
(
  setup_repo; source_dispatch; mkfakes
  GD=$(mktemp -d); export AGENT_GATES_DIR="$GD"
  cat > "$GD/hetero-check.json" <<'JSON'
{ "implementer_family": "anthropic",
  "pi_models": { "primary": "volcengine-coding/deepseek-v4-flash" } }
JSON
  _HETERO_CONFIG_SOURCED=""; _HETERO_FAMILY_CACHE=""
  unset HETERO_IMPLEMENTER_FAMILY HETERO_PI_MODEL
  source "$CONFIG_LIB"; hetero_load_config
  assert "HETERO_IMPLEMENTER_FAMILY 从配置读到 (实际 '${HETERO_IMPLEMENTER_FAMILY:-}')" \
    "$([[ "${HETERO_IMPLEMENTER_FAMILY:-}" == anthropic ]] && echo true || echo false)"
  assert "HETERO_PI_MODEL 从配置读到 (实际 '${HETERO_PI_MODEL:-}')" \
    "$([[ "${HETERO_PI_MODEL:-}" == volcengine-coding/deepseek-v4-flash ]] && echo true || echo false)"
  export HETERO_BIN_PASEO=/nonexistent-paseo
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "仅靠配置即可拿到 FULL (实际 $(cap))" "$([[ "$(cap)" == FULL ]] && echo true || echo false)"
  rm -rf "$GD" "$FAKE_DIR" "$HETERO_LOCK_DIR"; unset AGENT_GATES_DIR; teardown_repo
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]

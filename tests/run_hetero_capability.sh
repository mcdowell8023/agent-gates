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
  _HETERO_FAMILY_SOURCED=""
  HETERO_LOCK_DIR=$(mktemp -d); export HETERO_LOCK_DIR
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

echo "C6: paseo 配异构模型 + 实施族 anthropic → FULL"
(
  setup_repo; source_dispatch; mkfakes
  export HETERO_IMPLEMENTER_FAMILY="anthropic"
  export HETERO_PASEO_MODEL="opencode/volcengine-coding/deepseek-v4-flash"
  hetero_dispatch reviewer "p" 0 2>/dev/null
  assert "配异构后给 FULL (实际 $(cap))" "$([[ "$(cap)" == FULL ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$HETERO_LOCK_DIR"; teardown_repo
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]

#!/usr/bin/env bash
# Tests for bin/agent-gates-review — capability-aware review router.
# v1.10.1: fake opencode outputs REAL JSON format (not plain text) to catch P1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_CMD="$SCRIPT_DIR/../bin/agent-gates-review"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Fake opencode that outputs REAL --format json structure (not plain text!).
# This is the §9.2 fix: synthetic fixtures must match real tool output format.
make_fake_opencode() {
  local mode="$1"
  FAKE_DIR=$(mktemp -d)
  cat > "$FAKE_DIR/opencode" <<'FAKE'
#!/usr/bin/env bash
# Simulate real opencode --format json output (JSON lines, not plain text)
case "$1" in
  --timeout-forever) sleep 999; exit 1 ;;
esac
MODE_FILE="${FAKE_MODE:-ok}"
case "$MODE_FILE" in
  ok)
    echo '{"type":"step_start","part":{"type":"step-start"}}'
    echo '{"type":"text","part":{"type":"text","text":"VERDICT: PASS\nNo issues found."}}'
    echo '{"type":"step_finish","part":{"type":"step-finish"}}'
    exit 0 ;;
  plan_not_conclusion)
    echo '{"type":"text","part":{"type":"text","text":"I will now review this by dispatching sub-agents..."}}'
    exit 0 ;;
  mutate_staged)
    printf '// changed during review\n' >> src.ts
    git add src.ts
    echo '{"type":"text","part":{"type":"text","text":"VERDICT: PASS\nNo issues found."}}'
    exit 0 ;;
  empty) echo ""; exit 0 ;;
  fail)  echo "error" >&2; exit 1 ;;
esac
FAKE
  chmod +x "$FAKE_DIR/opencode"
}

# Fake codex
make_fake_codex() {
  local mode="$1"
  FAKE_DIR_CODEX=$(mktemp -d)
  cat > "$FAKE_DIR_CODEX/codex" <<FAKE
#!/usr/bin/env bash
case "$mode" in
  ok)   echo "CODEX REVIEW: PASS"; exit 0 ;;
  mutate_staged)
    printf '// changed during review\\n' >> src.ts
    git add src.ts
    echo "CODEX REVIEW: PASS"
    exit 0 ;;
  fail) exit 1 ;;
esac
FAKE
  chmod +x "$FAKE_DIR_CODEX/codex"
}

# Fake review-capability.json
make_cap() {
  local level="$1" preferred="$2" fallback="${3:-agent-tool}"
  CAP_DIR=$(mktemp -d)
  cat > "$CAP_DIR/review-capability.json" <<CAP
{
  "level": "$level",
  "preferred_route": "$preferred",
  "fallback_route": "$fallback"
}
CAP
}

echo "=== agent-gates-review tests (v1.10.1) ==="
echo ""

# --- P1 fix: opencode JSON parsing ---

# T1: L3 → opencode outputs JSON, review extracts plain text (P1 fix)
test_l3_opencode_json_parsed() {
  echo "T1: L3 → opencode JSON parsed to plain text (P1 fix)"
  make_cap "L3" "opencode" "codex"
  make_fake_opencode ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" FAKE_MODE=ok \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  # P1 core: output must contain VERDICT as plain text (not buried in JSON)
  assert "VERDICT in plain text (not JSON)" "$(echo "$out" | grep -q '^VERDICT: PASS' && echo true || echo false)"
  # Must NOT contain raw JSON structure
  assert "no raw JSON in output" "$(echo "$out" | grep -q '"type":"text"' && echo false || echo true)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE"
}

# T2: L3 → opencode fails → fallback to codex
test_l3_fallback_codex() {
  echo "T2: L3 → opencode fail → codex fallback"
  make_cap "L3" "opencode" "codex"
  make_fake_opencode empty
  make_fake_codex ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" FAKE_MODE=empty \
    OC_REVIEW_RETRIES=0 AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (codex succeeded)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "codex output" "$(echo "$out" | grep -q 'CODEX REVIEW: PASS' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

# T3: L1 → routes to codex directly
test_l1_codex() {
  echo "T3: L1 → codex direct"
  make_cap "L1" "codex" "agent-tool"
  make_fake_codex ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "codex output" "$(echo "$out" | grep -q 'CODEX REVIEW: PASS' && echo true || echo false)"
  rm -rf "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

# T4: L0 → exit 78 + warning
test_l0_degraded() {
  echo "T4: L0 → exit 78 (degraded)"
  make_cap "L0" "agent-tool" "agent-tool"
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  assert "exit 78" "$([[ $rc -eq 78 ]] && echo true || echo false)"
  assert "warns L0" "$(echo "$out" | grep -qi 'L0\|same.model\|degrad' && echo true || echo false)"
  rm -rf "$CAP_DIR" "$PROMPT_FILE"
}

# T5: no review-capability.json → exit 69
test_no_capability() {
  echo "T5: no capability file → exit 69"
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="/nonexistent" bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  assert "exit 69" "$([[ $rc -eq 69 ]] && echo true || echo false)"
  rm -f "$PROMPT_FILE"
}

# T6: --result writes to file
test_result_file() {
  echo "T6: --result writes to file"
  make_cap "L2" "opencode" "agent-tool"
  make_fake_opencode ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" FAKE_MODE=ok \
    bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>/dev/null
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "result file has plain VERDICT" "$(grep -q '^VERDICT: PASS' "$RESULT_FILE" && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$RESULT_FILE"
}

# T7: all 3 markers present with correct values
test_review_tool_marker() {
  echo "T7: REVIEW_TOOL/MODEL/LEVEL markers"
  make_cap "L2" "opencode" "agent-tool"
  make_fake_opencode ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" FAKE_MODE=ok \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  assert "REVIEW_TOOL: opencode" "$(echo "$out" | grep -q 'REVIEW_TOOL: opencode' && echo true || echo false)"
  assert "REVIEW_MODEL present" "$(echo "$out" | grep -q 'REVIEW_MODEL:' && echo true || echo false)"
  assert "REVIEW_LEVEL: L2" "$(echo "$out" | grep -q 'REVIEW_LEVEL: L2' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE"
}

# T8: codex receives prompt via stdin
test_codex_stdin() {
  echo "T8: codex receives prompt via stdin"
  make_cap "L1" "codex" "agent-tool"
  FAKE_DIR_CODEX=$(mktemp -d)
  cat > "$FAKE_DIR_CODEX/codex" <<'FAKE'
#!/usr/bin/env bash
echo "GOT STDIN: $(cat)"
exit 0
FAKE
  chmod +x "$FAKE_DIR_CODEX/codex"
  PROMPT_FILE=$(mktemp); echo "my review prompt" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  assert "codex got prompt via stdin" "$(echo "$out" | grep -q 'GOT STDIN: my review prompt' && echo true || echo false)"
  assert "REVIEW_TOOL: codex" "$(echo "$out" | grep -q 'REVIEW_TOOL: codex' && echo true || echo false)"
  rm -rf "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

# --- v1.10.1 NEW: prompt length gate ---

# T9: prompt >800 chars on L3 → skip opencode, go codex
test_long_prompt_l3_skip_opencode() {
  echo "T9: prompt >800 chars L3 → skip opencode, use codex"
  make_cap "L3" "opencode" "codex"
  make_fake_opencode ok
  make_fake_codex ok
  PROMPT_FILE=$(mktemp)
  python3 -c "print('x' * 900)" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" FAKE_MODE=ok \
    AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "routed to codex (not opencode)" "$(echo "$out" | grep -q 'REVIEW_TOOL: codex' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

# T10: prompt >800 chars on L2 (opencode only) → exit 76 + error
test_long_prompt_l2_reject() {
  echo "T10: prompt >800 chars L2 → reject (no codex fallback)"
  make_cap "L2" "opencode" "agent-tool"
  PROMPT_FILE=$(mktemp)
  python3 -c "print('x' * 900)" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  assert "exit 76 (prompt too long)" "$([[ $rc -eq 76 ]] && echo true || echo false)"
  assert "warns prompt too long" "$(echo "$out" | grep -qi 'too long\|过长\|800' && echo true || echo false)"
  rm -rf "$CAP_DIR" "$PROMPT_FILE"
}

# T11: prompt ≤800 chars → normal opencode path
test_short_prompt_ok() {
  echo "T11: prompt ≤800 chars → normal opencode"
  make_cap "L2" "opencode" "agent-tool"
  make_fake_opencode ok
  PROMPT_FILE=$(mktemp); echo "short review prompt" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" FAKE_MODE=ok \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "REVIEW_TOOL: opencode" "$(echo "$out" | grep -q 'REVIEW_TOOL: opencode' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE"
}

# --- v1.10.1 NEW: invalid output detection (failure mode B) ---

# T12: opencode outputs "plan not conclusion" → fallback
test_invalid_output_fallback() {
  echo "T12: opencode outputs plan-not-conclusion → fallback codex"
  make_cap "L3" "opencode" "codex"
  make_fake_opencode ok
  make_fake_codex ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" FAKE_MODE=plan_not_conclusion \
    AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (fell back to codex)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "codex output (not opencode plan)" "$(echo "$out" | grep -q 'CODEX REVIEW: PASS' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

# T13: L1 + preferred_route=omc-codex-plugin → should NOT just fail (P2 fix)
test_l1_omc_plugin() {
  echo "T13: L1 omc-codex-plugin → exit 78 with guidance (not silent 75)"
  make_cap "L1" "omc-codex-plugin" "agent-tool"
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  # No codex binary available — omc-codex-plugin is an agent-based route, not CLI.
  # agent-gates-review can't drive it directly → should exit 78 with clear guidance,
  # not silently fail with 75 pretending codex was tried.
  out=$(AGENT_GATES_DIR="$CAP_DIR" AG_REVIEW_CODEX="/nonexistent/codex" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  assert "exit 78 (omc-plugin is agent-based, not CLI-drivable)" "$([[ $rc -eq 78 ]] && echo true || echo false)"
  assert "mentions omc or plugin" "$(echo "$out" | grep -qiE 'omc|plugin|agent.based' && echo true || echo false)"
  rm -rf "$CAP_DIR" "$PROMPT_FILE"
}

# T14: L1 + preferred_route=codex (real codex CLI) → still works
test_l1_codex_preferred() {
  echo "T14: L1 preferred=codex → codex direct (unchanged)"
  make_cap "L1" "codex" "agent-tool"
  make_fake_codex ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "codex output" "$(echo "$out" | grep -q 'CODEX REVIEW: PASS' && echo true || echo false)"
  rm -rf "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

# --- v2.0.1: staged-content review anchors ---

setup_staged_review_repo() {
  REVIEW_REPO=$(mktemp -d)
  git -C "$REVIEW_REPO" init -q
  git -C "$REVIEW_REPO" config user.email test@test.com
  git -C "$REVIEW_REPO" config user.name Test
  printf 'export const value = 1\n' > "$REVIEW_REPO/src.ts"
  printf 'test value\n' > "$REVIEW_REPO/src.test.ts"
  git -C "$REVIEW_REPO" add src.ts src.test.ts
  git -C "$REVIEW_REPO" commit -q -m init
  printf 'export const value = 2\n' > "$REVIEW_REPO/src.ts"
  printf 'test changed value\n' > "$REVIEW_REPO/src.test.ts"
  git -C "$REVIEW_REPO" add src.ts src.test.ts
}

test_staged_review_emits_content_anchors() {
  echo "T-ANCHOR1: staged review emits HEAD/file/diff anchors"
  setup_staged_review_repo
  make_cap "L1" "codex" "agent-tool"
  make_fake_codex ok
  PROMPT_FILE=$(mktemp); echo "review staged change" > "$PROMPT_FILE"
  out=$(
    cd "$REVIEW_REPO" || exit 1
    AGENT_GATES_DIR="$CAP_DIR" AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
      bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null
  )
  rc=$?
  expected_head=$(git -C "$REVIEW_REPO" rev-parse HEAD)
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "REVIEW_HEAD matches HEAD" "$(echo "$out" | grep -q "REVIEW_HEAD: $expected_head" && echo true || echo false)"
  assert "REVIEW_FILE includes source" "$(echo "$out" | grep -q 'REVIEW_FILE: src.ts' && echo true || echo false)"
  assert "REVIEW_FILE includes test" "$(echo "$out" | grep -q 'REVIEW_FILE: src.test.ts' && echo true || echo false)"
  assert "REVIEW_FILES_SHA256 present" "$(echo "$out" | grep -qE 'REVIEW_FILES_SHA256: [0-9a-f]{64}' && echo true || echo false)"
  assert "REVIEW_DIFF_SHA256 present" "$(echo "$out" | grep -qE 'REVIEW_DIFF_SHA256: [0-9a-f]{64}' && echo true || echo false)"
  rm -rf "$REVIEW_REPO" "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

test_staged_change_during_review_is_rejected() {
  echo "T-ANCHOR2: staged change during review rejects evidence"
  setup_staged_review_repo
  make_cap "L1" "codex" "agent-tool"
  make_fake_codex mutate_staged
  PROMPT_FILE=$(mktemp); echo "review staged change" > "$PROMPT_FILE"
  out=$(
    cd "$REVIEW_REPO" || exit 1
    AGENT_GATES_DIR="$CAP_DIR" AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
      bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1
  )
  rc=$?
  assert "exits non-zero when staged content changes" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "no usable REVIEW_HEAD emitted" "$(echo "$out" | grep -q 'REVIEW_HEAD:' && echo false || echo true)"
  rm -rf "$REVIEW_REPO" "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

if [[ "${RUN_ANCHOR_TESTS_ONLY:-0}" == "1" ]]; then
  test_staged_review_emits_content_anchors
  test_staged_change_during_review_is_rejected
  echo ""
  read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
  echo "$PASS pass · $FAIL fail"
  [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
fi

test_l3_opencode_json_parsed
test_l3_fallback_codex
test_l1_codex
test_l0_degraded
test_no_capability
test_result_file
test_review_tool_marker
test_codex_stdin
test_long_prompt_l3_skip_opencode
test_long_prompt_l2_reject
test_short_prompt_ok
test_invalid_output_fallback
test_l1_omc_plugin
test_l1_codex_preferred
test_staged_review_emits_content_anchors
test_staged_change_during_review_is_rejected

# ============================================================
# v1.12.0: review model selection integration tests
# When review-capability.json contains "review_models" segment,
# bin/agent-gates-review uses lib/review-selection.sh fallback chain
# instead of old L0-L3 routing.
# ============================================================
echo ""
echo "--- v1.12.0: review model selection integration ---"

# Helper: create review-capability.json with review_models segment
make_cap_v2() {
  local coding_vendor="$1" primary="$2" panel_pool="$3" panel_mode="${4:-auto}"
  CAP_DIR=$(mktemp -d)
  cat > "$CAP_DIR/review-capability.json" <<CAP
{
  "level": "L3",
  "preferred_route": "opencode",
  "fallback_route": "codex",
  "review_models": {
    "coding_vendor": "$coding_vendor",
    "primary": "$primary",
    "panel_pool": [$panel_pool],
    "panel_active": 2,
    "panel_mode": "$panel_mode"
  }
}
CAP
}

# Model-aware fake opencode that checks --pure flag and responds per model.
# Models starting with "ok/" succeed; models starting with "fail/" fail.
make_fake_opencode_v2() {
  FAKE_DIR=$(mktemp -d)
  cat > "$FAKE_DIR/opencode" <<'FAKE'
#!/usr/bin/env bash
# v1.12.0 model-aware fake opencode
# Checks --pure flag; responds based on model name prefix.
HAS_PURE=false
MODEL=""
for arg in "$@"; do
  case "$arg" in
    --pure) HAS_PURE=true ;;
  esac
done
# Parse -m <model>
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m) MODEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Record what was called (for assertion)
echo "CALLED_MODEL=$MODEL PURE=$HAS_PURE" >> "${FAKE_CALL_LOG:-/dev/null}"

# Models prefixed "ok/" succeed with valid review output
if [[ "$MODEL" == ok/* ]]; then
  echo '{"type":"text","part":{"type":"text","text":"VERDICT: PASS\nReview by '"$MODEL"'."}}'
  exit 0
fi
# Models prefixed "fail/" fail
if [[ "$MODEL" == fail/* ]]; then
  exit 1
fi
# Default: check FAKE_MODE env (backward compat with existing tests)
case "${FAKE_MODE:-ok}" in
  ok)
    echo '{"type":"step_start","part":{"type":"step-start"}}'
    echo '{"type":"text","part":{"type":"text","text":"VERDICT: PASS\nNo issues found."}}'
    echo '{"type":"step_finish","part":{"type":"step-finish"}}'
    exit 0 ;;
  fail) exit 1 ;;
esac
FAKE
  chmod +x "$FAKE_DIR/opencode"
}

# T15: review_models present → new selection path (not old L0-L3)
test_v2_new_routing_path() {
  echo "T15: review_models present → uses new selection fallback chain"
  make_cap_v2 "claude" "ok/gpt-5.5" '"ok/gemini-pro","ok/deepseek-pro"'
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  FAKE_CALL_LOG=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    FAKE_CALL_LOG="$FAKE_CALL_LOG" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (new path succeeded)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  # Must use the primary from review_models, not the default AG_REVIEW_MODEL
  assert "used primary from review_models (ok/gpt-5.5)" "$(grep -q 'CALLED_MODEL=ok/gpt-5.5' "$FAKE_CALL_LOG" && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$FAKE_CALL_LOG"
}

# T16: no review_models → backward compat (original L0-L3 routing)
test_v2_backward_compat() {
  echo "T16: no review_models → original L0-L3 routing (backward compat)"
  make_cap "L3" "opencode" "codex"
  make_fake_opencode ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" FAKE_MODE=ok \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (old path still works)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "VERDICT present" "$(echo "$out" | grep -q 'VERDICT: PASS' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE"
}

# T17: primary fails → panel model used via fallback chain
test_v2_fallback_to_panel() {
  echo "T17: primary fails → panel[0] used via fallback chain"
  make_cap_v2 "claude" "fail/gpt-5.5" '"ok/gemini-pro","ok/deepseek-pro"'
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp)
  python3 -c "print('x' * 600)" > "$PROMPT_FILE"
  FAKE_CALL_LOG=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    FAKE_CALL_LOG="$FAKE_CALL_LOG" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (panel fallback succeeded)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "panel model was tried" "$(grep -q 'CALLED_MODEL=ok/gemini-pro' "$FAKE_CALL_LOG" && echo true || echo false)"
  assert "marker shows panel model (not primary)" "$(echo "$out" | grep -q 'ok/gemini-pro' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$FAKE_CALL_LOG"
}

# T18: all models fail → HETERO_EXHAUSTED marker written
test_v2_hetero_exhausted() {
  echo "T18: all models fail → HETERO_EXHAUSTED marker"
  make_cap_v2 "claude" "fail/gpt-5.5" '"fail/gemini-pro","fail/deepseek-pro"'
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>&1)
  rc=$?
  # Should still exit non-zero (75 = tool failed) or write HETERO_EXHAUSTED
  # The HETERO_EXHAUSTED marker must appear in the result file or stderr
  local has_marker=false
  if [[ -f "$RESULT_FILE" ]] && grep -q 'HETERO_EXHAUSTED' "$RESULT_FILE"; then
    has_marker=true
  elif echo "$out" | grep -q 'HETERO_EXHAUSTED'; then
    has_marker=true
  fi
  assert "HETERO_EXHAUSTED marker present" "$has_marker"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$RESULT_FILE"
}

# T19: --pure flag passed to opencode (bypasses OMO orchestration)
test_v2_pure_flag() {
  echo "T19: --pure flag passed in new selection path"
  make_cap_v2 "claude" "ok/gpt-5.5" '"ok/gemini-pro"'
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  FAKE_CALL_LOG=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    FAKE_CALL_LOG="$FAKE_CALL_LOG" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  assert "--pure was passed" "$(grep -q 'PURE=true' "$FAKE_CALL_LOG" && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$FAKE_CALL_LOG"
}

# T20: panel_mode=off → only primary tried, no panel
test_v2_panel_mode_off() {
  echo "T20: panel_mode=off → only primary, no panel models tried"
  make_cap_v2 "claude" "fail/gpt-5.5" '"ok/gemini-pro","ok/deepseek-pro"' "off"
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  FAKE_CALL_LOG=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    FAKE_CALL_LOG="$FAKE_CALL_LOG" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  # Primary fails and panel_mode=off → should NOT try panel models
  assert "panel models NOT tried" "$(grep -q 'gemini-pro\|deepseek-pro' "$FAKE_CALL_LOG" && echo false || echo true)"
  # Should fail since primary failed and no panel fallback
  assert "exits non-zero (no panel fallback)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$FAKE_CALL_LOG"
}

# T21: panel_mode=always → panel tried even for trivial severity
test_v2_panel_mode_always() {
  echo "T21: panel_mode=always → panel models tried regardless of severity"
  make_cap_v2 "claude" "ok/gpt-5.5" '"ok/gemini-pro","ok/deepseek-pro"' "always"
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp); echo "short" > "$PROMPT_FILE"
  FAKE_CALL_LOG=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    FAKE_CALL_LOG="$FAKE_CALL_LOG" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  # Even though this is a trivial/short prompt, panel_mode=always means panel should be tried
  # (or at least the routing should pass panel models to fallback chain)
  # The primary succeeds so panel may not be called, but the models should be available
  # For this test: primary succeeds → just verify new path was taken (not old routing)
  assert "used new selection path" "$(grep -q 'CALLED_MODEL=ok/gpt-5.5' "$FAKE_CALL_LOG" && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$FAKE_CALL_LOG"
}

# T22: empty primary → should exit non-zero, not crash
test_v2_empty_primary() {
  echo "T22: empty/missing primary → graceful failure"
  make_cap_v2 "claude" "" '"ok/gemini-pro"'
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  assert "exits non-zero (no valid primary)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE"
}

# T23: T21 enhanced — panel_mode=always, primary fails → panel actually tried
test_v2_panel_mode_always_panel_engaged() {
  echo "T23: panel_mode=always, primary fails → panel model actually used"
  make_cap_v2 "claude" "fail/gpt-5.5" '"ok/gemini-pro","ok/deepseek-pro"' "always"
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  FAKE_CALL_LOG=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    FAKE_CALL_LOG="$FAKE_CALL_LOG" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (panel fallback succeeded)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "panel model gemini-pro was tried" "$(grep -q 'CALLED_MODEL=ok/gemini-pro' "$FAKE_CALL_LOG" && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$FAKE_CALL_LOG"
}

# T24: panel_mode=auto, short prompt → panel NOT tried (severity=trivial)
test_v2_panel_mode_auto_short_prompt() {
  echo "T24: panel_mode=auto, short prompt → only primary (no panel for trivial)"
  make_cap_v2 "claude" "fail/gpt-5.5" '"ok/gemini-pro","ok/deepseek-pro"' "auto"
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp); echo "short" > "$PROMPT_FILE"
  FAKE_CALL_LOG=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    FAKE_CALL_LOG="$FAKE_CALL_LOG" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  assert "panel NOT tried (short prompt)" "$(grep -q 'gemini-pro\|deepseek-pro' "$FAKE_CALL_LOG" && echo false || echo true)"
  assert "exits non-zero (primary failed, no panel)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$FAKE_CALL_LOG"
}

# T25: panel_mode=auto, long prompt → panel tried (severity=important)
test_v2_panel_mode_auto_long_prompt() {
  echo "T25: panel_mode=auto, long prompt → panel models tried"
  make_cap_v2 "claude" "fail/gpt-5.5" '"ok/gemini-pro","ok/deepseek-pro"' "auto"
  make_fake_opencode_v2
  PROMPT_FILE=$(mktemp)
  python3 -c "print('x' * 600)" > "$PROMPT_FILE"
  FAKE_CALL_LOG=$(mktemp)
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    FAKE_CALL_LOG="$FAKE_CALL_LOG" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (panel fallback succeeded)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "panel model was tried" "$(grep -q 'CALLED_MODEL=ok/gemini-pro' "$FAKE_CALL_LOG" && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$FAKE_CALL_LOG"
}

test_v2_new_routing_path
test_v2_backward_compat
test_v2_fallback_to_panel
test_v2_hetero_exhausted
test_v2_pure_flag
test_v2_panel_mode_off
test_v2_panel_mode_always
test_v2_empty_primary
test_v2_panel_mode_always_panel_engaged
test_v2_panel_mode_auto_short_prompt
test_v2_panel_mode_auto_long_prompt

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

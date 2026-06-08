#!/usr/bin/env bash
# Tests for bin/agent-gates-review — capability-aware review router.
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

# Fake opencode that echoes args + controlled exit
make_fake_opencode() {
  local mode="$1"
  FAKE_DIR=$(mktemp -d)
  cat > "$FAKE_DIR/opencode" <<FAKE
#!/usr/bin/env bash
case "$mode" in
  ok)    echo "REVIEW: PASS"; exit 0 ;;
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

echo "=== agent-gates-review tests ==="
echo ""

# T1: L3 → routes to opencode (oc-review), success
test_l3_opencode_ok() {
  echo "T1: L3 → opencode success"
  make_cap "L3" "opencode" "codex"
  make_fake_opencode ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "opencode output" "$(echo "$out" | grep -q 'REVIEW: PASS' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE"
}

# T2: L3 → opencode fails → fallback to codex
test_l3_fallback_codex() {
  echo "T2: L3 → opencode fail → codex fallback"
  make_cap "L3" "opencode" "codex"
  make_fake_opencode empty
  make_fake_codex ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    OC_REVIEW_RETRIES=0 AG_REVIEW_CODEX="$FAKE_DIR_CODEX/codex" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (codex succeeded)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "codex output" "$(echo "$out" | grep -q 'CODEX REVIEW: PASS' && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$FAKE_DIR_CODEX" "$CAP_DIR" "$PROMPT_FILE"
}

# T3: L1 → routes to codex directly (no opencode)
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

# T4: L0 → exit 78 + warning (same-model degraded)
test_l0_degraded() {
  echo "T4: L0 → exit 78 (degraded, same-model only)"
  make_cap "L0" "agent-tool" "agent-tool"
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  assert "exit 78" "$([[ $rc -eq 78 ]] && echo true || echo false)"
  assert "warns L0 degraded" "$(echo "$out" | grep -qi 'L0\|same.model\|degrad' && echo true || echo false)"
  rm -rf "$CAP_DIR" "$PROMPT_FILE"
}

# T5: no review-capability.json → exit 69
test_no_capability() {
  echo "T5: no review-capability.json → exit 69"
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="/nonexistent" bash "$REVIEW_CMD" "$PROMPT_FILE" 2>&1)
  rc=$?
  assert "exit 69" "$([[ $rc -eq 69 ]] && echo true || echo false)"
  rm -f "$PROMPT_FILE"
}

# T6: result file output (--result flag)
test_result_file() {
  echo "T6: --result writes to file"
  make_cap "L2" "opencode" "agent-tool"
  make_fake_opencode ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
    bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>/dev/null
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "result file has content" "$(grep -q 'REVIEW: PASS' "$RESULT_FILE" && echo true || echo false)"
  rm -rf "$FAKE_DIR" "$CAP_DIR" "$PROMPT_FILE" "$RESULT_FILE"
}

# T7: output includes all 3 markers with correct values
test_review_tool_marker() {
  echo "T7: output includes REVIEW_TOOL/MODEL/LEVEL markers"
  make_cap "L2" "opencode" "agent-tool"
  make_fake_opencode ok
  PROMPT_FILE=$(mktemp); echo "review this" > "$PROMPT_FILE"
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" \
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
# echo stdin content to prove it was received
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

test_l3_opencode_ok
test_l3_fallback_codex
test_l1_codex
test_l0_degraded
test_no_capability
test_result_file
test_review_tool_marker
test_codex_stdin

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

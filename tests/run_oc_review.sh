#!/usr/bin/env bash
# Tests for bin/oc-review — retry-on-empty wrapper around `opencode run`.
# Strategy: mock `opencode` with a fake whose behavior is driven by env, so we can
# simulate empty-output (P2) and verify oc-review retries / falls back deterministically.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC_REVIEW="$SCRIPT_DIR/../bin/oc-review"
# File-based counter: tests run in ( ) subshells for isolation, so plain vars would
# be lost. Persist counts to a file (same pattern as run_gate.sh) — otherwise the
# summary shows "0 pass · 0 fail" and exit code is a FALSE GREEN.
RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Build a fake `opencode` on PATH. Behavior controlled by FAKE_MODE:
#   always_empty  → always prints nothing (exit 0)        [the P2 failure]
#   empty_then_ok → empty on attempt 1, content after     [transient flakiness]
#   always_ok     → always prints content                 [healthy]
# Attempt count tracked in a counter file ($FAKE_COUNT).
make_fake_opencode() {
  FAKE_DIR=$(mktemp -d)
  FAKE_COUNT="$FAKE_DIR/count"
  echo 0 > "$FAKE_COUNT"
  cat > "$FAKE_DIR/opencode" <<FAKE
#!/usr/bin/env bash
# fake opencode — only handles 'run'
[[ "\${1:-}" == "run" ]] || { echo "fake: unexpected \$*" >&2; exit 2; }
n=\$(cat "$FAKE_COUNT"); n=\$((n+1)); echo \$n > "$FAKE_COUNT"
case "\${FAKE_MODE:-always_ok}" in
  always_empty) exit 0 ;;                                   # exit 0, no output (P2)
  empty_then_ok) [[ "\$n" -le 1 ]] && exit 0; echo "review body — VERDICT: PASS" ;;
  always_ok) echo "review body — VERDICT: PASS" ;;
  always_error) echo "boom" >&2; exit 1 ;;                 # non-zero exit (real error, NOT P2)
  error_with_output) echo "partial"; echo "err" >&2; exit 1 ;;  # non-zero + stdout → must NOT be success
esac
exit 0
FAKE
  chmod +x "$FAKE_DIR/opencode"
}

echo "=== oc-review retry-on-empty tests ==="
echo ""

# T1: healthy opencode → exit 0, output passed through, no retry
test_healthy_passthrough() {
  echo "T1: healthy → exit 0 + output, no retry"
  ( make_fake_opencode
    out=$(FAKE_MODE=always_ok OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" bash "$OC_REVIEW" run -m x "prompt" 2>/dev/null)
    rc=$?
    n=$(cat "$FAKE_COUNT")
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "output passed through (VERDICT: PASS)" "$(echo "$out" | grep -q 'VERDICT: PASS' && echo true || echo false)"
    assert "exactly 1 attempt (no retry)" "$([[ "$n" == "1" ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" )
}

# T2: empty then ok → retries, eventually exit 0 with content
test_empty_then_ok() {
  echo "T2: empty-then-ok → retry, exit 0 with content"
  ( make_fake_opencode
    out=$(FAKE_MODE=empty_then_ok OC_REVIEW_RETRIES=2 OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" bash "$OC_REVIEW" run -m x "prompt" 2>/dev/null)
    rc=$?
    n=$(cat "$FAKE_COUNT")
    assert "exit 0 after retry" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "got content on retry" "$(echo "$out" | grep -q 'VERDICT: PASS' && echo true || echo false)"
    assert "took 2 attempts" "$([[ "$n" == "2" ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" )
}

# T3: always empty → exhausts retries, exit 75 (EX_TEMPFAIL) for codex fallback
test_always_empty_fallback() {
  echo "T3: always-empty → exit 75 after retries (caller falls back)"
  ( make_fake_opencode
    out=$(FAKE_MODE=always_empty OC_REVIEW_RETRIES=2 OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" bash "$OC_REVIEW" run -m x "prompt" 2>/dev/null)
    rc=$?
    err=$(FAKE_MODE=always_empty OC_REVIEW_RETRIES=2 OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" bash "$OC_REVIEW" run -m x "prompt" 2>&1 >/dev/null)
    n=$(cat "$FAKE_COUNT")
    assert "exit 75 (EX_TEMPFAIL)" "$([[ $rc -eq 75 ]] && echo true || echo false)"
    assert "stderr has oc-review: prefix" "$(echo "$err" | grep -q '^oc-review:' && echo true || echo false)"
    assert "tried 1+RETRIES=3 attempts" "$([[ "$n" == "6" ]] && echo true || echo false)"   # 3 per invocation × 2 invocations
    rm -rf "$FAKE_DIR" )
}

# T4: non-zero exit → retries, exit 75 (NOT treated as success), error surfaced
test_nonzero_exit_fallback() {
  echo "T4: opencode non-zero exit → exit 75, error not swallowed"
  ( make_fake_opencode
    rc_out=$(FAKE_MODE=always_error OC_REVIEW_RETRIES=1 OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" bash "$OC_REVIEW" run -m x "p" 2>/dev/null; echo "rc=$?")
    rc=$(echo "$rc_out" | sed -n 's/.*rc=//p')
    err=$(FAKE_MODE=always_error OC_REVIEW_RETRIES=1 OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" bash "$OC_REVIEW" run -m x "p" 2>&1 >/dev/null)
    assert "exit 75 on persistent error" "$([[ "$rc" == "75" ]] && echo true || echo false)"
    assert "reports opencode exit code (not P2 empty)" "$(echo "$err" | grep -q 'opencode exited 1' && echo true || echo false)"
    assert "surfaces opencode stderr" "$(echo "$err" | grep -q 'opencode stderr: boom' && echo true || echo false)"
    rm -rf "$FAKE_DIR" )
}

# T5: non-zero exit WITH stdout → must NOT be treated as success
test_nonzero_with_output_not_success() {
  echo "T5: non-zero exit + stdout → NOT success (exit 75)"
  ( make_fake_opencode
    out=$(FAKE_MODE=error_with_output OC_REVIEW_RETRIES=0 OC_REVIEW_OPENCODE="$FAKE_DIR/opencode" bash "$OC_REVIEW" run -m x "p" 2>/dev/null)
    rc=$?
    assert "exit 75 (not 0) despite having stdout" "$([[ $rc -eq 75 ]] && echo true || echo false)"
    assert "partial stdout NOT emitted as result" "$(echo "$out" | grep -q 'partial' && echo false || echo true)"
    rm -rf "$FAKE_DIR" )
}

test_healthy_passthrough
test_empty_then_ok
test_always_empty_fallback
test_nonzero_exit_fallback
test_nonzero_with_output_not_success

echo ""
read -r PASS FAIL < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

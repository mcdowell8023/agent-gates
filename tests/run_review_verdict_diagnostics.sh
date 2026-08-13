#!/usr/bin/env bash
# Tests for review-failure diagnostics, VERDICT matching tolerance, invocation
# timeouts, and codex fallback out of the hetero branch.
#
# Why these exist (2026-08-13): `HETERO_EXHAUSTED: all review models failed` was
# emitted for three unrelated failures — model unreachable, NDJSON parsed to empty,
# and "model answered but produced no line-start VERDICT: line". The third is the
# common one, yet the message pointed at the transport, so a whole day went into
# chasing a nonexistent `opencode --format json` hang. These tests pin the three
# apart, widen the VERDICT matcher to tolerate ordinary markdown decoration, require
# every opencode invocation to carry a timeout, and require the hetero branch to
# fall back to codex instead of dead-ending at exit 75.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_CMD="$SCRIPT_DIR/../bin/agent-gates-review"
WITH_TIMEOUT="$SCRIPT_DIR/../bin/with-timeout.mjs"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Fake curl on PATH so oc_serve_health_check passes without a real serve.
# Same technique as tests/run_oc_serve.sh — keeps these tests independent of
# whatever `opencode serve` happens to be running on the developer's machine.
setup_fakes() {
  FAKE_BIN=$(mktemp -d)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/curl"
  chmod +x "$FAKE_BIN/curl"
  PATH="$FAKE_BIN:$PATH"
  export PATH
}

# Model-name-driven fake opencode emitting REAL NDJSON (as --format json does).
# The model prefix selects the output shape, so one fake covers every case.
make_fake_opencode() {
  FAKE_OC=$(mktemp -d)
  cat > "$FAKE_OC/opencode" <<'FAKE'
#!/usr/bin/env bash
MODEL=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "-m" ]] && MODEL="$arg"
  prev="$arg"
done
emit() { printf '{"type":"text","part":{"type":"text","text":"%s"}}\n' "$1"; }
case "$MODEL" in
  plain/*)     emit 'VERDICT: PASS\nno issues' ;;
  bold/*)      emit '**VERDICT: PASS**\nno issues' ;;
  heading/*)   emit '## VERDICT: PASS\nno issues' ;;
  indent/*)    emit '  VERDICT: PASS\nno issues' ;;
  bullet/*)    emit '- VERDICT: PASS\nno issues' ;;
  quote/*)     emit '> VERDICT: PASS\nno issues' ;;
  backtick/*)  emit '`VERDICT: PASS`\nno issues' ;;
  cjkcolon/*)  emit 'VERDICT：PASS\nno issues' ;;
  boldvalue/*) emit 'VERDICT: **PASS**\nno issues' ;;
  issues/*)    emit '**VERDICT: ISSUES**\none blocker' ;;
  failed/*)    emit 'VERDICT: FAILED\nbroken' ;;
  issuesfnd/*) emit 'VERDICT: ISSUES_FOUND\none blocker' ;;
  dotend/*)    emit 'VERDICT: PASS.' ;;
  passenger/*) emit 'VERDICT: PASSENGER\nnonsense value' ;;
  condpass/*)  emit 'VERDICT: PASS_WITH_ISSUES\nnot a clean pass' ;;
  dashpass/*)  emit 'VERDICT: PASS-WITH-ISSUES\nnot a clean pass' ;;
  dotpass/*)   emit 'VERDICT: PASS.WITH.ISSUES\nnot a clean pass' ;;
  wordypass/*) emit 'VERDICT: PASS WITH NOTES\nqualified, not clean' ;;
  badenum/*)   emit 'VERDICT: OK\nno issues' ;;
  nocncl/*) emit 'I analysed the diff. UNIQUEMARKER_NOCONCLUSION and nothing more.' ;;
  blank/*)  exit 0 ;;
  crash/*)   echo 'simulated opencode crash' >&2; exit 3 ;;
  hang/*)      sleep 987; exit 1 ;;   # 987 is a marker the orphan assertion greps for
  *)           emit 'VERDICT: PASS' ;;
esac
exit 0
FAKE
  chmod +x "$FAKE_OC/opencode"
}

make_fake_codex() {
  FAKE_CX=$(mktemp -d)
  cat > "$FAKE_CX/codex" <<'FAKE'
#!/usr/bin/env bash
cat > /dev/null   # consume the prompt from stdin
echo 'VERDICT: PASS'
echo 'CODEX_FALLBACK_MARKER'
exit 0
FAKE
  chmod +x "$FAKE_CX/codex"
}

# review-capability.json carrying a review_models segment → hetero branch.
make_cap() {
  local primary="$1" panel="${2:-}" panel_mode="${3:-off}"
  CAP_DIR=$(mktemp -d)
  cat > "$CAP_DIR/review-capability.json" <<CAP
{
  "level": "L3",
  "preferred_route": "opencode",
  "fallback_route": "codex",
  "review_models": {
    "coding_vendor": "claude",
    "primary": "$primary",
    "panel_pool": [$panel],
    "panel_active": 2,
    "panel_mode": "$panel_mode"
  }
}
CAP
}

cleanup_case() {
  rm -rf "${FAKE_OC:-}" "${FAKE_CX:-}" "${CAP_DIR:-}" "${PROMPT_FILE:-}" "${RESULT_FILE:-}" 2>/dev/null
}

# Run agent-gates-review against a model prefix. Sets OUT / ERRTXT / RC.
# Wrapped in with-timeout so a regression that hangs fails the test instead of
# hanging the suite (that is exactly the failure mode T-T1 guards).
review_with() {
  local model="$1"; shift
  make_fake_opencode
  make_cap "$model" "" "off"
  PROMPT_FILE=$(mktemp); echo "review this change" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  local errfile; errfile=$(mktemp)
  # Point codex at a path that does not exist. These cases assert on the opencode-side
  # diagnostics; letting the F4 codex fallback reach a real codex would make the
  # assertions depend on an external tool and drag the suite out by minutes per case.
  OUT=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_OC/opencode" \
    AG_REVIEW_CODEX="/nonexistent/codex" \
    "$@" node "$WITH_TIMEOUT" 45 bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>"$errfile")
  RC=$?
  ERRTXT=$(cat "$errfile"); rm -f "$errfile"
}

echo "=== review diagnostics / VERDICT tolerance / timeout / codex fallback ==="
echo ""

# ---------------------------------------------------------------------------
# F1 — the three failures must be told apart in the error text
# ---------------------------------------------------------------------------

test_diag_missing_verdict() {
  echo "T-D1: model answered but no VERDICT line → error names that, and quotes the output"
  review_with "nocncl/gpt-5.5"
  assert "exits non-zero" "$([[ $RC -ne 0 ]] && echo true || echo false)"
  assert "error names the missing VERDICT line" \
    "$(echo "$ERRTXT" | grep -qiE 'no .*VERDICT|VERDICT.*(missing|not found)|缺.*VERDICT' && echo true || echo false)"
  assert "error quotes what the model actually said" \
    "$(echo "$ERRTXT" | grep -q 'UNIQUEMARKER_NOCONCLUSION' && echo true || echo false)"
  assert "error does NOT claim the model was unreachable" \
    "$(echo "$ERRTXT" | grep -qiE 'unreachable|no response|binary not found' && echo false || echo true)"
  cleanup_case
}

test_diag_empty_output() {
  echo "T-D2: opencode exits 0 with empty output → error names empty output"
  review_with "blank/gpt-5.5"
  assert "exits non-zero" "$([[ $RC -ne 0 ]] && echo true || echo false)"
  assert "error names empty output" \
    "$(echo "$ERRTXT" | grep -qiE 'empty|空' && echo true || echo false)"
  assert "error does NOT blame a missing VERDICT line" \
    "$(echo "$ERRTXT" | grep -qiE 'no .*VERDICT|VERDICT.*missing' && echo false || echo true)"
  cleanup_case
}

test_diag_crash_exit() {
  echo "T-D3: opencode exits non-zero → error reports the exit code"
  review_with "crash/gpt-5.5"
  assert "exits non-zero" "$([[ $RC -ne 0 ]] && echo true || echo false)"
  assert "error reports the child exit code (3)" \
    "$(echo "$ERRTXT" | grep -qE 'exit(ed)? (code )?3\b|rc=3' && echo true || echo false)"
  cleanup_case
}

test_diag_names_the_model() {
  echo "T-D4: every failure line names which model failed"
  review_with "nocncl/gpt-5.5"
  assert "error mentions the failing model id" \
    "$(echo "$ERRTXT" | grep -q 'nocncl/gpt-5.5' && echo true || echo false)"
  cleanup_case
}

# ---------------------------------------------------------------------------
# F2 — VERDICT matching must tolerate ordinary markdown decoration
# ---------------------------------------------------------------------------

verdict_accepts() {
  local label="$1" model="$2"
  review_with "$model"
  # Exit 0 alone is weak evidence: require the review to have actually been written.
  local ok=false
  if [[ $RC -eq 0 ]] && grep -q 'REVIEW_TOOL: opencode' "$RESULT_FILE" 2>/dev/null; then
    ok=true
  fi
  assert "accepts $label" "$ok"
  cleanup_case
}

verdict_rejects() {
  local label="$1" model="$2"
  review_with "$model"
  # Asserting only on a non-zero exit would go green for any failure whatsoever — a syntax
  # error, an unbound variable under `set -u`, a timeout — and silently stop testing the
  # matcher at all. Require the specific rejection reason so a crash cannot pass itself off
  # as a correct rejection.
  local ok=false
  if [[ $RC -ne 0 ]] && printf '%s' "$ERRTXT" | grep -qiE 'produced no VERDICT line'; then
    ok=true
  fi
  assert "rejects $label (for the right reason)" "$ok"
  cleanup_case
}

test_verdict_tolerance() {
  echo "T-V: VERDICT line tolerance"
  verdict_accepts "bare line (regression guard)"      "plain/gpt-5.5"
  verdict_accepts "**bold**"                          "bold/gpt-5.5"
  verdict_accepts "## heading"                        "heading/gpt-5.5"
  verdict_accepts "leading indent"                    "indent/gpt-5.5"
  verdict_accepts "- bullet"                          "bullet/gpt-5.5"
  verdict_accepts "> blockquote"                      "quote/gpt-5.5"
  verdict_accepts "\`backticks\` (seen in the wild)"  "backtick/gpt-5.5"
  verdict_accepts "full-width colon VERDICT："         "cjkcolon/gpt-5.5"
  verdict_accepts "bold value VERDICT: **PASS**"      "boldvalue/gpt-5.5"
  verdict_accepts "decorated non-PASS verdict"        "issues/gpt-5.5"
  verdict_accepts "inflection FAILED"                 "failed/gpt-5.5"
  verdict_accepts "inflection ISSUES_FOUND"           "issuesfnd/gpt-5.5"
  verdict_accepts "trailing period"                   "dotend/gpt-5.5"
  verdict_rejects "off-enum value (VERDICT: OK)"      "badenum/gpt-5.5"
  verdict_rejects "no verdict line at all"            "nocncl/gpt-5.5"
  # Prefix matching accepts all of these; a plain word boundary still accepts the hyphen
  # and dot variants. PASSENGER is merely absurd — the qualified ones are dangerous, since
  # reporting a review that still has open concerns as a clean pass inverts the result.
  verdict_rejects "prefix collision (PASSENGER)"      "passenger/gpt-5.5"
  verdict_rejects "qualified with _ (PASS_WITH_ISSUES)"  "condpass/gpt-5.5"
  verdict_rejects "qualified with - (PASS-WITH-ISSUES)"  "dashpass/gpt-5.5"
  verdict_rejects "qualified with . (PASS.WITH.ISSUES)"  "dotpass/gpt-5.5"
  verdict_rejects "qualified with words (PASS WITH NOTES)" "wordypass/gpt-5.5"
}

# ---------------------------------------------------------------------------
# F3 — every opencode invocation must be bounded by a timeout
# ---------------------------------------------------------------------------

test_timeout_guard() {
  echo "T-T1: hung opencode + AG_REVIEW_TIMEOUT=2 → bounded failure, not a hang"
  local start elapsed
  start=$(date +%s)
  review_with "hang/gpt-5.5" env AG_REVIEW_TIMEOUT=2
  elapsed=$(( $(date +%s) - start ))
  assert "outer guard did not have to kill it (rc != 124)" \
    "$([[ $RC -ne 124 ]] && echo true || echo false)"
  assert "returned in well under the outer 45s guard (<25s)" \
    "$([[ $elapsed -lt 25 ]] && echo true || echo false)"
  assert "exits non-zero" "$([[ $RC -ne 0 ]] && echo true || echo false)"
  assert "error mentions the timeout" \
    "$(echo "$ERRTXT" | grep -qiE 'timeout|timed out|超时' && echo true || echo false)"
  # The timeout must take the whole process group with it. Killing only the direct
  # child leaves the grandchild (`sleep 987`) holding the inherited stdout, so the
  # caller's command substitution keeps blocking — a timeout that changes nothing.
  assert "no orphaned grandchild left running" \
    "$(pgrep -f 'sleep 987' >/dev/null 2>&1 && echo false || echo true)"
  cleanup_case
}

test_exhausted_reported_once() {
  echo "T-D5: HETERO_EXHAUSTED appears exactly once on both paths"
  # The panel path emits it from run_fallback_chain; the panel_mode=off path calls
  # _try_review_model directly and needs the caller to add it. Printing unconditionally
  # duplicated the line, which reads like two separate failures.
  local n

  make_fake_opencode
  make_cap "crash/gpt-5.5" '"crash/gemini"' "always"
  PROMPT_FILE=$(mktemp); echo "review this change" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  local err_panel
  err_panel=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_OC/opencode" \
    AG_REVIEW_CODEX="/nonexistent/codex" \
    node "$WITH_TIMEOUT" 45 bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>&1 >/dev/null)
  n=$(printf '%s\n' "$err_panel" | grep -c 'HETERO_EXHAUSTED')
  assert "panel path: exactly one line (got $n)" "$([[ $n -eq 1 ]] && echo true || echo false)"
  cleanup_case

  make_fake_opencode
  make_cap "crash/gpt-5.5" "" "off"
  PROMPT_FILE=$(mktemp); echo "review this change" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  local err_off
  err_off=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_OC/opencode" \
    AG_REVIEW_CODEX="/nonexistent/codex" \
    node "$WITH_TIMEOUT" 45 bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>&1 >/dev/null)
  n=$(printf '%s\n' "$err_off" | grep -c 'HETERO_EXHAUSTED')
  assert "off path: exactly one line (got $n)" "$([[ $n -eq 1 ]] && echo true || echo false)"
  cleanup_case
}

test_hetero_self_heals_serve() {
  echo "T-S1: hetero path ensures the shared serve rather than only probing it"
  # Source-level guard, not a behaviour test: oc_serve_ensure's own behaviour is covered by
  # tests/run_oc_serve.sh, and _oc_serve_start shells out to a hardcoded /usr/bin/nohup that
  # cannot be stubbed from here. What this pins is the regression that actually bit —
  # _try_review_model probing with oc_serve_health_check, so a dead shared serve made the
  # opencode channel permanently unavailable while legacy run_opencode self-healed.
  local sel="$SCRIPT_DIR/../lib/hetero/select.sh"
  local body; body=$(awk '/^_try_review_model\(\)/,/^\}/' "$sel")
  assert "calls oc_serve_ensure" \
    "$(printf '%s' "$body" | grep -q 'oc_serve_ensure' && echo true || echo false)"
  assert "does not gate solely on oc_serve_health_check" \
    "$(printf '%s' "$body" | grep -q 'if oc_serve_health_check' && echo false || echo true)"
}

test_timeout_wrapper_missing_fails_closed() {
  echo "T-T2: timeout wrapper missing → fail-closed, not a silent unbounded run"
  # Mirror the install layout minus bin/with-timeout.mjs. Dropping the guard silently
  # would restore the original hang risk while the code still claims to be bounded.
  local fake_root; fake_root=$(mktemp -d)
  mkdir -p "$fake_root/bin" "$fake_root/lib/hetero"
  cp "$SCRIPT_DIR/../bin/agent-gates-review" "$fake_root/bin/"
  cp "$SCRIPT_DIR/../lib/hetero/"*.sh "$fake_root/lib/hetero/" 2>/dev/null
  make_fake_opencode
  make_cap "plain/gpt-5.5" "" "off"
  PROMPT_FILE=$(mktemp); echo "review this change" > "$PROMPT_FILE"
  local err rc
  err=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_OC/opencode" \
    AG_REVIEW_CODEX="/nonexistent/codex" \
    node "$WITH_TIMEOUT" 45 bash "$fake_root/bin/agent-gates-review" "$PROMPT_FILE" 2>&1 >/dev/null)
  rc=$?
  assert "exits non-zero" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "error refuses to run unbounded" \
    "$(echo "$err" | grep -qiE 'unbounded|fail-closed' && echo true || echo false)"
  assert "error names the missing wrapper" \
    "$(echo "$err" | grep -q 'with-timeout.mjs' && echo true || echo false)"
  rm -rf "$fake_root"
  cleanup_case
}

# ---------------------------------------------------------------------------
# F4 — the hetero branch must fall back to codex instead of dead-ending
# ---------------------------------------------------------------------------

test_hetero_falls_back_to_codex() {
  echo "T-F1: hetero models exhausted + fallback_route=codex → codex runs"
  make_fake_opencode
  make_fake_codex
  make_cap "crash/gpt-5.5" "" "off"
  PROMPT_FILE=$(mktemp); echo "review this change" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  local out rc
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_OC/opencode" \
    AG_REVIEW_CODEX="$FAKE_CX/codex" \
    node "$WITH_TIMEOUT" 45 bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>/dev/null)
  rc=$?
  assert "exit 0 (codex caught it)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  # With --result, output_result writes the file and deliberately prints nothing to
  # stdout, so every content assertion here has to look at the file.
  assert "stdout stays empty in --result mode" "$([[ -z "$out" ]] && echo true || echo false)"
  assert "codex output landed in the result file" \
    "$(grep -q 'CODEX_FALLBACK_MARKER' "$RESULT_FILE" && echo true || echo false)"
  assert "result file is a real review, not a HETERO_EXHAUSTED stub" \
    "$(grep -q 'HETERO_EXHAUSTED' "$RESULT_FILE" && echo false || echo true)"
  assert "marker records codex as the tool" \
    "$(grep -q 'REVIEW_TOOL: codex' "$RESULT_FILE" && echo true || echo false)"
  cleanup_case
}

test_hetero_exhausted_when_no_codex() {
  echo "T-F2: hetero exhausted and codex unavailable → still exit 75 + HETERO_EXHAUSTED"
  make_fake_opencode
  make_cap "crash/gpt-5.5" "" "off"
  PROMPT_FILE=$(mktemp); echo "review this change" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  local out rc
  out=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_OC/opencode" \
    AG_REVIEW_CODEX="/nonexistent/codex" \
    node "$WITH_TIMEOUT" 45 bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>&1)
  rc=$?
  assert "exit 75" "$([[ $rc -eq 75 ]] && echo true || echo false)"
  assert "HETERO_EXHAUSTED still reported" \
    "$(echo "$out" | grep -q 'HETERO_EXHAUSTED' && echo true || echo false)"
  cleanup_case
}

test_panel_chain_diagnostics() {
  echo "T-F3: panel chain exhausted → each model's own reason is reported"
  make_fake_opencode
  make_cap "nocncl/gpt-5.5" '"blank/gemini","crash/deepseek"' "always"
  PROMPT_FILE=$(mktemp); echo "review this change" > "$PROMPT_FILE"
  RESULT_FILE=$(mktemp)
  local err rc
  err=$(AGENT_GATES_DIR="$CAP_DIR" OC_REVIEW_OPENCODE="$FAKE_OC/opencode" \
    AG_REVIEW_CODEX="/nonexistent/codex" \
    node "$WITH_TIMEOUT" 45 bash "$REVIEW_CMD" "$PROMPT_FILE" --result "$RESULT_FILE" 2>&1 >/dev/null)
  rc=$?
  assert "exits non-zero" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "primary's missing-VERDICT reason reported" \
    "$(echo "$err" | grep -qiE 'nocncl/gpt-5.5.*(VERDICT|conclusion)' && echo true || echo false)"
  assert "panel member's empty-output reason reported" \
    "$(echo "$err" | grep -qiE 'blank/gemini.*(empty|空)' && echo true || echo false)"
  cleanup_case
}

setup_fakes

test_diag_missing_verdict
test_diag_empty_output
test_diag_crash_exit
test_diag_names_the_model
test_exhausted_reported_once
test_hetero_self_heals_serve
test_verdict_tolerance
test_timeout_guard
test_timeout_wrapper_missing_fails_closed
test_hetero_falls_back_to_codex
test_hetero_exhausted_when_no_codex
test_panel_chain_diagnostics

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

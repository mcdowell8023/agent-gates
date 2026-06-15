#!/usr/bin/env bash
# Tests for v1.12.0 review model selection algorithm.
# Covers: D1 vendor inference, D1 primary selection, D2 panel pool filtering,
#         D5 auto/local merge, D4 fallback chain.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTION_LIB="$SCRIPT_DIR/../lib/review-selection.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

echo "=== review model selection tests (v1.12.0) ==="
echo ""

# ============================================================
# §1: Coding vendor inference (D1)
# ============================================================
echo "--- D1: coding vendor inference ---"

test_infer_vendor_omc() {
  echo "T1: OMC platform → coding_vendor=claude"
  source "$SELECTION_LIB"
  local vendor
  vendor=$(infer_coding_vendor "omc")
  assert "omc → claude" "$([[ "$vendor" == "claude" ]] && echo true || echo false)"
}

test_infer_vendor_omx() {
  echo "T2: OMX platform → coding_vendor=gpt"
  source "$SELECTION_LIB"
  local vendor
  vendor=$(infer_coding_vendor "omx")
  assert "omx → gpt" "$([[ "$vendor" == "gpt" ]] && echo true || echo false)"
}

test_infer_vendor_omo() {
  echo "T3: OMO platform → coding_vendor=gpt (default model)"
  source "$SELECTION_LIB"
  local vendor
  vendor=$(infer_coding_vendor "omo")
  assert "omo → gpt" "$([[ "$vendor" == "gpt" ]] && echo true || echo false)"
}

test_infer_vendor_override() {
  echo "T4: explicit override → uses override"
  source "$SELECTION_LIB"
  local vendor
  vendor=$(infer_coding_vendor "omc" "deepseek")
  assert "override deepseek" "$([[ "$vendor" == "deepseek" ]] && echo true || echo false)"
}

# ============================================================
# §2: Primary model selection — reverse heterogeneous (D1)
# ============================================================
echo ""
echo "--- D1: primary selection (reverse heterogeneous) ---"

test_select_primary_claude_coding() {
  echo "T5: coding=claude → primary=gpt model"
  source "$SELECTION_LIB"
  local primary
  primary=$(select_primary "claude")
  assert "primary is gpt" "$(echo "$primary" | grep -qi 'gpt' && echo true || echo false)"
}

test_select_primary_gpt_coding() {
  echo "T6: coding=gpt → primary=claude model"
  source "$SELECTION_LIB"
  local primary
  primary=$(select_primary "gpt")
  assert "primary is claude" "$(echo "$primary" | grep -qi 'claude' && echo true || echo false)"
}

test_select_primary_other_coding() {
  echo "T7: coding=other → primary defaults to gpt"
  source "$SELECTION_LIB"
  local primary
  primary=$(select_primary "deepseek")
  assert "primary is gpt" "$(echo "$primary" | grep -qi 'gpt' && echo true || echo false)"
}

# ============================================================
# §3: Panel pool filtering (D2 + D6)
# ============================================================
echo ""
echo "--- D2: panel pool filtering ---"

test_filter_pool_excludes_flash() {
  echo "T8: flash models excluded from pool"
  source "$SELECTION_LIB"
  local pool
  pool=$(filter_panel_pool "claude" "github-copilot/gpt-5.5" \
    "github-copilot/gemini-3.1-pro-preview" \
    "bailian/qwen3.6-flash" \
    "bailian/deepseek-v4-pro")
  assert "no flash in pool" "$(echo "$pool" | grep -q 'flash' && echo false || echo true)"
  assert "pro models kept" "$(echo "$pool" | grep -q 'deepseek-v4-pro' && echo true || echo false)"
}

test_filter_pool_excludes_claude() {
  echo "T9: claude models excluded when coding=claude"
  source "$SELECTION_LIB"
  local pool
  pool=$(filter_panel_pool "claude" "github-copilot/gpt-5.5" \
    "github-copilot/claude-sonnet-4.6" \
    "github-copilot/gemini-3.1-pro-preview")
  assert "no claude in pool" "$(echo "$pool" | grep -q 'claude' && echo false || echo true)"
  assert "gemini kept" "$(echo "$pool" | grep -q 'gemini' && echo true || echo false)"
}

test_filter_pool_dedup_same_vendor() {
  echo "T10: same vendor dedup (keep strongest)"
  source "$SELECTION_LIB"
  local pool
  pool=$(filter_panel_pool "claude" "github-copilot/gpt-5.5" \
    "bailian/qwen3.7-max" \
    "bailian/qwen3.7-plus" \
    "bailian/qwen3.6-turbo")
  local count
  count=$(echo "$pool" | grep -c 'qwen')
  assert "only 1 qwen in pool" "$([[ "$count" -le 1 ]] && echo true || echo false)"
  assert "strongest kept (max)" "$(echo "$pool" | grep -q 'qwen3.7-max' && echo true || echo false)"
}

test_filter_pool_excludes_primary_vendor() {
  echo "T11: primary vendor excluded from pool"
  source "$SELECTION_LIB"
  local pool
  pool=$(filter_panel_pool "claude" "github-copilot/gpt-5.5" \
    "github-copilot/gpt-5.4" \
    "github-copilot/gemini-3.1-pro-preview" \
    "bailian/deepseek-v4-pro")
  assert "no gpt (primary vendor) in pool" "$(echo "$pool" | grep -q 'gpt' && echo false || echo true)"
  assert "gemini kept" "$(echo "$pool" | grep -q 'gemini' && echo true || echo false)"
}

# ============================================================
# §4: Auto + local merge (D5)
# ============================================================
echo ""
echo "--- D5: auto/local merge ---"

test_merge_local_overrides_primary() {
  echo "T12: local overrides primary"
  local AUTO_DIR=$(mktemp -d)
  local LOCAL_DIR="$AUTO_DIR"
  cat > "$AUTO_DIR/review-capability.json" <<'EOF'
{
  "level": "L3",
  "review_models": {
    "coding_vendor": "claude",
    "primary": "github-copilot/gpt-5.5",
    "panel_pool": ["bailian/deepseek-v4-pro"]
  }
}
EOF
  cat > "$AUTO_DIR/review-capability.local.json" <<'EOF'
{
  "review_models": {
    "primary": "bailian/kimi-k2.6"
  }
}
EOF
  source "$SELECTION_LIB"
  local merged_primary
  merged_primary=$(merge_capability "$AUTO_DIR" | python3 -c "import json,sys; print(json.load(sys.stdin)['review_models']['primary'])")
  assert "local primary wins" "$([[ "$merged_primary" == "bailian/kimi-k2.6" ]] && echo true || echo false)"
  rm -rf "$AUTO_DIR"
}

test_merge_no_local_uses_auto() {
  echo "T13: no local file → auto used as-is"
  local AUTO_DIR=$(mktemp -d)
  cat > "$AUTO_DIR/review-capability.json" <<'EOF'
{
  "level": "L3",
  "review_models": {
    "coding_vendor": "claude",
    "primary": "github-copilot/gpt-5.5",
    "panel_pool": ["bailian/deepseek-v4-pro"]
  }
}
EOF
  source "$SELECTION_LIB"
  local merged_primary
  merged_primary=$(merge_capability "$AUTO_DIR" | python3 -c "import json,sys; print(json.load(sys.stdin)['review_models']['primary'])")
  assert "auto primary used" "$([[ "$merged_primary" == "github-copilot/gpt-5.5" ]] && echo true || echo false)"
  rm -rf "$AUTO_DIR"
}

test_merge_local_override_blocks_same_vendor() {
  echo "T14: local override primary same vendor as coding → blocked"
  local AUTO_DIR=$(mktemp -d)
  cat > "$AUTO_DIR/review-capability.json" <<'EOF'
{
  "level": "L3",
  "review_models": {
    "coding_vendor": "claude",
    "primary": "github-copilot/gpt-5.5",
    "panel_pool": ["bailian/deepseek-v4-pro"]
  }
}
EOF
  cat > "$AUTO_DIR/review-capability.local.json" <<'EOF'
{
  "review_models": {
    "primary": "github-copilot/claude-sonnet-4.6"
  }
}
EOF
  source "$SELECTION_LIB"
  local rc
  merge_capability "$AUTO_DIR" >/dev/null 2>&1
  rc=$?
  assert "same vendor override blocked (non-zero exit)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  rm -rf "$AUTO_DIR"
}

# ============================================================
# §5: Fallback chain (D4)
# ============================================================
echo ""
echo "--- D4: fallback chain ---"

test_fallback_primary_fail_uses_panel() {
  echo "T15: primary fails → panel[0] used"
  source "$SELECTION_LIB"
  # Simulate: primary unreachable, panel[0] available
  local result
  result=$(run_fallback_chain \
    --primary "FAKE_UNREACHABLE_MODEL" \
    --panel "FAKE_AVAILABLE_MODEL_1,FAKE_AVAILABLE_MODEL_2" \
    --prompt "test review" 2>/dev/null)
  local rc=$?
  assert "fallback succeeded" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "used panel model" "$(echo "$result" | grep -q 'FAKE_AVAILABLE_MODEL_1\|panel' && echo true || echo false)"
}

test_fallback_all_fail_hetero_exhausted() {
  echo "T16: all fail → exit with HETERO_EXHAUSTED"
  source "$SELECTION_LIB"
  local result
  result=$(run_fallback_chain \
    --primary "FAKE_UNREACHABLE_1" \
    --panel "FAKE_UNREACHABLE_2,FAKE_UNREACHABLE_3" \
    --prompt "test review" 2>&1)
  local rc=$?
  assert "returns failure exit" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "HETERO_EXHAUSTED in output" "$(echo "$result" | grep -q 'HETERO_EXHAUSTED' && echo true || echo false)"
}

# ============================================================
# §6: panel_mode switch (D3)
# ============================================================
echo ""
echo "--- D3: panel_mode ---"

test_panel_mode_off_skips_panel() {
  echo "T17: panel_mode=off → only primary, no panel"
  local CAP_DIR=$(mktemp -d)
  cat > "$CAP_DIR/review-capability.json" <<'EOF'
{
  "level": "L3",
  "review_models": {
    "coding_vendor": "claude",
    "primary": "github-copilot/gpt-5.5",
    "panel_pool": ["bailian/deepseek-v4-pro", "bailian/kimi-k2.6"],
    "panel_active": 2,
    "panel_mode": "off"
  }
}
EOF
  source "$SELECTION_LIB"
  local models
  models=$(get_review_models "$CAP_DIR" "critical")
  local count
  count=$(echo "$models" | wc -l)
  assert "only 1 model (primary)" "$([[ $count -eq 1 ]] && echo true || echo false)"
  rm -rf "$CAP_DIR"
}

test_panel_mode_always_uses_panel() {
  echo "T18: panel_mode=always → panel even for trivial"
  local CAP_DIR=$(mktemp -d)
  cat > "$CAP_DIR/review-capability.json" <<'EOF'
{
  "level": "L3",
  "review_models": {
    "coding_vendor": "claude",
    "primary": "github-copilot/gpt-5.5",
    "panel_pool": ["bailian/deepseek-v4-pro", "bailian/kimi-k2.6"],
    "panel_active": 2,
    "panel_mode": "always"
  }
}
EOF
  source "$SELECTION_LIB"
  local models
  models=$(get_review_models "$CAP_DIR" "trivial")
  local count
  count=$(echo "$models" | wc -l)
  assert "3 models (primary + 2 panel)" "$([[ $count -eq 3 ]] && echo true || echo false)"
  rm -rf "$CAP_DIR"
}

# ============================================================
# Run all tests
# ============================================================

test_infer_vendor_omc
test_infer_vendor_omx
test_infer_vendor_omo
test_infer_vendor_override
test_select_primary_claude_coding
test_select_primary_gpt_coding
test_select_primary_other_coding
test_filter_pool_excludes_flash
test_filter_pool_excludes_claude
test_filter_pool_dedup_same_vendor
test_filter_pool_excludes_primary_vendor
test_merge_local_overrides_primary
test_merge_no_local_uses_auto
test_merge_local_override_blocks_same_vendor
test_fallback_empty_panel_primary_fails() {
  echo "T19: empty panel CSV + primary fails → HETERO_EXHAUSTED (no ghost iteration)"
  source "$SELECTION_LIB"
  local result
  result=$(run_fallback_chain \
    --primary "FAKE_UNREACHABLE_MODEL" \
    --panel "" \
    --prompt "test review" 2>&1)
  local rc=$?
  assert "returns failure" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "HETERO_EXHAUSTED" "$(echo "$result" | grep -q 'HETERO_EXHAUSTED' && echo true || echo false)"
}

test_fallback_model_used_tracking() {
  echo "T20: _REVIEW_MODEL_USED tracks which model succeeded"
  source "$SELECTION_LIB"
  _REVIEW_MODEL_USED=""
  run_fallback_chain \
    --primary "FAKE_UNREACHABLE_MODEL" \
    --panel "FAKE_AVAILABLE_MODEL_1,FAKE_AVAILABLE_MODEL_2" \
    --prompt "test" >/dev/null 2>&1
  assert "tracks panel model" "$([[ "$_REVIEW_MODEL_USED" == "FAKE_AVAILABLE_MODEL_1" ]] && echo true || echo false)"
}

test_fallback_primary_fail_uses_panel
test_fallback_all_fail_hetero_exhausted
test_fallback_empty_panel_primary_fails
test_fallback_model_used_tracking
test_panel_mode_off_skips_panel
test_panel_mode_always_uses_panel

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

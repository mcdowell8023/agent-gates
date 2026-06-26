#!/usr/bin/env bash
# tests/run_config_migrate.sh — agent-gates-config-migrate v1→v2 migration tests.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_MIGRATE="$SCRIPT_DIR/../bin/agent-gates-config-migrate"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

echo "=== agent-gates-config-migrate tests ==="
echo ""

# T-CM1: v1 review-capability.json with review_models → hetero-check.json with hetero_models
test_migrate_v1() {
  echo "T-CM1: v1 review-capability.json → hetero-check.json with hetero_models"
  (
    TMP=$(mktemp -d)
    export AGENT_GATES_DIR="$TMP"

    cat > "$TMP/review-capability.json" <<'EOFV1'
{
  "detected_at": "2026-01-01T00:00:00Z",
  "level": "L2",
  "review_models": {
    "primary": "github-copilot/gpt-5.5",
    "panel_pool": ["bailian/deepseek-v4-pro"],
    "panel_active": 1,
    "panel_mode": "auto"
  }
}
EOFV1

    bash "$CONFIG_MIGRATE" 2>/dev/null; rc=$?

    assert "exits 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "hetero-check.json created" "$([[ -f "$TMP/hetero-check.json" ]] && echo true || echo false)"
    if [[ -f "$TMP/hetero-check.json" ]]; then
      has_hetero=$(python3 -c "import json; d=json.load(open('$TMP/hetero-check.json')); print('yes' if 'hetero_models' in d else 'no')" 2>/dev/null || echo no)
      assert "hetero_models present" "$([[ "$has_hetero" == "yes" ]] && echo true || echo false)"
      version=$(python3 -c "import json; d=json.load(open('$TMP/hetero-check.json')); print(d.get('version',''))" 2>/dev/null || echo "")
      assert "version is 2.0.0" "$([[ "$version" == "2.0.0" ]] && echo true || echo false)"
      has_lifecycle=$(python3 -c "import json; d=json.load(open('$TMP/hetero-check.json')); print('yes' if 'lifecycle' in d else 'no')" 2>/dev/null || echo no)
      assert "lifecycle section present" "$([[ "$has_lifecycle" == "yes" ]] && echo true || echo false)"
    fi
    assert "v1bak created" "$([[ -f "$TMP/review-capability.json.v1bak" ]] && echo true || echo false)"
    assert "old file preserved (not deleted)" "$([[ -f "$TMP/review-capability.json" ]] && echo true || echo false)"

    rm -rf "$TMP"
  )
}

# T-CM2: no v1 config → creates default hetero-check.json
test_migrate_fresh() {
  echo "T-CM2: no v1 config → default hetero-check.json created"
  (
    TMP=$(mktemp -d)
    export AGENT_GATES_DIR="$TMP"

    bash "$CONFIG_MIGRATE" 2>/dev/null; rc=$?

    assert "exits 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "hetero-check.json created" "$([[ -f "$TMP/hetero-check.json" ]] && echo true || echo false)"
    if [[ -f "$TMP/hetero-check.json" ]]; then
      has_hetero=$(python3 -c "import json; d=json.load(open('$TMP/hetero-check.json')); print('yes' if 'hetero_models' in d else 'no')" 2>/dev/null || echo no)
      assert "hetero_models present" "$([[ "$has_hetero" == "yes" ]] && echo true || echo false)"
      version=$(python3 -c "import json; d=json.load(open('$TMP/hetero-check.json')); print(d.get('version',''))" 2>/dev/null || echo "")
      assert "version is 2.0.0" "$([[ "$version" == "2.0.0" ]] && echo true || echo false)"
    fi
    assert "no spurious v1bak" "$([[ ! -f "$TMP/review-capability.json.v1bak" ]] && echo true || echo false)"

    rm -rf "$TMP"
  )
}

test_migrate_v1
test_migrate_fresh

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

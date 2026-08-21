#!/usr/bin/env bash
# Tests for model-family resolution and the heterogeneity check.
#
# The gate must not know any specific provider. Providers come and go (opencode being
# uninstalled, Copilot swapped out, new vendors added) but the invariant is always the
# same: the reviewing model family must differ from the implementing one. So the provider
# prefix is stripped before the family is resolved — github-copilot/gpt-5.4 and
# azure/gpt-5.4 are both "openai".
#
# fail-closed rule: an unresolvable family can NEVER satisfy "different". Otherwise any
# unrecognised model id would silently pass the heterogeneity requirement.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/hetero/family.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
eq() { # eq <label> <got> <want>
  assert "$1 → $3 (实际 $2)" "$([[ "$2" == "$3" ]] && echo true || echo false)"
}

[[ -f "$LIB" ]] || { echo "  ✗ lib/hetero/family.sh 不存在（未实现）"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }
source "$LIB"

echo "=== hetero model-family tests ==="
echo

echo "F1: provider 前缀被剥掉——换 provider 不改变族"
eq "github-copilot/gpt-5.4"  "$(hetero_model_family github-copilot/gpt-5.4)"  openai
eq "azure/gpt-5.4"           "$(hetero_model_family azure/gpt-5.4)"           openai
eq "gpt-5.4"                 "$(hetero_model_family gpt-5.4)"                 openai
eq "volcengine-coding/deepseek-v4-flash" "$(hetero_model_family volcengine-coding/deepseek-v4-flash)" deepseek
eq "volcengine-chat/deepseek-v4-flash"   "$(hetero_model_family volcengine-chat/deepseek-v4-flash)"   deepseek

echo "F2: 常见族的默认规则"
eq "claude-opus-5"      "$(hetero_model_family claude-opus-5)"      anthropic
eq "claude-sonnet-4.6"  "$(hetero_model_family claude-sonnet-4.6)"  anthropic
eq "gemini-3.1-pro"     "$(hetero_model_family gemini-3.1-pro)"     google
eq "glm-5.3"            "$(hetero_model_family glm-5.3)"            zhipu
eq "kimi-k3"            "$(hetero_model_family kimi-k3)"            moonshot
eq "minimax-m3"         "$(hetero_model_family minimax-m3)"         minimax
eq "doubao-seed-2.1"    "$(hetero_model_family doubao-seed-2.1)"    bytedance
eq "grok-4.6"           "$(hetero_model_family grok-4.6)"           xai
eq "qmodel_38max"       "$(hetero_model_family qmodel_38max)"       alibaba

echo "F3: 无匹配 → unknown（不猜）"
eq "totally-new-model-9" "$(hetero_model_family totally-new-model-9)" unknown
eq "空字符串"            "$(hetero_model_family '')"                  unknown

echo "F4: 异构校验——不同族通过"
hetero_families_differ claude-opus-5 volcengine-coding/deepseek-v4-flash && r=true || r=false
assert "anthropic vs deepseek → 不同" "$r"
hetero_families_differ github-copilot/gpt-5.4 claude-opus-5 && r=true || r=false
assert "openai vs anthropic → 不同" "$r"

echo "F5: 同族被拒——含跨 provider 的同族"
hetero_families_differ claude-opus-5 github-copilot/claude-sonnet-4.6 && r=false || r=true
assert "anthropic vs anthropic（跨 provider）→ 相同，拒" "$r"
hetero_families_differ volcengine-coding/deepseek-v4-flash volcengine-agent-plan/deepseek-v4-pro && r=false || r=true
assert "deepseek vs deepseek（跨 provider）→ 相同，拒" "$r"

echo "F6: fail-closed——unknown 永远不满足「不同」"
hetero_families_differ totally-new-model-9 claude-opus-5 && r=false || r=true
assert "unknown vs anthropic → 拒（无法证明不同）" "$r"
hetero_families_differ claude-opus-5 totally-new-model-9 && r=false || r=true
assert "anthropic vs unknown → 拒" "$r"
hetero_families_differ '' '' && r=false || r=true
assert "两边都空 → 拒" "$r"

echo "F7: 也接受直接传族名（调用方已知实施族时不必给 model-id）"
hetero_families_differ github-copilot/gpt-5.4 anthropic && r=true || r=false
assert "model-id vs 族名 → 可比" "$r"

echo "F8: 配置可覆盖/新增规则"
(
  TMPD=$(mktemp -d)
  mkdir -p "$TMPD/.agent"
  cat > "$TMPD/.agent/hetero-check.json" <<'JSON'
{ "model_families": { "acme-*": "acme", "gpt-*": "acme-openai-fork" } }
JSON
  cd "$TMPD"
  _HETERO_FAMILY_CACHE=""   # force re-read
  eq "新增规则 acme-1" "$(hetero_model_family acme-1)" acme
  eq "覆盖内置 gpt-*"  "$(hetero_model_family gpt-5.4)" acme-openai-fork
  cd /; rm -rf "$TMPD"
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]

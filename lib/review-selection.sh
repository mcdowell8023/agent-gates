#!/usr/bin/env bash
# lib/review-selection.sh — v1.12.0 review model selection algorithm.
# Sourced library; provides pure functions for vendor inference, primary
# selection, panel pool filtering, capability merge, fallback chain.
# Requires: bash 4+, python3.

_extract_vendor() {
  local name="${1#*/}"
  case "$name" in
    *gpt*) echo "gpt" ;;
    *claude*) echo "claude" ;;
    *gemini*) echo "gemini" ;;
    *qwen*) echo "qwen" ;;
    *deepseek*) echo "deepseek" ;;
    *kimi*) echo "kimi" ;;
    *glm*) echo "glm" ;;
    *) echo "unknown" ;;
  esac
}

_model_strength() {
  local name="${1#*/}"
  case "$name" in
    *max*) echo 5 ;;
    *pro*) echo 4 ;;
    *plus*) echo 3 ;;
    *turbo*) echo 2 ;;
    *flash*) echo 1 ;;
    *) echo 3 ;;
  esac
}

infer_coding_vendor() {
  local platform="$1"
  local override="${2:-}"
  if [[ -n "$override" ]]; then
    echo "$override"
    return
  fi
  case "$platform" in
    omc) echo "claude" ;;
    omx|omo) echo "gpt" ;;
    *) echo "unknown" ;;
  esac
}

select_primary() {
  local coding_vendor="$1"
  case "$coding_vendor" in
    claude) echo "github-copilot/gpt-5.5" ;;
    gpt) echo "github-copilot/claude-sonnet-4.6" ;;
    *) echo "github-copilot/gpt-5.5" ;;
  esac
}

filter_panel_pool() {
  local coding_vendor="$1" primary="$2"
  shift 2
  local primary_vendor
  primary_vendor=$(_extract_vendor "$primary")

  local model
  for model in "$@"; do
    local name="${model#*/}"
    [[ "$name" == *flash* ]] && continue
    local v
    v=$(_extract_vendor "$model")
    [[ "$v" == "$coding_vendor" ]] && continue
    [[ "$v" == "$primary_vendor" ]] && continue
    printf '%s %s %s\n' "$(_model_strength "$model")" "$v" "$model"
  done | sort -t' ' -k1,1rn | awk '!seen[$2]++ {print $3}'
}

merge_capability() {
  local dir="$1"
  local auto_file="$dir/review-capability.json"
  local local_file="$dir/review-capability.local.json"

  if [[ ! -f "$auto_file" ]]; then
    echo "merge_capability: $auto_file not found" >&2
    return 1
  fi

  if [[ ! -f "$local_file" ]]; then
    cat "$auto_file"
    return 0
  fi

  python3 - "$auto_file" "$local_file" <<'PYEOF'
import json, sys

auto_path, local_path = sys.argv[1], sys.argv[2]
auto = json.load(open(auto_path))
local_data = json.load(open(local_path))

if 'review_models' in local_data:
    rm = auto.get('review_models', {})
    lrm = local_data['review_models']

    if 'primary' in lrm:
        coding_vendor = rm.get('coding_vendor', '')
        new_primary = lrm['primary']
        name = new_primary.split('/')[-1] if '/' in new_primary else new_primary
        vendors = ['gpt', 'claude', 'gemini', 'qwen', 'deepseek', 'kimi', 'glm']
        pv = 'unknown'
        for v in vendors:
            if v in name.lower():
                pv = v
                break
        if pv == coding_vendor:
            sys.exit(1)

    rm.update(lrm)
    auto['review_models'] = rm

json.dump(auto, sys.stdout)
PYEOF
  return $?
}

_try_review_model() {
  local model="$1" prompt="$2"

  if [[ "$model" == FAKE_AVAILABLE* ]]; then
    echo "review: panel model $model"
    return 0
  fi
  if [[ "$model" == FAKE_UNREACHABLE* || "$model" == FAKE_* ]]; then
    return 1
  fi

  local opencode_bin="${OC_REVIEW_OPENCODE:-opencode}"
  if ! command -v "$opencode_bin" &>/dev/null; then
    return 1
  fi
  local raw
  raw=$("$opencode_bin" run --pure -m "$model" --dir "${PWD}" --format json "$prompt" 2>/dev/null)
  [[ $? -ne 0 || -z "$raw" ]] && return 1
  echo "$raw"
  return 0
}

run_fallback_chain() {
  local primary="" panel="" prompt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --primary) primary="$2"; shift 2 ;;
      --panel) panel="$2"; shift 2 ;;
      --prompt) prompt="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _REVIEW_MODEL_USED=""

  if _try_review_model "$primary" "$prompt"; then
    _REVIEW_MODEL_USED="$primary"
    return 0
  fi

  if [[ -n "$panel" ]]; then
    IFS=',' read -ra panel_models <<< "$panel"
    local m
    for m in "${panel_models[@]}"; do
      [[ -z "$m" ]] && continue
      if _try_review_model "$m" "$prompt"; then
        _REVIEW_MODEL_USED="$m"
        return 0
      fi
    done
  fi

  echo "HETERO_EXHAUSTED: all review models failed (primary=$primary, panel=$panel)" >&2
  return 1
}

get_review_models() {
  local cap_dir="$1" severity="$2"
  local cap_file="$cap_dir/review-capability.json"

  if [[ ! -f "$cap_file" ]]; then
    return 1
  fi

  local primary panel_mode
  primary=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['review_models']['primary'])" "$cap_file" 2>/dev/null)
  panel_mode=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['review_models'].get('panel_mode','auto'))" "$cap_file" 2>/dev/null)

  echo "$primary"

  case "$panel_mode" in
    off) return 0 ;;
    always)
      python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
rm = d['review_models']
for m in rm.get('panel_pool', [])[:rm.get('panel_active', 2)]:
    print(m)
" "$cap_file" 2>/dev/null
      ;;
    auto|*)
      if [[ "$severity" == "critical" || "$severity" == "important" ]]; then
        python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
rm = d['review_models']
for m in rm.get('panel_pool', [])[:rm.get('panel_active', 2)]:
    print(m)
" "$cap_file" 2>/dev/null
      fi
      ;;
  esac
}

#!/usr/bin/env bash
# lib/hetero/select.sh — v1.12.0 review model selection algorithm.
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

  # v1.13.0: route through shared serve when available.
  # Fail-closed: if serve is not available/healthy, refuse to run bare.
  local attach_args=()
  local _oc_serve_lib="${BASH_SOURCE[0]%/*}/serve.sh"
  if [[ -f "$_oc_serve_lib" ]]; then
    source "$_oc_serve_lib"
    if oc_serve_health_check 2>/dev/null; then
      attach_args=(--attach "$OC_SERVE_URL")
    else
      return 1  # serve not healthy — fail-closed, don't run bare
    fi
  else
    return 1  # serve.sh not found — fail-closed, don't run bare
  fi

  local raw
  raw=$("$opencode_bin" run "${attach_args[@]}" --pure -m "$model" --dir "${PWD}" --format json "$prompt" 2>/dev/null)
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

# ============================================================
# D6: Doctor selection algorithm (v1.13.0)
# ============================================================

detect_available_models() {
  local opencode_bin="${1:-opencode}"
  "$opencode_bin" models 2>/dev/null | grep -E '^[a-zA-Z]' | sed 's/[[:space:]]*$//'
}

_probe_model() {
  local model="$1" opencode_bin="${2:-opencode}"
  local raw
  raw=$("$opencode_bin" run --pure -m "$model" --dir "${PWD}" --format json "say OK" 2>/dev/null)
  [[ $? -ne 0 ]] && return 1
  [[ -z "$raw" ]] && return 1
  return 0
}

# ============================================================
# P4: Shared risk-tier helpers (effort selection + high-risk path detection)
# Shared between CHECK 6 trigger logic and effort selection (design §3.2).
# ============================================================

# is_high_risk_path [file...]
#
# Returns exit 0 (high risk) when any file matches a high-risk pattern.
# Returns exit 1 (not high risk) otherwise.
# Prints "1" to stdout when high risk, "0" when not — for use with $(...).
#
# File list: positional args, or staged files from `git diff --cached` if none.
# Pattern override: HETERO_HIGH_RISK_PATTERNS (comma-separated substrings).
is_high_risk_path() {
  local _hr_default_patterns="auth/,security/,payment/,migration/,pages/,routes/,components/,views/,service/"
  local _hr_patterns_raw="${HETERO_HIGH_RISK_PATTERNS:-$_hr_default_patterns}"

  # Parse pattern list
  local _hr_patterns=()
  local _hr_IFS_save="$IFS"
  IFS=',' read -ra _hr_patterns <<< "$_hr_patterns_raw"
  IFS="$_hr_IFS_save"

  # Collect file list
  local _hr_files=()
  if [[ $# -gt 0 ]]; then
    _hr_files=("$@")
  else
    local _hr_f
    while IFS= read -r _hr_f; do
      [[ -n "$_hr_f" ]] && _hr_files+=("$_hr_f")
    done < <(git diff --cached --name-only 2>/dev/null)
  fi

  [[ ${#_hr_files[@]} -eq 0 ]] && { echo "0"; return 1; }

  local f pat
  for f in "${_hr_files[@]}"; do
    for pat in "${_hr_patterns[@]}"; do
      # Trim leading/trailing whitespace from pattern
      pat="${pat#"${pat%%[![:space:]]*}"}"
      pat="${pat%"${pat##*[![:space:]]}"}"
      [[ -z "$pat" ]] && continue
      if [[ "$f" == *"$pat"* ]]; then
        echo "1"
        return 0  # high risk
      fi
    done
  done

  echo "0"
  return 1  # not high risk
}

# select_effort <role> <is_high_risk>
#
# role        : "reviewer" or "verifier"
# is_high_risk: "0" (normal tier) or "1" (high_risk tier)
#
# Resolution order (design §7):
#   1. env HETERO_EFFORT_<ROLE_UPPER>_<TIER_UPPER>  (e.g. HETERO_EFFORT_REVIEWER_NORMAL)
#   2. hetero-check.json  effort.<role>.<tier>
#   3. builtin defaults   normal=medium, high_risk=high
#
# Outputs effort string to stdout: "low" | "medium" | "high" | "max"
select_effort() {
  local role="${1:-reviewer}"
  local is_high_risk="${2:-0}"

  local tier
  if [[ "$is_high_risk" == "1" ]]; then
    tier="high_risk"
  else
    tier="normal"
  fi

  local role_upper tier_upper env_val
  role_upper=$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')
  tier_upper=$(printf '%s' "$tier" | tr '[:lower:]' '[:upper:]')
  local env_var="HETERO_EFFORT_${role_upper}_${tier_upper}"

  # Priority 1: env override — eval indirect expansion for bash 3.2 compat
  eval "env_val=\"\${${env_var}:-}\""
  if [[ -n "$env_val" ]]; then
    echo "$env_val"
    return 0
  fi

  # Priority 2: JSON config
  local gates_dir="${AGENT_GATES_DIR:-$HOME/.agent-gates}"
  local config_file="$gates_dir/hetero-check.json"
  if [[ -f "$config_file" ]]; then
    local json_val
    json_val=$(python3 - "$config_file" "$role" "$tier" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    val = d.get('effort', {}).get(sys.argv[2], {}).get(sys.argv[3])
    if val:
        print(val)
except Exception:
    pass
PYEOF
)
    if [[ -n "$json_val" ]]; then
      echo "$json_val"
      return 0
    fi
  fi

  # Priority 3: builtin defaults
  if [[ "$tier" == "high_risk" ]]; then
    echo "high"
  else
    echo "medium"
  fi
}

build_review_models() {
  local platform="$1" rec_file="$2"
  local opencode_bin="${OC_REVIEW_OPENCODE:-opencode}"

  local coding_vendor
  coding_vendor=$(infer_coding_vendor "$platform")

  local primary
  primary=$(select_primary "$coding_vendor")

  local available
  available=$(detect_available_models "$opencode_bin")
  [[ -z "$available" ]] && return 1

  if ! _probe_model "$primary" "$opencode_bin"; then
    return 1
  fi

  local rec_models=""
  if [[ -f "$rec_file" ]]; then
    rec_models=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
for v, ms in d.get('vendors', {}).items():
    for m in ms:
        print(m)
" "$rec_file" 2>/dev/null)
  fi

  local pool=()
  local primary_vendor
  primary_vendor=$(_extract_vendor "$primary")

  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    local name="${model#*/}"
    [[ "$name" == *flash* ]] && continue
    local v
    v=$(_extract_vendor "$model")
    [[ "$v" == "$coding_vendor" ]] && continue
    [[ "$v" == "$primary_vendor" ]] && continue
    [[ "$v" == "unknown" ]] && continue

    if [[ -n "$rec_models" ]] && ! echo "$rec_models" | grep -qF "$model"; then
      continue
    fi

    if _probe_model "$model" "$opencode_bin"; then
      pool+=("$model")
    fi
  done <<< "$available"

  local pool_json="[]"
  if [[ ${#pool[@]} -gt 0 ]]; then
    pool_json=$(printf '%s\n' "${pool[@]}" | python3 -c "import json,sys;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  fi

  python3 -c "
import json
print(json.dumps({
    'coding_vendor': '$coding_vendor',
    'primary': '$primary',
    'panel_pool': $pool_json,
    'panel_active': 2,
    'panel_mode': 'auto'
}))
"
}

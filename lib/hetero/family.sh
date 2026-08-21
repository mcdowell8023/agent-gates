#!/usr/bin/env bash
# lib/hetero/family.sh — model-family resolution for the heterogeneity requirement.
#
# The gate deliberately knows NO specific provider. Providers come and go: opencode gets
# uninstalled, a Copilot subscription is swapped out, a new vendor appears. What never
# changes is the invariant — the reviewing model family must differ from the implementing
# one. So the provider prefix is stripped before resolving: github-copilot/gpt-5.4 and
# azure/gpt-5.4 are both "openai", volcengine-coding/deepseek-v4-flash and
# volcengine-chat/deepseek-v4-flash are both "deepseek".
#
# Rules can be overridden or extended in .agent/hetero-check.json:
#     { "model_families": { "acme-*": "acme" } }
# Configured patterns win over the built-ins, so a vendor fork can be reclassified without
# touching this file.
#
# fail-closed: an unresolvable family can NEVER satisfy "different" (see
# hetero_families_differ). Otherwise any unrecognised model id would silently pass the
# heterogeneity requirement — the exact shape of bug this subsystem keeps producing
# (a check that exists but does not check the thing that matters).

[[ -n "${_HETERO_FAMILY_SOURCED:-}" ]] && return 0
_HETERO_FAMILY_SOURCED=1

_HETERO_FAMILY_CACHE=""
_HETERO_FAMILY_RULES=""   # newline-separated "<pattern>\t<family>"

# Load configured rules once. Uses a newline-separated string rather than an array so this
# stays safe under `set -u` on macOS's bash 3.2, where empty-array expansion is a trap.
_hetero_family_load_config() {
  _HETERO_FAMILY_CACHE="loaded"
  _HETERO_FAMILY_RULES=""
  local f
  for f in ".agent/hetero-check.json" "${HOME}/.agent-gates/hetero-check.json"; do
    [[ -f "$f" ]] || continue
    _HETERO_FAMILY_RULES=$(python3 -c '
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
mf = d.get("model_families") or {}
if isinstance(mf, dict):
    for k, v in mf.items():
        if k and v:
            print("%s\t%s" % (k, v))
' "$f" 2>/dev/null) || _HETERO_FAMILY_RULES=""
    break
  done
}

# Echo the configured family for an id, or nothing. Returns 1 when no rule matches.
_hetero_family_from_config() {
  local id="$1" line pat fam
  [[ "${_HETERO_FAMILY_CACHE:-}" == "loaded" ]] || _hetero_family_load_config
  [[ -z "$_HETERO_FAMILY_RULES" ]] && return 1
  while IFS=$'\t' read -r pat fam; do
    [[ -z "$pat" || -z "$fam" ]] && continue
    # Unquoted $pat on purpose — it is a glob such as "acme-*".
    if [[ "$id" == $pat ]]; then printf '%s' "$fam"; return 0; fi
  done <<< "$_HETERO_FAMILY_RULES"
  return 1
}

# hetero_model_family <model-id | family-name> -> family (lowercase) or "unknown"
hetero_model_family() {
  local raw="${1:-}" id fam
  [[ -z "$raw" ]] && { echo unknown; return 0; }
  # The family is a property of the model, not of whoever serves it.
  id="${raw##*/}"
  id=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')

  # A bare family name is a valid input: callers often know the implementer family without
  # having a concrete model id to hand.
  case "$id" in
    anthropic|openai|google|deepseek|zhipu|moonshot|minimax|bytedance|xai|alibaba|nvidia|meta|mistral|tencent)
      echo "$id"; return 0 ;;
  esac

  if fam=$(_hetero_family_from_config "$id"); then
    echo "$fam"; return 0
  fi

  case "$id" in
    claude-*|opus-*|sonnet-*|haiku-*)          echo anthropic ;;
    gpt-*|o1-*|o3-*|o4-*|codex-*)              echo openai ;;
    gemini-*)                                   echo google ;;
    deepseek-*)                                 echo deepseek ;;
    glm-*)                                      echo zhipu ;;
    kimi-*)                                     echo moonshot ;;
    minimax-*|mimo-*)                           echo minimax ;;
    doubao-*|ark-*)                             echo bytedance ;;
    grok-*)                                     echo xai ;;
    qwen-*|qmodel*)                             echo alibaba ;;
    nemotron-*)                                 echo nvidia ;;
    llama-*)                                    echo meta ;;
    mistral-*|mixtral-*)                        echo mistral ;;
    hy3*|hunyuan*)                              echo tencent ;;
    *)                                          echo unknown ;;
  esac
}

# hetero_families_differ <reviewer: model-id|family> <implementer: model-id|family>
# Returns 0 only when both families resolve AND differ. Unknown on either side returns 1:
# "cannot prove different" must not read as "is different".
hetero_families_differ() {
  local a b
  a=$(hetero_model_family "${1:-}")
  b=$(hetero_model_family "${2:-}")
  [[ "$a" == unknown || "$b" == unknown ]] && return 1
  [[ "$a" != "$b" ]]
}

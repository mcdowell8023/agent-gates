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
# Rules come from two places with DIFFERENT trust, because one of them is writable by the
# very agent being reviewed:
#     ~/.agent-gates/hetero-check.json   user-controlled  → may override the built-ins
#     .agent/hetero-check.json           in the work tree → may only name families for ids
#                                                            the built-ins do not recognise
# Format: { "model_families": { "acme-*": "acme" } }
#
# ⚠️ Residual risk, stated rather than hidden: the repo-local source can still claim any id
# the built-in table misses. That table cannot be exhaustive, so a genuinely known vendor id
# absent from it remains relabelable. Adding bare/aliased forms as they surface is the only
# mitigation; set HETERO_FAMILY_NO_REPO_CONFIG=1 to refuse the repo-local source entirely.
#
# fail-closed: an unresolvable family can NEVER satisfy "different" (see
# hetero_families_differ). Otherwise any unrecognised model id would silently pass the
# heterogeneity requirement — the exact shape of bug this subsystem keeps producing
# (a check that exists but does not check the thing that matters).

[[ -n "${_HETERO_FAMILY_SOURCED:-}" ]] && return 0
_HETERO_FAMILY_SOURCED=1

_HETERO_FAMILY_CACHE=""
# Two config sources with DIFFERENT trust levels (cross-review 2026-08-21 #3):
#   TRUSTED — ~/.agent-gates/hetero-check.json, a user-controlled location. May override
#             built-ins, e.g. to reclassify a vendor fork.
#   REPO    — .agent/hetero-check.json, inside the work tree the reviewed agent can write.
#             May only SUPPLY families for ids the built-ins do not recognise; it must not
#             be able to relabel a known family. Otherwise one line
#             ({"model_families":{"claude-*":"openai"}}) turns same-family self-review into
#             "heterogeneous" and buys FULL.
_HETERO_FAMILY_RULES_TRUSTED=""
_HETERO_FAMILY_RULES_REPO=""

# Load configured rules once. Uses a newline-separated string rather than an array so this
# stays safe under `set -u` on macOS's bash 3.2, where empty-array expansion is a trap.
_hetero_family_read_rules() {
  python3 -c '
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
' "$1" 2>/dev/null || true
}

_hetero_family_load_config() {
  _HETERO_FAMILY_CACHE="loaded"
  _HETERO_FAMILY_RULES_TRUSTED=""
  _HETERO_FAMILY_RULES_REPO=""
  local tf="${HOME}/.agent-gates/hetero-check.json"
  local rf=".agent/hetero-check.json"
  [[ -f "$tf" ]] && _HETERO_FAMILY_RULES_TRUSTED=$(_hetero_family_read_rules "$tf")
  if [[ "${HETERO_FAMILY_NO_REPO_CONFIG:-0}" != "1" && -f "$rf" ]]; then
    _HETERO_FAMILY_RULES_REPO=$(_hetero_family_read_rules "$rf")
  fi
}

# Echo the family matched by a rule set, or nothing. Returns 1 when no rule matches.
_hetero_family_match() {
  local id="$1" rules="$2" pat fam
  [[ -z "$rules" ]] && return 1
  while IFS=$'\t' read -r pat fam; do
    [[ -z "$pat" || -z "$fam" ]] && continue
    # Unquoted $pat on purpose — it is a glob such as "acme-*".
    if [[ "$id" == $pat ]]; then printf '%s' "$fam"; return 0; fi
  done <<< "$rules"
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

  [[ "${_HETERO_FAMILY_CACHE:-}" == "loaded" ]] || _hetero_family_load_config

  # Trusted config may override the built-ins.
  if fam=$(_hetero_family_match "$id" "$_HETERO_FAMILY_RULES_TRUSTED"); then
    echo "$fam"; return 0
  fi

  case "$id" in
    # Bare forms matter: paseo takes `--provider claude/opus`, which strips to "opus".
    claude|claude-*|opus|opus-*|sonnet|sonnet-*|haiku|haiku-*) echo anthropic ;;
    # Bare forms must be listed too: anything the built-ins miss falls through to *),
    # where repo-local config may name it — so a missing bare form is a relabel hole
    # (cross-review round 2 found bare o1/o3 exactly this way).
    gpt|gpt-*|o1|o1-*|o3|o3-*|o4|o4-*|codex|codex-*) echo openai ;;
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
    *)
      # Only now may the repo-local config speak: it can name a family the built-ins do
      # not know, but never relabel one they do.
      if fam=$(_hetero_family_match "$id" "$_HETERO_FAMILY_RULES_REPO"); then
        echo "$fam"
      else
        echo unknown
      fi
      ;;
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

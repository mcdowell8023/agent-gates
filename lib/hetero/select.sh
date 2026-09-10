#!/usr/bin/env bash
# lib/hetero/select.sh — v1.12.0 review model selection algorithm.
# Sourced library; provides pure functions for vendor inference, primary
# selection, panel pool filtering, capability merge, fallback chain.
# Requires: bash 4+, python3.

# ⚠️ This is a SECOND vendor table — 8 vendors here, against the 14 families in
# lib/hetero/family.sh (which include xai/bytedance/tencent/minimax). That one answers in
# company names
# — anthropic/openai/google — while this one answers in the marketing names that
# `infer_coding_vendor` and the persisted `coding_vendor` field already use
# (claude/gpt/gemini). Merging them means remapping both plus every stored config, so
# they stay separate for now. The cost of that split is that a vendor added to one is
# NOT known to the other: `doubao` / `hunyuan` / `mai-code` / `minimax` all still land
# in "unknown" here.
#
# "unknown" is not inert. build_review_models has `[[ "$v" == "unknown" ]] && continue`,
# so an unrecognised vendor is dropped from the panel pool silently — configure the
# model all you like, it will never be a candidate and nothing says why.
_extract_vendor() {
  local name="${1#*/}"
  case "$name" in
    *gpt*) echo "gpt" ;;
    *claude*) echo "claude" ;;
    *gemini*) echo "gemini" ;;
    *grok*) echo "grok" ;;
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
        # Keep in step with _extract_vendor above — this is the same table, a third time,
        # in python. Missing a vendor here does not drop the model; it makes pv 'unknown',
        # which collides with coding_vendor 'unknown' (platform undetected) and rejects the
        # whole local config with a bare exit 1.
        vendors = ['gpt', 'claude', 'gemini', 'grok', 'qwen', 'deepseek', 'kimi', 'glm']
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

# ============================================================
# Review channels (v2.9.3)
# ============================================================
# THE GAP this closes: `channels.opencode.enabled=false` was set on 2026-08-26 and the
# docs demoted opencode to third choice, but no code path under `agent-gates-review` ever
# read either. `_try_review_model` shelled straight out to the opencode binary. The one
# function that does implement a pi channel AND does read the flag — `hetero_dispatch` —
# has no production caller at all (every non-comment reference is in tests/).
#
# bin/oc-review:69 already said so out loud:
#   "v2.4.0 turned that channel off by default, but only hetero_dispatch consults the flag."
#
# The cost was not a stale setting. The user's standing instruction is "⛔ never review with
# opencode"; two sub-sessions reviewed through it anyway and reported PASS. A ban that only
# travels in task briefs is a ban the tool cannot enforce.

# Only an EXPLICIT disable is enforced here — a missing file or key means "nobody said to
# turn it off", matching bin/oc-review's guard. Preference between channels is expressed by
# the order they are tried in, not by defaults.
_review_chan_enabled() {   # _review_chan_enabled <channel>
  local chan="$1" envvar ev
  # NOTE: `tr`, not ${chan^^} — macOS ships bash 3.2 where that is a runtime
  # "bad substitution", and this function failing open would re-enable a banned channel.
  envvar="HETERO_CHAN_$(printf '%s' "$chan" | tr '[:lower:]-' '[:upper:]_')"
  ev="${!envvar:-}"
  if [[ -n "$ev" ]]; then
    [[ "$ev" == "1" ]]
    return
  fi
  local f="${AGENT_GATES_DIR:-$HOME/.agent-gates}/hetero-check.json"
  [[ -f "$f" ]] || return 0
  local v
  v=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
c = (d.get("channels") or {}).get(sys.argv[2]) or {}
e = c.get("enabled")
print("" if e is None else ("1" if e else "0"))
' "$f" "$chan" 2>/dev/null)
  [[ "$v" != "0" ]]
}

# Which tool/model actually answered. Set as shell variables for in-process callers, and
# ALSO written to $_REVIEW_SIDECAR when that is set — because the real caller runs
# `_raw=$(run_fallback_chain ...)`, and a variable assigned inside a command substitution
# dies with the subshell. `_REVIEW_MODEL_USED` has always had that hole; it went unnoticed
# because the caller silently defaults to the primary model, so a panel model's review was
# stamped with the primary's name.
_review_record_tool() {   # _review_record_tool <tool> <model>
  _REVIEW_TOOL_USED="$1"
  _REVIEW_MODEL_USED="$2"
  [[ -n "${_REVIEW_SIDECAR:-}" ]] || return 0
  printf 'tool=%s\nmodel=%s\n' "$1" "$2" > "$_REVIEW_SIDECAR" 2>/dev/null || true
}

# Shared bound. Both backends refuse rather than run unbounded: an unbounded review was
# measured burning 80 minutes and producing nothing.
#
# ⚠️ The two channels need DIFFERENT defaults. `AG_REVIEW_TIMEOUT`'s 120s was tuned for
# opencode, where 120s is already the point past which that channel is considered wedged.
# pi is not wedged at 120s — it is working: a real review that reads files took 1.5–4.5
# minutes across four measured runs on 2026-09-08/09, and the first end-to-end run of this
# very channel died at 200s mid-review. Inheriting 120s would make a healthy pi channel
# look broken on every non-trivial review, and the caller would see a timeout rather than
# "this needs longer".
_review_timeout_cmd() {   # _review_timeout_cmd [channel]
  local wt="${BASH_SOURCE[0]%/*}/../../bin/with-timeout.mjs"
  [[ -f "$wt" ]] && command -v node >/dev/null 2>&1 || return 1
  local secs
  case "${1:-opencode}" in
    pi) secs="${AG_REVIEW_PI_TIMEOUT:-${AG_REVIEW_TIMEOUT:-300}}" ;;
    *)  secs="${AG_REVIEW_TIMEOUT:-120}" ;;
  esac
  printf '%s\n%s\n%s\n' node "$wt" "$secs"
}

# The number actually used, so the timeout message can name it truthfully.
_review_timeout_secs() {  # _review_timeout_secs [channel]
  case "${1:-opencode}" in
    pi) echo "${AG_REVIEW_PI_TIMEOUT:-${AG_REVIEW_TIMEOUT:-300}}" ;;
    *)  echo "${AG_REVIEW_TIMEOUT:-120}" ;;
  esac
}

_review_via_pi() {
  local model="$1" prompt="$2"
  local pi_bin="${AG_REVIEW_PI:-pi}"

  if ! command -v "$pi_bin" &>/dev/null; then
    _REVIEW_CHAN_NOTES="${_REVIEW_CHAN_NOTES}pi: no '$pi_bin' on PATH; "
    return 1
  fi

  # A slash alone is not enough: `github-copilot/` and `/gpt-5.6-sol` both match `*/*` yet
  # leave one side empty, and `pi --provider ""` does not fail fast. Same guard the
  # dispatch-side pi channel carries.
  if [[ "$model" != */* || -z "${model%%/*}" || -z "${model#*/}" ]]; then
    _REVIEW_CHAN_NOTES="${_REVIEW_CHAN_NOTES}pi: '$model' is not a '<provider>/<model>' pair (both sides must be non-empty), e.g. github-copilot/gpt-5.6-sol; "
    return 1
  fi
  local provider="${model%%/*}" id="${model#*/}"

  local _tc
  if ! _tc=$(_review_timeout_cmd pi); then
    echo "review-fail[$model]: timeout wrapper unavailable (bin/with-timeout.mjs, node required) — refusing to run pi unbounded (fail-closed)" >&2
    return 1
  fi
  local timeout_cmd=() _l
  while IFS= read -r _l; do [[ -n "$_l" ]] && timeout_cmd+=("$_l"); done <<< "$_tc"

  # ⛔ Read-only tool set, not a style preference. pi's defaults include edit/write/bash,
  # and on 2026-09-01 a reviewer used them: it modified the source under review, created a
  # branch, and pushed it. `--provider` and `--model` are two separate flags — writing
  # `--model provider/model` as one string is the documented footgun.
  local raw rc secs
  secs=$(_review_timeout_secs pi)
  # ⚠️ `if X=$(...); then` — NOT `X=$(...)` followed by `rc=$?`. The gate sources this file
  # (hooks/git/agent-quality-gate.sh:664) and runs under `set -euo pipefail`, where a failing
  # command substitution terminates the process BEFORE `rc=$?` executes, with no message at
  # all. The whole error-handling block below would be unreachable. Same shape that once made
  # the gate exit 1 straight after printing its banner.
  if raw=$(${timeout_cmd[@]+"${timeout_cmd[@]}"} "$pi_bin" -p \
        --provider "$provider" --model "$id" \
        --tools read,grep,find,ls \
        "$prompt" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc -eq 124 ]]; then
    echo "review-fail[$model]: pi timed out after ${secs}s (raise AG_REVIEW_TIMEOUT, or narrow the prompt — an unbounded 'go find everything' prompt makes the model crawl the repo)" >&2
    return 1
  fi
  if [[ $rc -ne 0 ]]; then
    echo "review-fail[$model]: pi exited $rc" >&2
    return 1
  fi
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    echo "review-fail[$model]: pi exited 0 but produced empty output" >&2
    return 1
  fi

  # ⛔ pi returns PLAIN TEXT. Do not send it through parse_opencode_json — that helper
  # parses an NDJSON stream and yields empty for plain text, which would read as
  # "the model answered nothing" and fall through every channel.
  # ⛔ fail-CLOSED on a missing helper. The opencode path skips its checks when the helper
  # is absent (it is sourced from bin/agent-gates-review), but pi's raw text IS the final
  # artifact — there is no later parse step inside this file to catch a verdict-less answer.
  # Skipping here would accept an error message, a refusal, or a half-written reply as a
  # passing review.
  if ! declare -f has_valid_conclusion >/dev/null 2>&1; then
    echo "review-fail[$model]: has_valid_conclusion is not defined — cannot tell a review from arbitrary output, refusing to accept it (fail-closed). Source bin/agent-gates-review's helpers, or define has_valid_conclusion before calling." >&2
    return 1
  fi
  if ! has_valid_conclusion "$raw"; then
    echo "review-fail[$model]: answered ${#raw} chars but produced no VERDICT line — the prompt must require a line matching 'VERDICT: PASS|REVISE|FAIL|ISSUES|APPROVED|REJECT'. Model said: $(printf '%.200s' "$raw" | tr '\n' ' ')" >&2
    return 1
  fi

  printf '%s\n' "$raw"
  return 0
}

_try_review_model() {
  local model="$1" prompt="$2"

  if [[ "$model" == FAKE_AVAILABLE* ]]; then
    _review_record_tool fake "$model"
    echo "review: panel model $model"
    return 0
  fi
  if [[ "$model" == FAKE_UNREACHABLE* || "$model" == FAKE_* ]]; then
    return 1
  fi

  # Channel order IS the preference: pi first. pi is one-shot (~200MB peak, zero residue),
  # while opencode needs a long-lived `opencode serve` — one was observed at 4 days uptime
  # and 133 minutes of CPU with no client on the machine.
  # Channel notes accumulate and are printed ONLY if nothing succeeds. On a machine
  # without pi, announcing "pi not found" ahead of every successful opencode review is
  # noise that actively misleads — a caller reading it alongside a real error concludes
  # the model was unreachable when the model in fact answered.
  _REVIEW_CHAN_NOTES=""
  local tried=0
  if _review_chan_enabled pi; then
    tried=1
    if _review_via_pi "$model" "$prompt"; then
      _review_record_tool pi "$model"
      return 0
    fi
  else
    _REVIEW_CHAN_NOTES="${_REVIEW_CHAN_NOTES}pi: disabled (channels.pi.enabled=false / HETERO_CHAN_PI=0); "
  fi

  if _review_chan_enabled opencode; then
    tried=1
    if _review_via_opencode "$model" "$prompt"; then
      _review_record_tool opencode "$model"
      return 0
    fi
  else
    _REVIEW_CHAN_NOTES="${_REVIEW_CHAN_NOTES}opencode: disabled (channels.opencode.enabled=false / HETERO_CHAN_OPENCODE=0); "
  fi

  if [[ "$tried" -eq 0 ]]; then
    echo "review-fail[$model]: both the pi and the opencode channel are disabled — there is nothing left to review with. Enable one: channels.pi.enabled / channels.opencode.enabled in hetero-check.json, or HETERO_CHAN_PI=1 / HETERO_CHAN_OPENCODE=1. [$_REVIEW_CHAN_NOTES]" >&2
  elif [[ -n "$_REVIEW_CHAN_NOTES" ]]; then
    echo "review[$model]: channels skipped — ${_REVIEW_CHAN_NOTES%; }" >&2
  fi
  return 1
}

_review_via_opencode() {
  local model="$1" prompt="$2"

  local opencode_bin="${OC_REVIEW_OPENCODE:-opencode}"
  if ! command -v "$opencode_bin" &>/dev/null; then
    echo "review-fail[$model]: opencode binary not found ($opencode_bin)" >&2
    return 1
  fi

  # v1.13.0: route through shared serve when available.
  # Fail-closed: if serve is not available/startable, refuse to run bare.
  #
  # v2.0.2: ensure, not merely probe. This used to call oc_serve_health_check, so once the
  # shared serve died the opencode channel was permanently unavailable — every review fell
  # through to codex, and the caller-facing message did not say why. Note the asymmetry
  # this fixes: the legacy run_opencode path has always used oc_serve_ensure, so the
  # hetero path was strictly more fragile than the one it replaced. oc_serve_ensure still
  # yields an attach URL or fails, so the fail-closed guarantee is unchanged.
  local attach_args=()
  local _oc_serve_lib="${BASH_SOURCE[0]%/*}/serve.sh"
  if [[ -f "$_oc_serve_lib" ]]; then
    source "$_oc_serve_lib"
    if oc_serve_ensure 2>/dev/null; then
      attach_args=(--attach "$OC_SERVE_URL")
    else
      echo "review-fail[$model]: shared opencode serve is down and could not be started (${OC_SERVE_URL:-unset}) — refusing to run bare (fail-closed). Try: oc-reaper --apply, then retry" >&2
      return 1
    fi
  else
    echo "review-fail[$model]: serve.sh not found at $_oc_serve_lib — refusing to run bare (fail-closed)" >&2
    return 1
  fi

  # v2.0.2: bound every invocation. bin/with-timeout.mjs shipped since v1.x but was
  # never wired to any call site, so a request that never came back hung the whole
  # review chain — one observed run burned 80 minutes and produced nothing.
  local _wt="${BASH_SOURCE[0]%/*}/../../bin/with-timeout.mjs"
  local _timeout_secs="${AG_REVIEW_TIMEOUT:-120}"
  if [[ ! -f "$_wt" ]] || ! command -v node >/dev/null 2>&1; then
    # fail-closed, same posture as the serve guard above. Degrading to an unbounded run
    # would silently drop the guarantee this block exists to provide, and an unbounded
    # run is exactly how a review once went 80 minutes and produced nothing.
    echo "review-fail[$model]: timeout wrapper unavailable ($_wt, node required) — refusing to run unbounded (fail-closed)" >&2
    return 1
  fi
  local timeout_cmd=(node "$_wt" "$_timeout_secs")

  # Neither array can actually be empty at this point: the check above fails closed so
  # timeout_cmd is always populated, and the serve guard populates attach_args on the only
  # path that reaches here (every other branch returns). The guarded expansion is kept on
  # timeout_cmd regardless — bash 3.2 (macOS default) errors under `set -u` on "${arr[@]}"
  # for an empty array, and staying safe against a future edit costs nothing here.
  local raw rc
  # Same errexit guard as the pi path above — this line predates it and carried the same
  # hole; fixing only the new one is the asymmetry that comes back later.
  if raw=$(${timeout_cmd[@]+"${timeout_cmd[@]}"} "$opencode_bin" run "${attach_args[@]}" --pure -m "$model" --dir "${PWD}" --format json "$prompt" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc -eq 124 ]]; then
    echo "review-fail[$model]: opencode timed out after ${_timeout_secs}s (raise AG_REVIEW_TIMEOUT, or narrow the prompt — an unbounded 'go find everything' prompt makes the model crawl the repo)" >&2
    return 1
  fi
  if [[ $rc -ne 0 ]]; then
    echo "review-fail[$model]: opencode exited $rc" >&2
    return 1
  fi
  if [[ -z "$raw" ]]; then
    echo "review-fail[$model]: opencode exited 0 but produced empty output" >&2
    return 1
  fi

  # v2.0.2: judge usability here, so an answer that cannot be used falls through to
  # the next model instead of dead-ending in the caller. Both helpers are defined in
  # bin/agent-gates-review; when select.sh is sourced elsewhere they may be absent,
  # in which case skip the check rather than fail.
  if declare -f parse_opencode_json >/dev/null 2>&1; then
    local parsed
    parsed=$(printf '%s' "$raw" | parse_opencode_json)
    if [[ -z "${parsed//[[:space:]]/}" ]]; then
      echo "review-fail[$model]: opencode returned ${#raw} bytes but NDJSON parsed to empty text" >&2
      return 1
    fi
    if declare -f has_valid_conclusion >/dev/null 2>&1 && ! has_valid_conclusion "$parsed"; then
      echo "review-fail[$model]: answered ${#parsed} chars but produced no VERDICT line — the prompt must require a line matching 'VERDICT: PASS|REVISE|FAIL|ISSUES|APPROVED|REJECT'. Model said: $(printf '%.200s' "$parsed" | tr '\n' ' ')" >&2
      return 1
    fi
  fi

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
  _REVIEW_TOOL_USED=""

  # ⛔ Do NOT re-assign _REVIEW_MODEL_USED here: _try_review_model already recorded which
  # model AND which tool answered, via _review_record_tool. Setting it again from the loop
  # variable is how the tool name would get lost.
  if _try_review_model "$primary" "$prompt"; then
    return 0
  fi

  if [[ -n "$panel" ]]; then
    IFS=',' read -ra panel_models <<< "$panel"
    local m
    for m in "${panel_models[@]}"; do
      [[ -z "$m" ]] && continue
      if _try_review_model "$m" "$prompt"; then
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

# Both probes shell out to opencode — the one channel already measured wedging for
# 120–200s — and neither had a timeout. doctor.sh was observed at 6+ minutes, CPU 0%,
# having never reached the point where it writes hetero-check.json. The visible symptom was
# elsewhere: `review_models.primary` sat on a retired model, because the only path that
# refreshes it both required opencode AND never finished. A maintenance step slow enough to
# never complete is indistinguishable from one that does not exist.
#
# ⚠️ Still opencode-only. When opencode is uninstalled, build_review_models returns 1 and
# `review_models` simply is not refreshed — which is survivable now only because doctor
# MERGES rather than rewrites (lib/hetero/persist.sh); before that fix the key was dropped
# entirely. Moving the probe to `pi` (~7s, the documented primary channel) is the real fix
# and is not done here.
_hetero_probe_timeout() {  # _hetero_probe_timeout <default>
  local t="${HETERO_PROBE_TIMEOUT:-$1}"
  # A misconfigured value must not degrade to "no timeout" — that is the state being fixed.
  [[ "$t" =~ ^[0-9]+$ ]] || t="$1"
  # 10# forces base 10. `^[0-9]+$` happily passes "08", and bash arithmetic then reads it as
  # octal: `[[ 08 -lt 1 ]]` prints `value too great for base` and leaks a baffling error to
  # the terminal. Measured, not theorised.
  t=$((10#$t))
  [[ "$t" -lt 1 ]] && t=$((10#$1))
  [[ "$t" -gt 300 ]] && t=300
  echo "$t"
}

# Runs <cmd...> with a hard bound. with-timeout.mjs kills the whole process group, which is
# what makes the bound real: killing only the direct child leaves grandchildren holding the
# pipe and the command substitution keeps blocking anyway.
_hetero_bounded() {  # _hetero_bounded <secs> <cmd> [args...]
  local secs="$1"; shift
  local wrapper
  wrapper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../bin/with-timeout.mjs"
  if [[ -f "$wrapper" ]] && command -v node >/dev/null 2>&1; then
    # The probed tool's own noise is silenced HERE, not at the call site. Putting
    # `2>/dev/null` on the call swallowed this function's own fail-closed diagnostic too,
    # so the refusal below was invisible and the whole thing degraded silently into
    # "no models available" — a checkpoint that speaks where nobody can hear it.
    node "$wrapper" "$secs" "$@" 2>/dev/null
    return $?
  fi
  # No wrapper: refuse rather than run unbounded. An unbounded probe is the defect.
  echo "hetero: with-timeout.mjs 或 node 不可用 —— 跳过模型探测，不做无超时调用" >&2
  return 69
}

detect_available_models() {
  local opencode_bin="${1:-opencode}" out rc t
  t=$(_hetero_probe_timeout 20)
  # Not a pipeline: piping straight into grep threw away the 69 status, so "node is missing"
  # and "this tool lists no models" became the same observable — and with the diagnostic
  # suppressed as well, the environment defect was completely masked.
  out=$(_hetero_bounded "$t" "$opencode_bin" models); rc=$?
  [[ "$rc" -eq 69 ]] && return 69
  printf '%s\n' "$out" | grep -E '^[a-zA-Z]' | sed 's/[[:space:]]*$//'
}

_probe_model() {
  local model="$1" opencode_bin="${2:-opencode}"
  local raw rc t
  t=$(_hetero_probe_timeout 60)
  raw=$(_hetero_bounded "$t" "$opencode_bin" run --pure -m "$model" --dir "${PWD}" --format json "say OK")
  rc=$?
  # 124 = timed out. Treat as "could not verify", never as available: an unverifiable model
  # recorded as primary is how the config ends up pointing at something unreachable.
  [[ $rc -ne 0 ]] && return 1
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

  local available avail_rc
  available=$(detect_available_models "$opencode_bin"); avail_rc=$?
  if [[ "$avail_rc" -eq 69 ]]; then
    echo "hetero: 模型探测环境不可用（见上）—— review_models 保持原值不刷新" >&2
    return 69
  fi
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

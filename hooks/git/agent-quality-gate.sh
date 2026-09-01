#!/usr/bin/env bash
# Agent Quality Gate — version is stamped at install time (see GATE_VERSION below).
# Only fires when AGENT_MODE=1; human developers pass through.
# Source: https://github.com/mcdowell8023/agent-gates

set -euo pipefail

[[ "${AGENT_MODE:-0}" != "1" ]] && exit 0

# ---------------------------------------------------------------------------
# Gate mode (v2.7.0)
#
# Review had become the bottleneck rather than development — one change went through five
# rounds. The gate applied the same severity to every commit on a feature branch as to a
# merge into test/master, so iteration paid the full price every time.
#
# The model: permissive while iterating, strict at the boundary where work enters an
# integration branch.
#
#   strict   (default)  verdicts enforced — the behaviour up to v2.6.x
#   relaxed             evidence must EXIST and be anchored to this diff, but its verdict is
#                       not enforced. ⚠️ NOT the same as off: "reviewed once, outcome not
#                       enforced" still requires a review to have happened, otherwise the
#                       two modes would be one thing with two names
#   off                 no checks — and it says so loudly, never silently
#
# Resolution order (first hit wins):
#   AGENT_GATES_MODE  →  .agent/gates.json  →  $AGENT_GATES_DIR/gates.json  →  strict
#
# strict_branches: on these branches, and on merges INTO them, strict is forced regardless
# of configuration. That is where "one full review before it reaches test/master" lands.
# ---------------------------------------------------------------------------
_GATE_CFG_PROJECT=".agent/gates.json"
_GATE_CFG_USER="${AGENT_GATES_DIR:-$HOME/.agent-gates}/gates.json"
GATE_MODE_SOURCE=""

# Read a dotted path out of a config file. python3 rather than sed because review.mode /
# verify.mode are nested, and a regex over nested JSON is how you get a value from the wrong
# object.
_gate_cfg_get() {
  [[ -f "$1" ]] || return 1
  local v
  v=$(python3 -c '
import json,sys
try:
    cur = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sys.argv[2].split("."):
    if not isinstance(cur, dict): sys.exit(0)
    cur = cur.get(k)
    if cur is None: sys.exit(0)
print(cur)
' "$1" "$2" 2>/dev/null)
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

_gate_norm_mode() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    strict|relaxed|merge-only|off) printf '%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; return 0 ;;
  esac
  return 1
}

# env > project config > user config > fallback. Used for the overall mode and for the
# per-check overrides, so all three resolve the same way.
_gate_resolve_mode() {   # <env-var-name> <cfg.path> <fallback> -> "<mode>|<source>"
  local envvar="$1" path="$2" fb="$3" raw m
  raw="$(eval "printf '%s' \"\${${envvar}:-}\"")"
  if [[ -n "$raw" ]]; then
    if m=$(_gate_norm_mode "$raw"); then printf '%s|env %s' "$m" "$envvar"; return 0; fi
    echo "⚠️  ${envvar}='${raw}' is not one of strict|relaxed|merge-only|off — ignored" >&2
  fi
  local f
  for f in "$_GATE_CFG_PROJECT" "$_GATE_CFG_USER"; do
    if raw=$(_gate_cfg_get "$f" "$path") && m=$(_gate_norm_mode "$raw"); then
      printf '%s|%s' "$m" "$f"; return 0
    fi
  done
  printf '%s|%s' "$fb" "inherited"
}

_gm=$(_gate_resolve_mode AGENT_GATES_MODE mode strict)
GATE_MODE="${_gm%%|*}"; GATE_MODE_SOURCE="${_gm##*|}"
[[ "$GATE_MODE_SOURCE" == "inherited" ]] && GATE_MODE_SOURCE="default"

# Review (reading the code) and verify (checking it actually runs) are different jobs, so
# they need not share a severity. Unspecified inherits the overall mode.
_grm=$(_gate_resolve_mode AGENT_GATES_REVIEW_MODE review.mode "$GATE_MODE")
GATE_REVIEW_MODE="${_grm%%|*}"; GATE_REVIEW_SOURCE="${_grm##*|}"
_gvm=$(_gate_resolve_mode AGENT_GATES_VERIFY_MODE verify.mode "$GATE_MODE")
GATE_VERIFY_MODE="${_gvm%%|*}"; GATE_VERIFY_SOURCE="${_gvm##*|}"

# strict_branches: project config wins over user config; fall back to the usual integration
# branch names. Patterns are globs, so release/* works.
_gate_strict_branches() {
  local f
  for f in "$_GATE_CFG_PROJECT" "$_GATE_CFG_USER"; do
    [[ -f "$f" ]] || continue
    local out
    out=$(python3 -c '
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
b = d.get("strict_branches")
if isinstance(b, list):
    for x in b:
        if x: print(x)
' "$f" 2>/dev/null)
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  done
  printf '%s' 'test
master
main'
}

_GATE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
_gate_branch_is_strict() {
  local b="${1:-}" pat
  [[ -z "$b" || "$b" == "HEAD" ]] && return 1
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    # Unquoted $pat on purpose — these are globs (release/*).
    [[ "$b" == $pat ]] && return 0
  done <<< "$(_gate_strict_branches)"
  return 1
}

_GATE_ON_STRICT_BRANCH=0
if _gate_branch_is_strict "$_GATE_BRANCH"; then
  _GATE_ON_STRICT_BRANCH=1
  if [[ "$GATE_MODE" != "strict" || "$GATE_REVIEW_MODE" != "strict" || "$GATE_VERIFY_MODE" != "strict" ]]; then
    echo "ℹ️  branch '${_GATE_BRANCH}' is a strict branch — mode forced to strict (config said review=${GATE_REVIEW_MODE}, verify=${GATE_VERIFY_MODE})"
    GATE_MODE="strict"; GATE_MODE_SOURCE="strict_branches override"
    GATE_REVIEW_MODE="strict"; GATE_VERIFY_MODE="strict"
  fi
fi

# A merge used to be skipped unconditionally, which is exactly where a full review is most
# warranted: it is the moment feature work enters an integration branch. Skip only when the
# destination is NOT a strict branch.
if git rev-parse MERGE_HEAD &>/dev/null 2>&1; then
  if [[ "$_GATE_ON_STRICT_BRANCH" -eq 1 ]]; then
    echo "ℹ️  merge into strict branch '${_GATE_BRANCH}' — gate applies (merges are skipped only outside strict branches)"
  else
    exit 0
  fi
fi

if [[ "$GATE_MODE" == "off" ]]; then
  echo "⚠️  Agent Quality Gate: DISABLED by configuration (mode=off, from ${GATE_MODE_SOURCE})"
  echo "   No checks ran. Set \"mode\": \"relaxed\" or \"strict\" in ${_GATE_CFG_PROJECT} or"
  echo "   ${_GATE_CFG_USER} to re-enable, or AGENT_GATES_MODE=strict for one commit."
  exit 0
fi

# Say which mode is in effect whenever it is not the default. A gate that silently changed
# severity would be worse than one that is strict: nobody could tell why a commit passed.
if [[ "$GATE_MODE" != "strict" || "$GATE_REVIEW_MODE" != "strict" || "$GATE_VERIFY_MODE" != "strict" ]]; then
  echo "ℹ️  Agent Quality Gate mode: ${GATE_MODE} (from ${GATE_MODE_SOURCE}) — review=${GATE_REVIEW_MODE}, verify=${GATE_VERIFY_MODE}"
fi

RELAXED_WAIVES=0
# In relaxed mode, "already reviewed but the conclusion is not clean" is waived; "never
# reviewed at all" still blocks. Callers use it as:  relaxed_waive "..." || fail "..."
relaxed_waive() {   # relaxed_waive <message> [review|verify]
  local _which="${2:-}"
  case "$_which" in
    review) [[ "$GATE_REVIEW_MODE" == "relaxed" ]] || return 1 ;;
    verify) [[ "$GATE_VERIFY_MODE" == "relaxed" ]] || return 1 ;;
    *)      [[ "$GATE_MODE" == "relaxed" ]] || return 1 ;;
  esac
  echo "⚠️  GATE (relaxed): $1"
  echo "     Waived because anchored review evidence exists for this change; relaxed mode"
  echo "     does not enforce the verdict. ⛔ This is a relaxed pass, NOT an approval —"
  echo "     merging into a strict branch will require a full review."
  RELAXED_WAIVES=$((RELAXED_WAIVES + 1))
  return 0
}

# Version stamped into THIS copy by install.sh / init-project-gates when copied from
# the repo source (sed replaces the placeholder). Shows "dev" if run from an unstamped
# source tree (repo / tests). This is why the runtime banner no longer hardcodes a
# version — a stale per-project copy now honestly reports the version it was stamped with.
GATE_VERSION="__AGENT_GATES_VERSION__"
[[ "$GATE_VERSION" == *VERSION* ]] && GATE_VERSION="dev"

FAILED=0
fail() { echo "❌ GATE: $1"; FAILED=1; }

DIFF_LINES=$(git diff --cached --stat | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
CHANGED_COUNT=$(git diff --cached --name-only --diff-filter=ACMR | wc -l | tr -d ' ')

NEW_SOURCE=$(git diff --cached --diff-filter=A --name-only \
  | grep -E '\.(ts|tsx|js|jsx|py|java|kt|go)$' \
  | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.|\.setup\.)' || true)

if [[ -z "$NEW_SOURCE" && "$DIFF_LINES" -le 15 && "$CHANGED_COUNT" -le 2 ]]; then
  # v1.5.5: print info so user knows the gate ran and decided to skip
  echo "✅ Agent Quality Gate: trivial change skipped ($CHANGED_COUNT file(s), +${DIFF_LINES} lines)"
  exit 0
fi

echo "🔍 Agent Quality Gate v$GATE_VERSION ($CHANGED_COUNT files, +${DIFF_LINES} lines)"

# === Path detection: A (OpenSpec) vs B ===
IS_PATH_A=0
if [[ -d openspec/changes ]] \
   || [[ -d .opencode/skills/openspec-propose ]] \
   || [[ -d .claude/skills/openspec-propose ]]; then
  IS_PATH_A=1
fi

# === Gate 1: Test file correspondence ===
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.ts|*.tsx|*.js|*.jsx)
      t1="${f%.*}.test.${f##*.}"; t2="${f%.*}.spec.${f##*.}" ;;
    *.py)
      dir=$(dirname "$f"); base=$(basename "$f" .py)
      t1="${dir}/test_${base}.py"; t2="${dir}/${base}_test.py" ;;
    *.java|*.kt)
      t1=$(echo "$f" | sed 's|/main/|/test/|;s|\.\(java\|kt\)$|Test.\1|'); t2="" ;;
    *.go)
      t1="${f%.go}_test.go"; t2="" ;;
    *) continue ;;
  esac

  if [[ ! -f "$t1" ]] && [[ -z "$t2" || ! -f "$t2" ]]; then
    fail "No test for: $f → expected: $t1"
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR \
  | grep -E '\.(ts|tsx|js|jsx|py|java|kt|go)$' \
  | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.|\.d\.ts$|\.setup\.|config)')

# === CHECK 1: OpenSpec active change (Path A only) ===
if [[ "$IS_PATH_A" -eq 1 && -d openspec/changes ]]; then
  ACTIVE_CHANGES=$(find openspec/changes/ -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)
  if [[ -z "$ACTIVE_CHANGES" ]]; then
    fail "Path A project has openspec/changes/ but no active change directory"
    echo "   Fix: Run opsx:propose to create a change, or mkdir openspec/changes/<name>/"
  fi
fi

# === CHECK 2: BDD .feature exists (Path A required; Path B skipped) ===
if [[ "$IS_PATH_A" -eq 1 && -n "$NEW_SOURCE" ]]; then
  FEATURE_COUNT=0
  if [[ -d features ]]; then
    FEATURE_COUNT=$(find features -maxdepth 2 -type f -name '*.feature' 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [[ "$FEATURE_COUNT" -eq 0 ]]; then
    fail "Path A project has new source files but no features/*.feature scenarios"
    echo "   Fix: Create BDD scenarios in features/<name>.feature before committing"
  fi
fi

# === Pre-compute change metrics (shared by CHECK 3 + Gate 2) ===
LOGIC_FILES=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  LOGIC_FILES=$((LOGIC_FILES + 1))
done < <(git diff --cached --name-only --diff-filter=ACMR \
  | grep -vE '(\.(lock|md|json|yaml|yml)$|generated/|migrations/|\.d\.ts$)' \
  | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.)')

MAX_SINGLE_FILE_LINES=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  flines=$(git diff --cached -- "$f" | grep -c '^+[^+]' 2>/dev/null || echo "0")
  [[ "$flines" -gt "$MAX_SINGLE_FILE_LINES" ]] && MAX_SINGLE_FILE_LINES="$flines"
done < <(git diff --cached --name-only --diff-filter=ACMR \
  | grep -vE '(\.(lock|md|json|yaml|yml)$|generated/|migrations/|\.d\.ts$)' \
  | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.)')

# === CHECK 3: Plan/design decision (v1.11.0 三态方案门控) ===
# Non-trivial code changes require either:
#   - A plan with PLAN_REVIEW markers (requires-plan / L1+ machines)
#   - A plan exists (L0 machines — no marker required)
#   - A command-generated .skip.md with GENERATED_BY (skip-with-approval)
# Trivial changes (handled by gate top) skip entirely.
if [[ "${SKIP_PLAN_CHECK:-0}" != "1" ]] && [[ -d .agent/plans ]]; then
  PLAN_NEEDED=0
  [[ -n "$NEW_SOURCE" ]] && PLAN_NEEDED=1
  [[ "$LOGIC_FILES" -gt 1 && "$DIFF_LINES" -gt 50 ]] && PLAN_NEEDED=1
  [[ "$MAX_SINGLE_FILE_LINES" -gt 150 ]] && PLAN_NEEDED=1

  if [[ "$PLAN_NEEDED" -eq 1 ]]; then
    PLAN_FOUND=0
    PLAN_REVIEWED=0
    SKIP_APPROVED=0

    # Dangerous-category detection (requires-plan, skip NOT accepted)
    DANGEROUS=0
    while IFS= read -r df; do
      [[ -z "$df" ]] && continue
      if echo "$df" | grep -qiE 'migration|\.sql$|auth|security|permission|acl|schema'; then
        DANGEROUS=1; break
      fi
    done < <(git diff --cached --name-only --diff-filter=ACMR)

    # Check for reviewed plans (带 PLAN_REVIEW 三件套)
    while IFS= read -r pf; do
      [[ -z "$pf" || ! -f "$pf" ]] && continue
      PLAN_FOUND=1
      if grep -q 'PLAN_REVIEW:' "$pf" && grep -q 'PLAN_REVIEW_TOOL:' "$pf" && grep -q 'PLAN_REVIEW_MODEL:' "$pf"; then
        PLAN_REVIEWED=1
        break
      fi
    done < <(find .agent/plans/ -maxdepth 1 -name '*.md' ! -name '*.skip.md' 2>/dev/null)

    # Check for approved skip (.skip.md with GENERATED_BY)
    while IFS= read -r sf; do
      [[ -z "$sf" || ! -f "$sf" ]] && continue
      if grep -q 'GENERATED_BY: agent-gates' "$sf" \
         && grep -q 'TIMESTAMP:' "$sf" \
         && grep -q 'BRANCH:' "$sf" \
         && grep -q 'HEAD:' "$sf" \
         && grep -q 'REASON:' "$sf"; then
        SKIP_APPROVED=1
        break
      fi
    done < <(find .agent/plans/ -maxdepth 1 -name '*.skip.md' 2>/dev/null)

    if [[ "$DANGEROUS" -eq 1 && "$SKIP_APPROVED" -eq 1 && "$PLAN_REVIEWED" -ne 1 ]]; then
      fail "Dangerous change (auth/security/migration/schema) requires a reviewed plan — skip not accepted"
      echo "   Fix: write .agent/plans/<topic>.md + run agent-gates-review --plan <plan>"
    elif [[ "$SKIP_APPROVED" -eq 1 ]]; then
      : # skip-with-approval — decision recorded, pass (non-dangerous only)
    elif [[ "$PLAN_REVIEWED" -eq 1 ]]; then
      : # reviewed plan found, pass
    elif [[ "$PLAN_FOUND" -eq 1 ]]; then
      # Plan exists but no PLAN_REVIEW markers — check capability level
      PLAN_CAP_LEVEL="L0"
      PLAN_CAP_FILE="${AGENT_GATES_DIR:-$HOME/.agent-gates}/review-capability.json"
      if [[ -f "$PLAN_CAP_FILE" ]]; then
        PLAN_CAP_LEVEL=$(grep -oE '"level"[[:space:]]*:[[:space:]]*"L[0-3]"' "$PLAN_CAP_FILE" 2>/dev/null | grep -oE 'L[0-3]' | head -1 || echo "L0")
      fi
      if [[ "$PLAN_CAP_LEVEL" == "L0" ]]; then
        echo "⚠️  CHECK 3: L0 — plan exists but no PLAN_REVIEW markers (no heterogeneous tool to verify)"
      else
        fail "Plan exists but missing PLAN_REVIEW markers (machine is $PLAN_CAP_LEVEL — heterogeneous review required)"
        echo "   Fix: run agent-gates-review --plan .agent/plans/<your-plan>.md"
      fi
    else
      fail "Non-trivial change but no plan or approved skip in .agent/plans/"
      echo "   Fix: write a plan to .agent/plans/<topic>.md + run agent-gates-review --plan <plan>"
      echo "   Or: agent-gates-plan-decision skip --reason \"<reason>\" --topic <name>"
    fi
  fi
fi

# === Gate 2: Cross-review evidence ===
# (LOGIC_FILES / MAX_SINGLE_FILE_LINES already computed above for CHECK 3)
# Trigger: (multi-file AND substantial change) OR single-file massive change
NEEDS_REVIEW=0
[[ "$LOGIC_FILES" -gt 1 && "$DIFF_LINES" -gt 50 ]] && NEEDS_REVIEW=1
[[ "$MAX_SINGLE_FILE_LINES" -gt 150 ]] && NEEDS_REVIEW=1

# merge-only defers review entirely to the moment work enters an integration branch.
# ⚠️ It relaxes review only — Gate 1 (a test file must exist) and CHECK 3 (a plan) are
# discipline at the time code is written, unrelated to when it gets reviewed.
if [[ "$NEEDS_REVIEW" -eq 1 && "$GATE_REVIEW_MODE" == "merge-only" ]]; then
  echo "ℹ️  CHECK 5 skipped: review mode is merge-only — deferred until this work merges into a strict branch (${_GATE_BRANCH:-?} is not one)"
  NEEDS_REVIEW=0
fi

if [[ "$NEEDS_REVIEW" -eq 1 ]]; then
  if [[ -d .agent && ! -d .agent/reviews ]]; then
    fail "Project has .agent/ but missing .agent/reviews/ directory"
    echo "   Fix: mkdir -p .agent/reviews"
  elif [[ -d .agent/reviews ]]; then
    gate_sha256_stream() {
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
      else
        shasum -a 256 | awk '{print $1}'
      fi
    }

    CURRENT_REVIEW_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    CURRENT_REVIEW_FILES=$(git -c core.quotePath=true diff --cached --name-only --diff-filter=ACMRD -- \
      . \
      ':(exclude).agent/reviews/**' \
      ':(exclude).agent/verify/**' \
      ':(exclude).agent/plans/**')
    CURRENT_REVIEW_DIFF_SHA256=$(git diff --cached --binary -- \
      . \
      ':(exclude).agent/reviews/**' \
      ':(exclude).agent/verify/**' \
      ':(exclude).agent/plans/**' \
      | gate_sha256_stream)

    ANCHORED_REVIEW_COUNT=0
    HEAD_MATCH_COUNT=0
    COVERING_REVIEW_COUNT=0
    PASS_REVIEW_FILE=""
    NEGATIVE_REVIEW_FILE=""
    REVIEW_DIFF_MATCH=0

    while IFS= read -r rf; do
      [[ -z "$rf" || ! -f "$rf" ]] && continue

      rf_head=$(sed -n 's/^<!-- REVIEW_HEAD: \(.*\) -->$/\1/p' "$rf" | head -1)
      [[ -n "$rf_head" ]] || continue
      ANCHORED_REVIEW_COUNT=$((ANCHORED_REVIEW_COUNT + 1))

      rf_files=$(sed -n 's/^<!-- REVIEW_FILE: \(.*\) -->$/\1/p' "$rf")
      # `[[:space:]-]*` after the hex, not a single space: `shasum` reading stdin prints
      # `<hex>  -` (that trailing `-` is a filename placeholder), and pasted into an anchor
      # it became `<!-- REVIEW_FILES_SHA256: <hex>  - -->`. Requiring ` -->` immediately
      # after the hex made that not match ⇒ empty variable ⇒ the `|| continue` below
      # skipped the ENTIRE report, with the most misleading symptom possible: report
      # present, VERDICT: PASS present, hex correct, and the gate reporting no review at
      # all (observed 2026-08-24). Non-hex content still fails to match — this widens what
      # may follow the hex, not what counts as one.
      rf_files_sha256=$(sed -n 's/^<!-- REVIEW_FILES_SHA256: \([0-9a-fA-F]*\)[[:space:]-]*-->$/\1/p' "$rf" | head -1 | tr '[:upper:]' '[:lower:]')
      rf_diff_sha256=$(sed -n 's/^<!-- REVIEW_DIFF_SHA256: \([0-9a-fA-F]*\)[[:space:]-]*-->$/\1/p' "$rf" | head -1 | tr '[:upper:]' '[:lower:]')
      [[ -n "$rf_files" && -n "$rf_files_sha256" && -n "$rf_diff_sha256" ]] || continue

      computed_files_sha256=$(printf '%s\n' "$rf_files" | gate_sha256_stream)
      [[ "$computed_files_sha256" == "$rf_files_sha256" ]] || continue
      [[ "$rf_head" == "$CURRENT_REVIEW_HEAD" ]] || continue
      HEAD_MATCH_COUNT=$((HEAD_MATCH_COUNT + 1))

      review_covers_current=1
      while IFS= read -r current_file; do
        [[ -z "$current_file" ]] && continue
        if ! grep -Fqx -- "$current_file" <<< "$rf_files"; then
          review_covers_current=0
          break
        fi
      done <<< "$CURRENT_REVIEW_FILES"
      [[ "$review_covers_current" -eq 1 ]] || continue
      COVERING_REVIEW_COUNT=$((COVERING_REVIEW_COUNT + 1))

      if grep -qiE '^VERDICT:[[:space:]]*(ISSUES|FAIL|REJECT)' "$rf"; then
        NEGATIVE_REVIEW_FILE="$rf"
      elif grep -qiE '^VERDICT:[[:space:]]*(PASS|APPROVED)' "$rf"; then
        if [[ "$rf_diff_sha256" == "$CURRENT_REVIEW_DIFF_SHA256" ]]; then
          PASS_REVIEW_FILE="$rf"
          REVIEW_DIFF_MATCH=1
        elif [[ -z "$PASS_REVIEW_FILE" ]]; then
          PASS_REVIEW_FILE="$rf"
        fi
      fi
    done < <(find .agent/reviews/ -type f -name "*.md" -print 2>/dev/null | sort)

    REVIEW_FILE="$PASS_REVIEW_FILE"
    if [[ -n "$NEGATIVE_REVIEW_FILE" ]]; then
      if relaxed_waive "review verdict is ISSUES/FAIL ($NEGATIVE_REVIEW_FILE)" review; then
        :
      else
      fail "Applicable review verdict is ISSUES/FAIL — resolve before committing"
      echo "   Review: $NEGATIVE_REVIEW_FILE"
      fi
    elif [[ -z "$PASS_REVIEW_FILE" ]]; then
      if [[ "$ANCHORED_REVIEW_COUNT" -eq 0 ]]; then
        fail "No content-anchored review evidence covers the staged change"
        echo "   Legacy review files without REVIEW_HEAD/REVIEW_FILE anchors are historical only; filesystem mtime is ignored."
        echo "   Fix: Run cross-review with the current agent-gates-review command."
      elif [[ "$HEAD_MATCH_COUNT" -eq 0 ]]; then
        fail "Review HEAD does not match current HEAD ($CURRENT_REVIEW_HEAD)"
        echo "   Fix: Re-run cross-review on the current base commit."
      elif [[ "$COVERING_REVIEW_COUNT" -eq 0 ]]; then
        fail "Staged file set is not covered by any review's REVIEW_FILE list"
        echo "   Unreviewed staged files are not allowed. Current staged files:"
        while IFS= read -r current_file; do
          [[ -n "$current_file" ]] && echo "     - $current_file"
        done <<< "$CURRENT_REVIEW_FILES"
      else
        fail "Content-anchored review is missing an explicit PASS/APPROVED verdict"
      fi
    else
      if [[ "$REVIEW_DIFF_MATCH" -ne 1 ]]; then
        echo "⚠️  GATE WARNING: reviewed files changed after cross-review; explicit confirmation is required by continuing this commit."
        echo "   No unreviewed files were added. Inspect the staged diff summary:"
        git diff --cached --stat -- \
          . \
          ':(exclude).agent/reviews/**' \
          ':(exclude).agent/verify/**' \
          ':(exclude).agent/plans/**'
      fi

      # === Gate 2b (v1.7.0): heterogeneous-review enforcement ===
      if [[ "${SKIP_HETERO_CHECK:-0}" != "1" ]]; then
        HETERO_DIR="${AGENT_GATES_DIR:-$HOME/.agent-gates}"
        if [[ -f "$HETERO_DIR/hetero-check.json" ]]; then
          CAP_FILE="$HETERO_DIR/hetero-check.json"
        else
          CAP_FILE="$HETERO_DIR/review-capability.json"
        fi
        if [[ -f "$CAP_FILE" ]]; then
          CAP_LEVEL=$(grep -oE '"level"[[:space:]]*:[[:space:]]*"L[0-3]"' "$CAP_FILE" 2>/dev/null | grep -oE 'L[0-3]' | head -1 || true)
          if [[ "$CAP_LEVEL" == "L1" || "$CAP_LEVEL" == "L2" || "$CAP_LEVEL" == "L3" ]]; then
            RLEVEL=$(grep -oE 'REVIEW_LEVEL:[[:space:]]*L[0-3]' "$REVIEW_FILE" 2>/dev/null | grep -oE 'L[0-3]' | head -1 || true)
            if [[ -z "$RLEVEL" ]]; then
              fail "Review has no REVIEW_LEVEL marker, but this machine supports heterogeneous review ($CAP_LEVEL)"
              echo "   Same-model review does NOT satisfy the different-model requirement."
              echo "   Fix: run cross-review via a DIFFERENT model, then add <!-- REVIEW_LEVEL: L1 --> (or higher)."
            elif [[ "$RLEVEL" == "L0" ]]; then
              if grep -q '<!-- HETERO_EXHAUSTED:' "$REVIEW_FILE" 2>/dev/null; then
                echo "⚠️  Gate 2b: HETERO_EXHAUSTED — all heterogeneous review models failed; degrading to warn"
              else
                fail "Review is same-model (REVIEW_LEVEL: L0) but machine supports heterogeneous ($CAP_LEVEL)"
                echo "   Fix: re-run cross-review via a different model."
              fi
            fi
          fi
        fi
      fi
    fi
  elif [[ ! -d .agent ]]; then
    echo "⚠️  No .agent/ directory — cross-review check skipped (run init-project-gates)."
  fi
fi

# === CHECK 6: Verifier 验收 (v2.0.0) ===
# Triggered when change is substantial (mirrors CHECK 5 thresholds) or touches a
# high-risk path (shared is_high_risk_path helper from lib/hetero/select.sh §3.2).
# Reads VERIFY_VERDICT from .agent/verify/<date>-<topic>.md (directory isolated from
# .agent/reviews/ used by CHECK 5). High-risk + EVIDENCE_ONLY capability downgrades
# PASS to INCOMPLETE requiring USER_ACK (§5.3 required_capability).
# Say exactly how to proceed. The old text ("confirm via workflow") named no command, so
# every agent had to reconstruct the mechanism and explain it to the user before anyone
# could move — turning a 10-second decision into a multi-message detour.
_v6_ack_help() {
  local run_id="$1" verdict="$2"
  echo ""
  echo "   This is not a failed check. The verifier could not finish, and only you can decide"
  echo "   whether that is acceptable. To approve proceeding:"
  echo ""
  echo "     ~/.agent-gates/bin/agent-gates-verify-ack ${run_id}"
  echo ""
  echo "   Valid 4h, bound to the current staged diff and HEAD — do not restage between"
  echo "   signing and committing, or the ACK stops matching."
  if [[ "$verdict" == "INCOMPLETE" ]]; then
    echo ""
    echo "   NOTE: INCOMPLETE is often ordering, not an omission — end-to-end testing needs a"
    echo "   deployment, the deployment needs this commit, and this commit needs the verify."
    echo "   Nobody can work out of that loop by trying harder. Approving is the intended way"
    echo "   out: commit, run the end-to-end straight after, and record that it is still open."
  fi
  echo ""
  echo "   An agent may run that command once you have explicitly approved. The gate records"
  echo "   no signer identity, so restricting it to humans never bought any safety — what does"
  echo "   matter is that the report says plainly this was an authorized override, not a pass."
  echo "   Blunter equivalent, same approval required: SKIP_VERIFY=1 git commit ..."
}

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
  NEEDS_VERIFY=0
  [[ "$LOGIC_FILES" -gt 1 && "$DIFF_LINES" -gt 50 ]] && NEEDS_VERIFY=1
  [[ "$MAX_SINGLE_FILE_LINES" -gt 150 ]] && NEEDS_VERIFY=1

  # Source shared high-risk helper located relative to this script (BASH_SOURCE[0])
  IS_HIGH_RISK=0
  _GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _VERIFY_SELECT_SH="$_GATE_DIR/../../lib/hetero/select.sh"
  if [[ -f "$_VERIFY_SELECT_SH" ]]; then
    # shellcheck disable=SC1090
    source "$_VERIFY_SELECT_SH"
    _VERIFY_HR=$(is_high_risk_path 2>/dev/null || echo "0")
    if [[ "$_VERIFY_HR" == "1" ]]; then
      IS_HIGH_RISK=1
      NEEDS_VERIFY=1
    fi
  fi

  if [[ "$NEEDS_VERIFY" -eq 1 && "$GATE_VERIFY_MODE" == "merge-only" ]]; then
    echo "ℹ️  CHECK 6 skipped: verify mode is merge-only — deferred until this work merges into a strict branch (${_GATE_BRANCH:-?} is not one)"
    NEEDS_VERIFY=0
  fi

  if [[ "$NEEDS_VERIFY" -eq 1 ]]; then
    if [[ -d .agent && ! -d .agent/verify ]]; then
      fail "No verifier evidence (.agent/verify/ missing)"
      echo "   Fix: Run verifier agent, save output to .agent/verify/<date>-<topic>.md"
    elif [[ -d .agent/verify ]]; then
      # Prefer the verify doc whose dispatch record binds the CURRENT staged diff; fall
      # back to newest-by-mtime only when nothing is anchored.
      #
      # mtime alone is not enough: `git worktree add` stamps every file with the same
      # mtime, so in a fresh worktree ALL historical verify docs land inside the -mmin
      # window with IDENTICAL mtimes, and "newest" under a strict `>` degenerates into
      # "whichever find happened to return first". Observed 2026-08-24 in a fresh
      # worktree: 38 docs all at the creation timestamp, the gate picked an unrelated one
      # from three weeks earlier, and reported it as missing a VERIFY_VERDICT line — an
      # error naming a file the agent had never seen, which reads as "my artifact was
      # never generated". CHECK 5 already anchors on the diff hash; do the same here.
      VERIFY_FILE=""
      VERIFY_NEWEST_MTIME=0
      VERIFY_ANCHORED=""
      _V6_CAND=0          # candidates in the window
      _V6_DECIDABLE=0     # candidates carrying a dispatch.json (i.e. anchorable)
      _V6_MTIME_SET=""    # distinct mtimes seen, to detect the fresh-worktree shape
      if command -v sha256sum >/dev/null 2>&1; then
        _V6_CUR_HASH=$(git diff --cached -- ':!.agent/verify' 2>/dev/null | sha256sum | cut -d' ' -f1)
      else
        _V6_CUR_HASH=$(git diff --cached -- ':!.agent/verify' 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
      fi
      while IFS= read -r vf; do
        [[ -z "$vf" || ! -f "$vf" ]] && continue
        _V6_CAND=$((_V6_CAND+1))
        # "Decidable" requires an actual staged_diff_hash, not merely the presence of a
        # dispatch record. Records carrying only channel/capability (older artifacts, and
        # every fixture in run_gate.sh) cannot be anchored either way, so counting them as
        # decidable would turn "no hash to compare" into "verified nothing" and reject
        # perfectly valid setups — it broke 16 assertions when written that way.
        _v6_dj=".agent/verify/$(basename "$vf" .md).dispatch.json"
        if [[ -f "$_v6_dj" ]]; then
          _v6_h=$(sed -n 's/.*"staged_diff_hash"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p' "$_v6_dj" 2>/dev/null | head -1)
          if [[ -n "$_v6_h" ]]; then
            _V6_DECIDABLE=$((_V6_DECIDABLE+1))
            [[ -n "$_V6_CUR_HASH" && "$_v6_h" == "$_V6_CUR_HASH" ]] && VERIFY_ANCHORED="$vf"
          fi
        fi
        vf_mtime=$(stat -f %m "$vf" 2>/dev/null || stat -c %Y "$vf" 2>/dev/null || echo "0")
        case " $_V6_MTIME_SET " in *" $vf_mtime "*) ;; *) _V6_MTIME_SET="$_V6_MTIME_SET $vf_mtime" ;; esac
        if [[ "$vf_mtime" -gt "$VERIFY_NEWEST_MTIME" ]]; then
          VERIFY_NEWEST_MTIME="$vf_mtime"
          VERIFY_FILE="$vf"
        fi
      done < <(find .agent/verify/ -name "*.md" -mmin -240 2>/dev/null)

      if [[ -n "$VERIFY_ANCHORED" ]]; then
        # Deterministic: this document's dispatch record binds exactly the staged diff.
        VERIFY_FILE="$VERIFY_ANCHORED"
      elif [[ "$_V6_DECIDABLE" -gt 0 ]]; then
        # Anchorable candidates exist and NONE matches ⇒ there is simply no verify for this
        # change. Falling back to mtime here is what produced the misleading
        # "Significant changes (N lines) made AFTER verification": in a fresh worktree
        # `git worktree add` stamps every doc with the same mtime, so the fallback picked an
        # unrelated task's old PASS at random (find order) and compared line counts against
        # it. Reported 2026-08-26: 28 docs, one single mtime, 23 anchorable, 0 matching.
        # "Cannot prove a verify exists for this diff" must not read as "you changed too much".
        _v6_distinct=$(printf '%s' "$_V6_MTIME_SET" | wc -w | tr -d ' ')
        fail "No verifier evidence anchored to the current staged diff — verify this change"
        echo "   Looked at $_V6_CAND verify doc(s) in .agent/verify/ within the 4h window;"
        echo "   $_V6_DECIDABLE carry a dispatch record and none binds the current staged diff."
        if [[ "$_V6_CAND" -gt 1 && "$_v6_distinct" -le 1 ]]; then
          echo "   ⚠️  All $_V6_CAND share one mtime — typical of a fresh \`git worktree add\`,"
          echo "       so \"newest by mtime\" would have been an arbitrary pick. Not guessing."
        fi
        echo "   Fix: run the verifier against THIS change so its dispatch record binds"
        echo "        the current staged diff. Pre-existing docs from other tasks do not count."
        VERIFY_FILE=""
        VERIFY_VERDICT="__NO_ANCHOR__"   # skip the verdict/staleness checks below
      fi
      # else: nothing anchorable at all (legacy docs without dispatch records) — the mtime
      # pick above stands, which is the only signal available.

      if [[ "${VERIFY_VERDICT:-}" == "__NO_ANCHOR__" ]]; then
        : # already reported above with full diagnostics
      elif [[ -z "$VERIFY_FILE" ]]; then
        fail "Verifier evidence missing or stale (>4h old)"
        echo "   Fix: Run verifier agent, save to .agent/verify/\$(date +%Y-%m-%d)-<topic>.md"
      else
        VERIFY_VERDICT=$(grep -oiE '^VERIFY_VERDICT:[[:space:]]*(PASS|FAIL|QUESTIONS|INCOMPLETE)' \
          "$VERIFY_FILE" 2>/dev/null \
          | grep -oiE 'PASS|FAIL|QUESTIONS|INCOMPLETE' | head -1 | tr '[:lower:]' '[:upper:]' \
          || echo "")

        if [[ -z "$VERIFY_VERDICT" ]]; then
          fail "Verifier file missing VERIFY_VERDICT line: $VERIFY_FILE"
          echo "   Fix: Add 'VERIFY_VERDICT: PASS' (or FAIL/QUESTIONS/INCOMPLETE) to the file"
        else
          VERIFY_RUN_ID=$(basename "$VERIFY_FILE" .md)
          DISPATCH_FILE=".agent/verify/${VERIFY_RUN_ID}.dispatch.json"
          VERIFY_CAP=""
          if [[ -f "$DISPATCH_FILE" ]]; then
            VERIFY_CAP=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('capability', ''))
except Exception:
    pass
" "$DISPATCH_FILE" 2>/dev/null || echo "")
          else
            fail "No dispatch artifact for verify run $VERIFY_RUN_ID"
          fi

          # High-risk + EVIDENCE_ONLY: downgrade PASS to INCOMPLETE (§5.3 required_capability)
          if [[ "$IS_HIGH_RISK" -eq 1 && "$VERIFY_CAP" == "EVIDENCE_ONLY" && "$VERIFY_VERDICT" == "PASS" ]]; then
            VERIFY_VERDICT="INCOMPLETE"
            echo "⚠️  CHECK 6: high-risk path + EVIDENCE_ONLY capability — downgraded to INCOMPLETE (needs USER_ACK)"
          fi

          # === Requirement matrix — the omission detector (v2.9.0) ===
          #
          # WHY: a feature that was never built leaves no trace in the diff. CHECK 5 reads
          # the diff, sees only correct code, and passes. The implementer's own tests are
          # just as blind — it did not build the thing, so it did not write the test.
          # "All green" and "half the requirement missing" coexist happily. Every checklist
          # derived from CODE is structurally blind to omission; only one derived from the
          # REQUIREMENT can catch it.
          #
          # WHEN it is enforced (verify.require_matrix, default "auto"):
          #   auto   on a strict branch, AND a requirement source with an acceptance section
          #          actually exists (or the matrix is already there). Otherwise: a loud
          #          notice, no block.
          #   true   always enforce
          #   false  never enforce
          #
          # `auto` exists because the first cut keyed enforcement off the strict branch alone
          # and broke 12 pre-existing gate tests on the spot — every fixture that commits on
          # master with an old-style verify doc. Those fixtures mirror real deployed repos,
          # so shipping it would have meant "every master commit fails until you hand-write a
          # new artifact", and the predictable response to that is mode:off. Tying the demand
          # to the presence of its own input makes the rollout self-paced: writing a
          # "## 验收标准" section is what opts a repo in.
          #
          # On a feature branch a present matrix is still parsed and its findings printed:
          # free signal, no blocking, because a partial requirement is normal there.
          _V6_RM_LIB="$_GATE_DIR/../../lib/verify/reqmatrix.sh"
          _V6_HAS_MATRIX=0
          grep -qE '^REQ_ITEM:' "$VERIFY_FILE" 2>/dev/null && _V6_HAS_MATRIX=1

          if [[ -f "$_V6_RM_LIB" ]]; then
            # shellcheck disable=SC1090
            source "$_V6_RM_LIB"

            # Requirement sources = docs that actually yield acceptance items. A plan full of
            # implementation-step checkboxes does not count; refusing to number those was the
            # whole point (they are tasks, not requirements, and counting them fails for noise).
            #
            # One grep narrows the candidates before any python starts. This runs on EVERY
            # commit, and a repo with 50 plans would otherwise pay 50 interpreter startups —
            # about a second and a half added to every `git commit`, which is how a hook earns
            # a --no-verify habit.
            _v6_req_sources() {
              local f
              while IFS= read -r f; do
                [[ -n "$f" && -f "$f" ]] || continue
                case "$f" in *.skip.md) continue ;; esac
                reqmatrix_extract_items "$f" >/dev/null 2>&1 && echo "$f"
              done < <(
                grep -lE '^#{2,6}[[:space:]]*(验收标准|验收清单|验收条件|Acceptance([[:space:]]+Criteria)?|验收)[[:space:]]*$' \
                  .agent/plans/*.md 2>/dev/null || true
                find features -type f -name '*.feature' 2>/dev/null || true
              )
              return 0
            }
            # Discovery is lazy: with a matrix already present and an explicit REQ_SOURCE,
            # nothing here is needed.
            #
            # ⚠️ Every assignment needs `|| true`. The gate runs under `set -euo pipefail`, and
            # `X=$(cmd)` exits the script when cmd fails — with pipefail an empty list makes
            # `grep -v` return 1 and takes the pipeline with it. That killed the gate silently
            # right after its banner: no message, exit 1, and 16 unrelated tests failed with
            # "expected exit 0" while the output looked perfectly clean.
            _V6_SRC_LIST=""; _V6_DISCOVERED_SRC=""; _V6_SRC_COUNT=0; _V6_DISCOVERED=0
            _v6_discover_sources() {
              [[ "$_V6_DISCOVERED" -eq 1 ]] && return 0
              _V6_DISCOVERED=1
              _V6_SRC_LIST=$(_v6_req_sources || true)
              _V6_DISCOVERED_SRC=$(printf '%s\n' "$_V6_SRC_LIST" | grep -v '^$' | head -1 || true)
              _V6_SRC_COUNT=$(printf '%s\n' "$_V6_SRC_LIST" | grep -c '[^[:space:]]' || true)
              [[ "$_V6_SRC_COUNT" =~ ^[0-9]+$ ]] || _V6_SRC_COUNT=0
              return 0
            }

            _V6_RM_CFG=""
            for _v6_f in ".agent/gates.json" "${AGENT_GATES_DIR:-$HOME/.agent-gates}/gates.json"; do
              _v6_raw=$(_gate_cfg_get "$_v6_f" "verify.require_matrix" 2>/dev/null || true)
              if [[ -n "$_v6_raw" ]]; then _V6_RM_CFG="$_v6_raw"; break; fi
            done
            _V6_MATRIX_REQUIRED=0
            case "$(printf '%s' "$_V6_RM_CFG" | tr '[:upper:]' '[:lower:]')" in
              true|1|yes) _V6_MATRIX_REQUIRED=1 ;;
              false|0|no) _V6_MATRIX_REQUIRED=0 ;;
              *)  # auto
                if [[ "$_GATE_ON_STRICT_BRANCH" -eq 1 ]]; then
                  [[ "$_V6_HAS_MATRIX" -eq 1 ]] || _v6_discover_sources
                  if [[ "$_V6_HAS_MATRIX" -eq 1 || -n "$_V6_DISCOVERED_SRC" ]]; then
                    _V6_MATRIX_REQUIRED=1
                  else
                    echo "ℹ️  CHECK 6: 未启用需求遗漏检查 —— 找不到带 '## 验收标准' 章节的需求文档"
                    echo "      漏做的功能在 diff 里不留痕迹，代码审查和实现者自己写的测试都抓不到。"
                    echo "      要启用：在 .agent/plans/<需求>.md 加 '## 验收标准' 章节逐条列出需求，"
                    echo "      或设 verify.require_matrix=true 强制要求。"
                  fi
                fi
                ;;
            esac
            [[ "$GATE_VERIFY_MODE" == "off" ]] && _V6_MATRIX_REQUIRED=0

            if [[ "$_V6_MATRIX_REQUIRED" -eq 1 || "$_V6_HAS_MATRIX" -eq 1 ]]; then
              # Findings block only where the matrix is required. Elsewhere they are printed
              # and the commit proceeds — an unfinished requirement on a feature branch is
              # the normal state, and failing there is how a gate gets bypassed.
              _rm_problem() {
                if [[ "$_V6_MATRIX_REQUIRED" -eq 1 ]]; then
                  fail "$1"
                else
                  echo "ℹ️  CHECK 6 需求矩阵（不阻断，当前分支非 strict）: $1"
                fi
                [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/   /'
              }

              if [[ "$_V6_HAS_MATRIX" -eq 0 ]]; then
                _v6_discover_sources
                _rm_problem "验收产物没有需求矩阵 — 无法判断需求是否有遗漏" \
"需求源: ${_V6_DISCOVERED_SRC:-<未找到>}
每条需求一行，格式：
  REQ_SOURCE: ${_V6_DISCOVERED_SRC:-.agent/plans/<需求文档>.md}
  REQ_ITEM: 1 | COVERED | ui:src/X.vue:88, api:src/y.ts:12 | 说明
状态: COVERED / PREEXISTING / PARTIAL / DEFERRED / NA / MISSING
证据路径不带 ~ 表示本次改动、带 ~ 表示既有未改（如 ui:~src/X.vue:88）
⛔ 不要手写 —— 用 ~/.agent-gates/bin/agent-gates-verify-harvest 生成骨架"
              else
                _V6_RM_SRC=$(sed -n 's/^REQ_SOURCE:[[:space:]]*//p' "$VERIFY_FILE" 2>/dev/null | head -1 | tr -d '\r' || true)
                # No explicit REQ_SOURCE: fall back to the discovered one, but only when it
                # is unambiguous. Guessing among several plans would produce a count mismatch
                # against a document nobody was verifying against — a false failure naming a
                # file the agent never saw, which reads as "my artifact was ignored".
                if [[ -z "$_V6_RM_SRC" ]]; then
                  _v6_discover_sources
                fi
                if [[ -z "$_V6_RM_SRC" && -n "$_V6_DISCOVERED_SRC" ]]; then
                  if [[ "${_V6_SRC_COUNT:-0}" -eq 1 ]]; then
                    _V6_RM_SRC="$_V6_DISCOVERED_SRC"
                    echo "   需求源未显式声明，采用唯一候选: $_V6_RM_SRC"
                  fi
                fi

                if ! _v6_out=$(reqmatrix_parse "$VERIFY_FILE" 2>&1 >/dev/null); then
                  _rm_problem "需求矩阵格式错误" "$_v6_out"
                else
                  # E1 — the count comes from the requirement source. This is the one
                  # mechanism the model has no say in: it fills a disposition per item but
                  # cannot decide how many items exist.
                  if [[ -n "$_V6_RM_SRC" && -f "$_V6_RM_SRC" ]]; then
                    if ! _v6_out=$(reqmatrix_check_count "$VERIFY_FILE" "$_V6_RM_SRC" 2>&1 >/dev/null); then
                      _rm_problem "需求条目数与需求源不符 — 有条目被静默丢掉" "$_v6_out"
                    fi
                  else
                    # bad-source tier: an explicitly named source that cannot be read must be
                    # an error, not a downgrade to "warn". A downgrade here is a bypass:
                    # point REQ_SOURCE at anything unparseable and the count check vanishes.
                    if [[ -n "$_V6_RM_SRC" ]]; then
                      _rm_problem "REQ_SOURCE 指向的文件读不到: $_V6_RM_SRC"
                    else
                      _rm_problem "矩阵没有 REQ_SOURCE — 条目数无从核对" \
"补一行 REQ_SOURCE: <需求文档路径>，文档里要有 '## 验收标准' 章节或 Gherkin Scenario"
                    fi
                  fi

                  # E2 — recompute the item-block hash. The field was being WRITTEN by
                  # harvest and read by nobody, which made it decoration: an independent
                  # review swapped in `REQ_BLOCK_SHA256: deadbeef` and the gate still
                  # passed. Worse, the staged-diff anchor deliberately excludes
                  # .agent/verify, so editing the requirement doc after verification does
                  # not break that anchor either — this is the only line of defence, and it
                  # was not connected. (Same shape as the `signed_by` field this project
                  # already got caught on once.)
                  #
                  # The count check does not cover it: REWORDING an item keeps the count
                  # identical while changing what was agreed.
                  if [[ -n "$_V6_RM_SRC" && -f "$_V6_RM_SRC" ]]; then
                    _v6_declared_hash=$(sed -n 's/^REQ_BLOCK_SHA256:[[:space:]]*//p' "$VERIFY_FILE" 2>/dev/null | head -1 | tr -d '\r' || true)
                    if [[ -n "$_v6_declared_hash" ]]; then
                      _v6_actual_hash=$(reqmatrix_block_hash "$_V6_RM_SRC" 2>/dev/null || true)
                      if [[ -n "$_v6_actual_hash" && "$_v6_declared_hash" != "$_v6_actual_hash" ]]; then
                        _rm_problem "需求条目在验收之后被改过 —— REQ_BLOCK_SHA256 对不上" \
"验收时记录: $_v6_declared_hash
现在算出的:   $_v6_actual_hash
需求源:       $_V6_RM_SRC
条数不变、只改写条目文字也会触发这条 —— 改的是「当初同意的是什么」。
要么把需求改回去，要么按新需求重新验收。"
                      fi
                    fi
                  fi

                  # E3 — citations must land inside this change.
                  if ! _v6_out=$(reqmatrix_check_citations "$VERIFY_FILE" 2>&1 >/dev/null); then
                    _rm_problem "需求矩阵的证据引用不成立" "$_v6_out"
                  fi

                  # Escape hatches are counted and printed rather than blocked. No mechanism
                  # can stop NA/DEFERRED/PREEXISTING abuse without producing false failures,
                  # and the goal was never "impossible to bypass" — it is "impossible to
                  # bypass silently".
                  if _v6_rep=$(reqmatrix_surface_report "$VERIFY_FILE" 2>/dev/null); then
                    echo "   需求矩阵: $(printf '%s' "$_v6_rep" | grep -E '^(COVERED|PREEXISTING|PARTIAL|DEFERRED|NA|MISSING|TOTAL)=' | tr '\n' ' ')"
                    if grep -q '^NO_UI_EVIDENCE$' <<<"$_v6_rep"; then
                      echo "   ⚠️  整个矩阵没有一条 ui: 证据 — 用户入口可能根本没写（纵向漏层）"
                      echo "      纯后端/基建需求请显式写 NO_UI:<理由>"
                    fi
                    grep -q '^ALL_PREEXISTING$' <<<"$_v6_rep" && \
                      echo "   ⚠️  全部条目标为 PREEXISTING — 本次改动等于没有交付任何需求"
                    _v6_nt=$(grep -o '^NOTHING_TOUCHED=.*' <<<"$_v6_rep" || true)
                    [[ -n "$_v6_nt" ]] && \
                      echo "   ⚠️  条目 ${_v6_nt#NOTHING_TOUCHED=} 标为 COVERED 但证据全是既有(~) — 本次并未改动任何东西"
                  fi

                  # E4 — the verdict is derived, not accepted. Only ever tighten: the
                  # capability rule above may already have downgraded PASS to INCOMPLETE,
                  # and a mechanical step must never hand that back.
                  if [[ "$_V6_MATRIX_REQUIRED" -eq 1 ]]; then
                    _v6_derived=$(reqmatrix_reconcile_verdict "$VERIFY_FILE" 2>/dev/null || true)
                    if [[ -n "$_v6_derived" && "$_v6_derived" != "$VERIFY_VERDICT" ]]; then
                      if [[ "$(_reqmatrix_rank "$_v6_derived")" -gt "$(_reqmatrix_rank "$VERIFY_VERDICT")" ]]; then
                        echo "⚠️  CHECK 6: 申报 $VERIFY_VERDICT，按矩阵推导为 $_v6_derived — 采用推导结果"
                        VERIFY_VERDICT="$_v6_derived"
                      fi
                    fi
                  fi
                fi
              fi
            fi
          fi

          case "$VERIFY_VERDICT" in
            PASS)
              # Freshness. Two different signals, and the strong one must win:
              #
              #   anchored  — the dispatch record's staged_diff_hash equals the CURRENT staged
              #               diff, i.e. the staged content is byte-identical to what was
              #               verified. "Did anything change since verification?" is already
              #               answered: no.
              #   mtime     — source file newer than the verify doc. A weak proxy, and simply
              #               wrong in a fresh worktree: `git worktree add` stamps everything
              #               at checkout time, so every source file ends up newer than every
              #               verify doc and ALL changes get counted as post-verification.
              #               That is what produced "Significant changes (115 lines) made
              #               AFTER verification" on a change whose anchor matched exactly
              #               (reported 2026-08-26).
              #
              # So when the anchor matched, skip the mtime comparison — it can only contradict
              # a stronger proof.
              if [[ -n "${VERIFY_ANCHORED:-}" ]]; then
                : # anchor already proves the staged diff is unchanged since verification
              else
              VERIFY_MTIME=$(stat -f %m "$VERIFY_FILE" 2>/dev/null || stat -c %Y "$VERIFY_FILE" 2>/dev/null || echo "0")
              POST_VERIFY_LINES=0
              while IFS= read -r sf; do
                [[ -z "$sf" || ! -f "$sf" ]] && continue
                SF_MTIME=$(stat -f %m "$sf" 2>/dev/null || stat -c %Y "$sf" 2>/dev/null || echo "0")
                if [[ "$SF_MTIME" -gt "$VERIFY_MTIME" ]]; then
                  sf_lines=$(git diff --cached -- "$sf" | grep -c '^+[^+]' 2>/dev/null || echo "0")
                  POST_VERIFY_LINES=$((POST_VERIFY_LINES + sf_lines))
                fi
              done < <(git diff --cached --name-only --diff-filter=ACMR \
                | grep -vE '(\.(lock|md|json|yaml|yml)$|generated/|migrations/|\.d\.ts$)')
              if [[ "$POST_VERIFY_LINES" -gt 20 ]]; then
                fail "Significant changes ($POST_VERIFY_LINES lines) made AFTER verification — re-verify required"
                echo "   (mtime-based check; no dispatch anchor was available to compare against)"
              fi
              fi
              ;;
            FAIL)
              if relaxed_waive "verifier verdict is FAIL ($VERIFY_FILE)" verify; then
                :
              else
                fail "Verifier found real defects — fix before commit"
                echo "   Review: $VERIFY_FILE"
              fi
              ;;
            QUESTIONS|INCOMPLETE)
              if relaxed_waive "verifier verdict is ${VERIFY_VERDICT} ($VERIFY_FILE)" verify; then
                :
              else
              ACK_FILE=".agent/verify/${VERIFY_RUN_ID}.ack"
              if [[ -f "$ACK_FILE" ]]; then
                _ACK_MTIME=$(stat -f %m "$ACK_FILE" 2>/dev/null || stat -c %Y "$ACK_FILE" 2>/dev/null || echo "0")
                _V6_NOW=$(date +%s)
                _ACK_AGE=$(( _V6_NOW - _ACK_MTIME ))
                # TTL is configurable: 4h was arbitrary, and under parallel development an
                # ACK signed before a long build would expire before the commit landed.
                # Capped, because the variable is readable from the agent's own environment
                # and an unbounded value would retire the staleness check entirely
                # (cross-review 2026-08-21 #8).
                _ACK_TTL="${AGENT_GATES_ACK_TTL:-14400}"
                [[ "$_ACK_TTL" =~ ^[0-9]+$ ]] || _ACK_TTL=14400
                [[ "$_ACK_TTL" -gt 86400 ]] && _ACK_TTL=86400
                if [[ "$_ACK_AGE" -le "$_ACK_TTL" ]] && grep -q 'USER_ACK: PROCEED' "$ACK_FILE" 2>/dev/null; then
                  # Hash binding: if staged_diff_hash is present in .ack, verify it matches
                  # current staged diff (excluding .agent/verify/ to avoid chicken-and-egg).
                  # Missing hash field = old-style .ack without binding, skip check (backward compat).
                  # Surface who signed. The field is not a permission check — nothing at
                  # this layer can be — but an agent-signed ACK must not read like a human
                  # one in the log (cross-review 2026-08-21 #7: the field was written and
                  # never consumed, making it decorative).
                  # Printed UNCONDITIONALLY. Showing it only when signed_by=agent gave the
                  # agent a hidden switch: ASK_USER_CONFIRMED=1 is env-settable, records
                  # "human", and the warning disappeared (cross-review round 2, 2026-08-21).
                  # The field cannot be trusted, so it is surfaced rather than acted on.
                  _ACK_SIGNER=$(grep '^signed_by:' "$ACK_FILE" 2>/dev/null | awk '{print $2}' | head -1 || true)
                  _ACK_REASON=$(sed -n 's/^reason:[[:space:]]*//p' "$ACK_FILE" 2>/dev/null | head -1)
                  echo "   ACK: signed_by=${_ACK_SIGNER:-<unset>} — reason: ${_ACK_REASON:-<none>}"
                  _ACK_HASH=$(grep '^staged_diff_hash:' "$ACK_FILE" 2>/dev/null | awk '{print $2}' | head -1 || true)
                  _ACK_HEAD=$(grep '^HEAD:' "$ACK_FILE" 2>/dev/null | awk '{print $2}' | head -1 || true)
                  if [[ -n "$_ACK_HASH" ]]; then
                    if command -v sha256sum >/dev/null 2>&1; then
                      _CURRENT_HASH=$(git diff --cached -- ':!.agent/verify' | sha256sum | cut -d' ' -f1)
                    else
                      _CURRENT_HASH=$(git diff --cached -- ':!.agent/verify' | shasum -a 256 | cut -d' ' -f1)
                    fi
                    _CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
                    if [[ "$_ACK_HASH" != "$_CURRENT_HASH" ]]; then
                      fail "Verifier ACK stale — staged diff changed since ACK was written (re-run verifier + confirm)"
                      echo "   ACK hash:     $_ACK_HASH"
                      echo "   Current hash: $_CURRENT_HASH"
                    elif [[ -n "$_ACK_HEAD" && "$_ACK_HEAD" != "$_CURRENT_HEAD" ]]; then
                      fail "Verifier ACK stale — HEAD changed since ACK was written (new commit since confirmation)"
                    fi
                  fi
                  # else: no hash field — backward-compat, skip hash check
                else
                  fail "Verifier ACK expired or malformed (valid $(( _ACK_TTL / 3600 ))h; set AGENT_GATES_ACK_TTL to change)"
                  _v6_ack_help "$VERIFY_RUN_ID" "$VERIFY_VERDICT"
                fi
              else
                fail "Verifier returned ${VERIFY_VERDICT} — needs the user's go-ahead"
                _v6_ack_help "$VERIFY_RUN_ID" "$VERIFY_VERDICT"
              fi
              fi
              ;;
          esac
        fi
      fi
    elif [[ ! -d .agent ]]; then
      echo "⚠️  No .agent/ directory — verify check skipped (run init-project-gates)."
    fi
  fi
fi

if [[ "$FAILED" -eq 1 ]]; then
  echo ""
  echo "❌ Agent Quality Gate FAILED."
  exit 1
fi

echo "✅ Agent Quality Gate PASSED"

#!/usr/bin/env bash
# Agent Quality Gate — version is stamped at install time (see GATE_VERSION below).
# Only fires when AGENT_MODE=1; human developers pass through.
# Source: https://github.com/mcdowell8023/agent-gates

set -euo pipefail

[[ "${AGENT_MODE:-0}" != "1" ]] && exit 0

git rev-parse MERGE_HEAD &>/dev/null 2>&1 && exit 0

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

if [[ "$NEEDS_REVIEW" -eq 1 ]]; then
  if [[ -d .agent && ! -d .agent/reviews ]]; then
    fail "Project has .agent/ but missing .agent/reviews/ directory"
    echo "   Fix: mkdir -p .agent/reviews"
  elif [[ -d .agent/reviews ]]; then
    # Pick the NEWEST review by mtime — NOT `sort -r` (which sorts by filename,
    # so an old but alphabetically-later file would shadow a freshly-written one).
    REVIEW_FILE=""
    REVIEW_NEWEST_MTIME=0
    while IFS= read -r rf; do
      [[ -z "$rf" || ! -f "$rf" ]] && continue
      rf_mtime=$(stat -f %m "$rf" 2>/dev/null || stat -c %Y "$rf" 2>/dev/null || echo "0")
      if [[ "$rf_mtime" -gt "$REVIEW_NEWEST_MTIME" ]]; then
        REVIEW_NEWEST_MTIME="$rf_mtime"
        REVIEW_FILE="$rf"
      fi
    done < <(find .agent/reviews/ -name "*.md" -mmin -240 2>/dev/null)
    if [[ -z "$REVIEW_FILE" ]]; then
      fail "Cross-review evidence missing or stale (>4h old)"
      echo "   Fix: Run cross-review, save to .agent/reviews/$(date +%Y-%m-%d)-<topic>.md"
      echo "   File MUST end with: VERDICT: PASS (or VERDICT: ISSUES)"
    else
      # Verdict validation: require explicit VERDICT line
      if ! grep -qiE '^VERDICT:\s*(PASS|APPROVED)' "$REVIEW_FILE"; then
        if grep -qiE '^VERDICT:\s*(ISSUES|FAIL|REJECT)' "$REVIEW_FILE"; then
          fail "Review verdict is ISSUES/FAIL — resolve before committing"
        else
          fail "Review file missing explicit verdict line: $REVIEW_FILE"
          echo "   Fix: Add 'VERDICT: PASS' or 'VERDICT: ISSUES' at the end of review file."
        fi
      else
        # Freshness gate: skip if post-review changes are minor (<20 lines)
        # KNOWN LIMITATION: mtime is second-granularity (macOS `stat -f %m`). A source
        # edit made in the SAME second as (but after) the review write escapes this `>`
        # comparison. Using `>=` would over-trigger normal flow (review written right
        # after the last edit), so we accept the rare same-second race. See CHANGELOG
        # v1.7.0 known limitations; a sub-second fix is not portably available.
        REVIEW_MTIME=$(stat -f %m "$REVIEW_FILE" 2>/dev/null || stat -c %Y "$REVIEW_FILE" 2>/dev/null || echo "0")
        POST_REVIEW_LINES=0
        while IFS= read -r sf; do
          [[ -z "$sf" || ! -f "$sf" ]] && continue
          SF_MTIME=$(stat -f %m "$sf" 2>/dev/null || stat -c %Y "$sf" 2>/dev/null || echo "0")
          if [[ "$SF_MTIME" -gt "$REVIEW_MTIME" ]]; then
            sf_lines=$(git diff --cached -- "$sf" | grep -c '^+[^+]' 2>/dev/null || echo "0")
            POST_REVIEW_LINES=$((POST_REVIEW_LINES + sf_lines))
          fi
        done < <(git diff --cached --name-only --diff-filter=ACMR \
          | grep -vE '(\.(lock|md|json|yaml|yml)$|generated/|migrations/|\.d\.ts$)')
        if [[ "$POST_REVIEW_LINES" -gt 20 ]]; then
          fail "Significant changes ($POST_REVIEW_LINES lines) made AFTER review — re-review required"
          echo "   Fix: Re-run cross-review covering your latest changes."
        fi

        # === Gate 2b (v1.7.0): heterogeneous-review enforcement ===
        # If this machine can do heterogeneous review (review-capability.json
        # level >= L1), a same-model (L0) or unmarked review does NOT satisfy
        # 红线 #8's "different model" requirement — block it. A true L0 machine
        # (no opencode/codex) is exempt: there is no heterogeneous alternative.
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
                echo "   Same-model review (e.g. Opus reviewing Opus) does NOT satisfy the different-model requirement."
                echo "   Fix: run cross-review via a DIFFERENT model (opencode/codex — agent-review-protocol §8),"
                echo "        then add a header line to the review file: <!-- REVIEW_LEVEL: L1 -->  (or higher)."
                echo "   Override (genuine exception, e.g. stale config): SKIP_HETERO_CHECK=1"
              elif [[ "$RLEVEL" == "L0" ]]; then
                # v1.13.0 Gate 2b: HETERO_EXHAUSTED exception — all heterogeneous
                # models failed, agent-gates-review fell back to agent-tool L0.
                # R6: require BOTH html comment format AND L0 level to prevent bypass.
                if grep -q '<!-- HETERO_EXHAUSTED:' "$REVIEW_FILE" 2>/dev/null; then
                  echo "⚠️  Gate 2b: HETERO_EXHAUSTED — all heterogeneous review models failed; degrading to warn"
                  echo "   Review was completed with agent-tool (L0) as last resort."
                else
                  fail "Review is same-model (REVIEW_LEVEL: L0) but machine supports heterogeneous ($CAP_LEVEL)"
                  echo "   Fix: re-run cross-review via a different model (opencode/codex — §8)."
                  echo "   Override (genuine exception): SKIP_HETERO_CHECK=1"
                fi
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

  if [[ "$NEEDS_VERIFY" -eq 1 ]]; then
    if [[ -d .agent && ! -d .agent/verify ]]; then
      fail "No verifier evidence (.agent/verify/ missing)"
      echo "   Fix: Run verifier agent, save output to .agent/verify/<date>-<topic>.md"
    elif [[ -d .agent/verify ]]; then
      # Pick the newest verify file by mtime (within 4h); mirrors Gate 2 selection logic
      VERIFY_FILE=""
      VERIFY_NEWEST_MTIME=0
      while IFS= read -r vf; do
        [[ -z "$vf" || ! -f "$vf" ]] && continue
        vf_mtime=$(stat -f %m "$vf" 2>/dev/null || stat -c %Y "$vf" 2>/dev/null || echo "0")
        if [[ "$vf_mtime" -gt "$VERIFY_NEWEST_MTIME" ]]; then
          VERIFY_NEWEST_MTIME="$vf_mtime"
          VERIFY_FILE="$vf"
        fi
      done < <(find .agent/verify/ -name "*.md" -mmin -240 2>/dev/null)

      if [[ -z "$VERIFY_FILE" ]]; then
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

          case "$VERIFY_VERDICT" in
            PASS)
              # Freshness: post-verify source changes ≤ 20 lines (mirrors Gate 2 post-review check)
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
              fi
              ;;
            FAIL)
              fail "Verifier found real defects — fix before commit"
              echo "   Review: $VERIFY_FILE"
              ;;
            QUESTIONS|INCOMPLETE)
              ACK_FILE=".agent/verify/${VERIFY_RUN_ID}.ack"
              if [[ -f "$ACK_FILE" ]]; then
                _ACK_MTIME=$(stat -f %m "$ACK_FILE" 2>/dev/null || stat -c %Y "$ACK_FILE" 2>/dev/null || echo "0")
                _V6_NOW=$(date +%s)
                _ACK_AGE=$(( _V6_NOW - _ACK_MTIME ))
                if [[ "$_ACK_AGE" -le 14400 ]] && grep -q 'USER_ACK: PROCEED' "$ACK_FILE" 2>/dev/null; then
                  # Hash binding: if staged_diff_hash is present in .ack, verify it matches
                  # current staged diff (excluding .agent/verify/ to avoid chicken-and-egg).
                  # Missing hash field = old-style .ack without binding, skip check (backward compat).
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
                  fail "Verifier needs user confirmation (stale or invalid .ack)"
                  echo "   Fix: Re-run verifier workflow to regenerate .agent/verify/${VERIFY_RUN_ID}.ack"
                fi
              else
                fail "Verifier needs user confirmation (no .ack file)"
                echo "   Fix: After reviewing verifier output, confirm via workflow to create .agent/verify/${VERIFY_RUN_ID}.ack"
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

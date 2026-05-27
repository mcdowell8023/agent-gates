#!/usr/bin/env bash
# Agent Quality Gate v1.5
# Only fires when AGENT_MODE=1; human developers pass through.
# Version: 1.5.0
# Source: https://github.com/mcdowell8023/agent-gates

set -euo pipefail

[[ "${AGENT_MODE:-0}" != "1" ]] && exit 0

git rev-parse MERGE_HEAD &>/dev/null 2>&1 && exit 0

FAILED=0
fail() { echo "❌ GATE: $1"; FAILED=1; }

DIFF_LINES=$(git diff --cached --stat | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
CHANGED_COUNT=$(git diff --cached --name-only --diff-filter=ACMR | wc -l | tr -d ' ')

NEW_SOURCE=$(git diff --cached --diff-filter=A --name-only \
  | grep -E '\.(ts|tsx|js|jsx|py|java|kt|go)$' \
  | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.|\.setup\.)' || true)

if [[ -z "$NEW_SOURCE" && "$DIFF_LINES" -le 15 && "$CHANGED_COUNT" -le 2 ]]; then
  exit 0
fi

echo "🔍 Agent Quality Gate v1.5 ($CHANGED_COUNT files, +${DIFF_LINES} lines)"

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

# === Gate 2: Cross-review evidence ===
# Count non-test logic files (test files excluded from trigger count)
LOGIC_FILES=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  LOGIC_FILES=$((LOGIC_FILES + 1))
done < <(git diff --cached --name-only --diff-filter=ACMR \
  | grep -vE '(\.(lock|md|json|yaml|yml)$|generated/|migrations/|\.d\.ts$)' \
  | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.)')

# Single-file high-change threshold
MAX_SINGLE_FILE_LINES=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  flines=$(git diff --cached -- "$f" | grep -c '^+[^+]' 2>/dev/null || echo "0")
  [[ "$flines" -gt "$MAX_SINGLE_FILE_LINES" ]] && MAX_SINGLE_FILE_LINES="$flines"
done < <(git diff --cached --name-only --diff-filter=ACMR \
  | grep -vE '(\.(lock|md|json|yaml|yml)$|generated/|migrations/|\.d\.ts$)' \
  | grep -vE '(\.test\.|\.spec\.|_test\.|Test\.)')

# Trigger: (multi-file AND substantial change) OR single-file massive change
NEEDS_REVIEW=0
[[ "$LOGIC_FILES" -gt 1 && "$DIFF_LINES" -gt 50 ]] && NEEDS_REVIEW=1
[[ "$MAX_SINGLE_FILE_LINES" -gt 150 ]] && NEEDS_REVIEW=1

if [[ "$NEEDS_REVIEW" -eq 1 ]]; then
  if [[ -d .agent && ! -d .agent/reviews ]]; then
    fail "Project has .agent/ but missing .agent/reviews/ directory"
    echo "   Fix: mkdir -p .agent/reviews"
  elif [[ -d .agent/reviews ]]; then
    REVIEW_FILE=$(find .agent/reviews/ -name "*.md" -mmin -240 2>/dev/null | sort -r | head -1)
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
      fi
    fi
  elif [[ ! -d .agent ]]; then
    echo "⚠️  No .agent/ directory — cross-review check skipped (run init-project-gates)."
  fi
fi

if [[ "$FAILED" -eq 1 ]]; then
  echo ""
  echo "❌ Agent Quality Gate FAILED."
  exit 1
fi

echo "✅ Agent Quality Gate PASSED"

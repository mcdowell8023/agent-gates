#!/usr/bin/env bash
# lib/hetero/conclusion.sh — parsing model output and its conclusion line.
#
# Extracted from bin/agent-gates-review so the verify side can use the same code instead of
# a second copy. lib/hetero/select.sh already probed for these with `declare -f`, which was
# the tell that they belonged in a library rather than in one executable.

[[ -n "${_HETERO_CONCLUSION_SOURCED:-}" ]] && return 0
_HETERO_CONCLUSION_SOURCED=1

# opencode --format json emits NDJSON; the text lives at obj["part"]["text"], not obj["text"].
parse_opencode_json() {
  python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'text':
            print(obj.get('part', {}).get('text', ''), end='')
    except:
        pass
"
}

# Does the text carry a usable conclusion line? Tolerates leading markdown decoration and a
# full-width colon, but the line must carry nothing except the value — PASS_WITH_ISSUES and
# friends are rejected because they invert the result.
has_valid_conclusion() {
  local text="$1"
  echo "$text" | grep -qiE '^[[:blank:]]*[#>*_`[:blank:]-]*VERDICT[[:blank:]]*(:|：)[[:blank:]]*[*`]*(PASS|PASSED|REVISE|REVISED|FAIL|FAILED|ISSUES|ISSUES_FOUND|APPROVED|APPROVE|REJECT|REJECTED)[*`[:blank:].]*$' && return 0
  return 1
}

# Echo the raw conclusion line as the model wrote it, so a transcription can be checked
# word for word rather than trusted.
extract_conclusion_line() {
  local text="$1"
  printf '%s' "$text" | grep -iE '^[[:blank:]]*[#>*_`[:blank:]-]*(VERIFY_)?VERDICT[[:blank:]]*(:|：)' | head -1
}

# Echo just the value, decoration stripped and upper-cased.
extract_verdict_value() {
  local text="$1" line
  line=$(extract_conclusion_line "$text")
  [[ -z "$line" ]] && return 1
  printf '%s' "$line" \
    | grep -oiE '(PASS|PASSED|REVISE|REVISED|FAIL|FAILED|ISSUES|ISSUES_FOUND|APPROVED|APPROVE|REJECT|REJECTED|QUESTIONS|INCOMPLETE)' \
    | head -1 | tr '[:lower:]' '[:upper:]'
}

# Map a review-side value onto CHECK 6's vocabulary (PASS / FAIL / QUESTIONS / INCOMPLETE).
# ⚠️ This is a mechanical relabelling, not a judgement: "found issues" and "needs revision"
# both mean the change is not cleared, which on the verify side is FAIL. Callers MUST record
# the original line next to the mapped one so the transcription stays checkable.
map_verdict_to_verify() {
  case "${1:-}" in
    PASS|PASSED|APPROVED|APPROVE)                          echo PASS ;;
    FAIL|FAILED|REJECT|REJECTED|ISSUES|ISSUES_FOUND|REVISE|REVISED) echo FAIL ;;
    QUESTIONS)                                             echo QUESTIONS ;;
    INCOMPLETE)                                            echo INCOMPLETE ;;
    *)                                                     return 1 ;;
  esac
}

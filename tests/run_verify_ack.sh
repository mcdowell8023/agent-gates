#!/usr/bin/env bash
# Tests for bin/agent-gates-verify-ack.
#
# Design note (2026-08-21): the gate used to refuse to run under AGENT_MODE=1 unless
# ASK_USER_CONFIRMED=1 was also set. That check never proved anything — this script records
# no signer identity and cannot, since anyone able to run it can set any environment
# variable. Its only real effect was forcing the user to cd into the directory and sign by
# hand, which became the dominant cost during parallel development.
#
# So the gate is now on HONESTY rather than identity:
#   - AGENT_MODE=1 must supply an explicit reason; the default "user confirmed" would be a
#     false statement when an agent signs on the user's behalf.
#   - The .ack records signed_by, so the artifact states which it was.
#   - ASK_USER_CONFIRMED=1 still means a human confirmed, and keeps the default reason.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACK="$SCRIPT_DIR/../bin/agent-gates-verify-ack"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# A repo with one staged change and a verify document, which is what ack binds to.
setup_repo() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  echo base > f.txt; git add f.txt; git commit -q -m init
  echo changed > f.txt; git add f.txt          # staged change for the hash binding
  mkdir -p .agent/verify
  cat > .agent/verify/RUN1.md <<'MD'
VERIFY_VERDICT: INCOMPLETE
e2e pending deploy
MD
}
teardown_repo() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; }

echo "=== agent-gates-verify-ack tests ==="
echo

# A1: human path (no AGENT_MODE) works with the default reason
echo "A1: 无 AGENT_MODE → 成功，signed_by: human"
(
  setup_repo
  out=$(env -u AGENT_MODE -u ASK_USER_CONFIRMED bash "$ACK" RUN1 2>&1); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert ".ack 已生成" "$([[ -f .agent/verify/RUN1.ack ]] && echo true || echo false)"
  assert "含 USER_ACK: PROCEED" "$(grep -q '^USER_ACK: PROCEED' .agent/verify/RUN1.ack && echo true || echo false)"
  assert "signed_by: human" "$(grep -q '^signed_by: human' .agent/verify/RUN1.ack && echo true || echo false)"
  teardown_repo
)

# A2: agent path without a reason is refused — the default reason would be a lie
echo "A2: AGENT_MODE=1 且未给 reason → 拒绝（默认 reason 会是假话）"
(
  setup_repo
  out=$(AGENT_MODE=1 bash "$ACK" RUN1 2>&1); rc=$?
  assert "exit != 0 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "报错提到 reason" "$([[ "$out" == *reason* ]] && echo true || echo false)"
  assert "未写出 .ack" "$([[ ! -f .agent/verify/RUN1.ack ]] && echo true || echo false)"
  teardown_repo
)

# A3: agent path WITH a reason succeeds and is recorded as such
echo "A3: AGENT_MODE=1 且给了 reason → 成功，signed_by: agent，reason 落盘"
(
  setup_repo
  out=$(AGENT_MODE=1 bash "$ACK" RUN1 "user approved: e2e blocked on deploy" 2>&1); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "signed_by: agent" "$(grep -q '^signed_by: agent' .agent/verify/RUN1.ack && echo true || echo false)"
  assert "reason 原文落盘" "$(grep -q 'e2e blocked on deploy' .agent/verify/RUN1.ack && echo true || echo false)"
  teardown_repo
)

# A4: backward compatibility — an explicit human confirmation keeps the default reason
echo "A4: ASK_USER_CONFIRMED=1 → 仍算人工确认，可用默认 reason"
(
  setup_repo
  out=$(AGENT_MODE=1 ASK_USER_CONFIRMED=1 bash "$ACK" RUN1 2>&1); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "signed_by: human" "$(grep -q '^signed_by: human' .agent/verify/RUN1.ack && echo true || echo false)"
  teardown_repo
)

# A5: the ack must bind the current staged diff and HEAD, or the gate cannot detect staleness
echo "A5: .ack 绑定当前 staged hash 与 HEAD"
(
  setup_repo
  env -u AGENT_MODE bash "$ACK" RUN1 >/dev/null 2>&1
  want_hash=$(git diff --cached -- ':!.agent/verify' | shasum -a 256 | cut -d' ' -f1)
  want_head=$(git rev-parse HEAD)
  got_hash=$(grep '^staged_diff_hash:' .agent/verify/RUN1.ack | awk '{print $2}')
  got_head=$(grep '^HEAD:' .agent/verify/RUN1.ack | awk '{print $2}')
  assert "staged_diff_hash 与实际一致" "$([[ "$got_hash" == "$want_hash" ]] && echo true || echo false)"
  assert "HEAD 与实际一致" "$([[ "$got_head" == "$want_head" ]] && echo true || echo false)"
  teardown_repo
)

# A6: no verify document -> refuse (an ack must point at a real verify run)
echo "A6: verify 文档不存在 → 拒绝"
(
  setup_repo
  out=$(env -u AGENT_MODE bash "$ACK" NOSUCH 2>&1); rc=$?
  assert "exit != 0 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "未写出 .ack" "$([[ ! -f .agent/verify/NOSUCH.ack ]] && echo true || echo false)"
  teardown_repo
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]

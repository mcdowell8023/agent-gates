#!/usr/bin/env bash
# Tests for lib/hetero/dispatch.sh + lib/hetero/config.sh — P2 dispatch + minimal lifecycle.
#
# Coverage (T1-T9 per P2 spec):
#   T1  hetero_spawn_pg 起子进程在新 PGID（不复用调用方 shell 的组）
#   T2  hetero_kill_tree 杀整组（含 fork 孙进程，禁 pkill -P）
#   T3  hetero_register_spawn 写归因 JSON
#   T4  dispatch 在 opencode 可用 + serve 可用时走 opencode 通道 (EVIDENCE_ONLY)
#   T5  dispatch 在 opencode 可用 + serve 不可用时不裸跑（fail-closed 降级）
#   T6  dispatch 原子写 .agent/verify/<verify_run_id>.dispatch.json
#   T7  墙钟 watcher 在超时后杀进程组
#   T8  最小熔断——连续 3 次 cold-start 死亡停用该 key
#   T9  oc-review serve 失败 → exit 75（不裸跑 opencode）
#
# Strategy:
#   - T1/T2/T3/T7/T8: real fork (no mock of kill), verify process-group semantics
#   - T4/T5/T6: fake opencode/curl/nohup on PATH for channel selection + serve
#   - T9: fake opencode/curl on PATH, do NOT set OC_SERVE_DISABLED (must attempt+fail)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_LIB="$SCRIPT_DIR/../lib/hetero/dispatch.sh"
CONFIG_LIB="$SCRIPT_DIR/../lib/hetero/config.sh"
OC_REVIEW="$SCRIPT_DIR/../bin/oc-review"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Source dispatch + config libs with fresh state. Each test gets its own HETERO_LOCK_DIR.
source_dispatch() {
  _HETERO_CONFIG_SOURCED=""
  _HETERO_DISPATCH_SOURCED=""
  _OC_SERVE_SOURCED=""
  HETERO_LOCK_DIR=$(mktemp -d)
  export HETERO_LOCK_DIR
  source "$CONFIG_LIB"
  source "$DISPATCH_LIB"
}

setup_mock_repo() {
  MOCK_REPO=$(mktemp -d)
  cd "$MOCK_REPO" || exit 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"
}

teardown_mock_repo() {
  cd /
  [[ -n "${MOCK_REPO:-}" && -d "$MOCK_REPO" ]] && rm -rf "$MOCK_REPO"
}

# Build a fake opencode that handles 'serve' (backgrounded by nohup) and 'run'.
# Behavior controlled by $1: "ok" (serve exits 0, run echoes body) or "fail" (both exit 1).
make_fake_opencode() {
  local mode="$1" fake_dir="$2"
  cat > "$fake_dir/opencode" <<FAKE
#!/usr/bin/env bash
case "\$1" in
  serve) [[ "$mode" == "ok" ]] && exit 0 || exit 1 ;;
  run)   [[ "$mode" == "ok" ]] && { echo "review body — VERDICT: PASS"; exit 0; } || exit 1 ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$fake_dir/opencode"
}

make_fake_curl() {
  local mode="$1" fake_dir="$2"
  cat > "$fake_dir/curl" <<FAKE
#!/usr/bin/env bash
[[ "$mode" == "ok" ]] && exit 0 || exit 1
FAKE
  chmod +x "$fake_dir/curl"
}

# oc-review uses /usr/bin/nohup explicitly (not PATH); but dispatch.sh uses `nohup` from PATH.
# For tests that exercise serve.sh's _oc_serve_start, /usr/bin/nohup runs the fake opencode (which exits
# immediately), so the fake nohup here only matters for dispatch path. Provide a passthrough.
make_fake_nohup() {
  local fake_dir="$1"
  cat > "$fake_dir/nohup" <<'NOHUP'
#!/usr/bin/env bash
exec "$@"
NOHUP
  chmod +x "$fake_dir/nohup"
}

echo "=== hetero dispatch + minimal lifecycle tests (P2) ==="
echo ""

# T1: hetero_spawn_pg 起子进程在新 PGID
test_t1_spawn_pg_new_pgid() {
  echo "T1: hetero_spawn_pg 起子进程在新 PGID（不复用调用方 shell 的组）"
  (
    source_dispatch
    hetero_spawn_pg sleep 30
    assert "HETERO_LAST_ROOT_PID 已设" "$([[ -n "${HETERO_LAST_ROOT_PID:-}" ]] && echo true || echo false)"
    assert "HETERO_LAST_PGID 已设" "$([[ -n "${HETERO_LAST_PGID:-}" ]] && echo true || echo false)"
    local child_pgid caller_pgid
    child_pgid=$(ps -o pgid= -p "$HETERO_LAST_ROOT_PID" 2>/dev/null | tr -d ' ')
    caller_pgid=$(ps -o pgid= -p "$BASHPID" 2>/dev/null | tr -d ' ')
    assert "child PGID ($child_pgid) != caller PGID ($caller_pgid)" "$([[ -n "$child_pgid" && "$child_pgid" != "$caller_pgid" ]] && echo true || echo false)"
    assert "setsid 后 child PGID == ROOT_PID ($HETERO_LAST_ROOT_PID)" "$([[ "$child_pgid" == "$HETERO_LAST_ROOT_PID" ]] && echo true || echo false)"
    hetero_kill_tree "$HETERO_LAST_PGID" 0
    rm -rf "$HETERO_LOCK_DIR"
  )
}

# T2: hetero_kill_tree 杀整组（含孙进程）
test_t2_kill_tree_kills_grandchild() {
  echo "T2: hetero_kill_tree 杀整组（parent + child + grandchild）"
  (
    source_dispatch
    local fork_script
    fork_script=$(mktemp)
    cat > "$fork_script" <<'EOF'
#!/usr/bin/env bash
# parent: fork a child that forks a grandchild, all in the same pgid (no set -m)
bash -c 'sleep 30 & wait' &
wait
EOF
    chmod +x "$fork_script"
    hetero_spawn_pg bash "$fork_script"
    local pgid=$HETERO_LAST_PGID
    sleep 0.6  # let forks settle (parent → child → grandchild)
    local before
    before=$(pgrep -g "$pgid" 2>/dev/null | wc -l | tr -d ' ')
    assert "kill 前 pgid 内 >=3 进程 (实际 $before)" "$([[ "$before" -ge 3 ]] && echo true || echo false)"
    hetero_kill_tree "$pgid" 1
    sleep 0.6
    local after
    after=$(pgrep -g "$pgid" 2>/dev/null | wc -l | tr -d ' ')
    assert "kill 后 pgid 内 0 进程 (实际 $after)" "$([[ "$after" == "0" ]] && echo true || echo false)"
    rm -f "$fork_script"
    rm -rf "$HETERO_LOCK_DIR"
  )
}

# T3: hetero_register_spawn 写归因文件
test_t3_register_spawn_writes_attribution() {
  echo "T3: hetero_register_spawn 写归因 JSON 到 spawns/"
  (
    source_dispatch
    hetero_register_spawn "opencode/test-key" 12345 12345
    local spawns_dir="$HETERO_LOCK_DIR/spawns"
    local count
    count=$(ls "$spawns_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
    assert "spawns/ 下有 1 个 JSON 文件 (实际 $count)" "$([[ "$count" == "1" ]] && echo true || echo false)"
    local file
    file=$(ls "$spawns_dir"/*.json 2>/dev/null | head -1)
    assert "JSON 含 key=opencode/test-key" "$(grep -q '"key": "opencode/test-key"' "$file" && echo true || echo false)"
    assert "JSON 含 root_pid=12345" "$(grep -q '"root_pid": 12345' "$file" && echo true || echo false)"
    assert "JSON 含 pgid=12345" "$(grep -q '"pgid": 12345' "$file" && echo true || echo false)"
    assert "JSON 含 started_at" "$(grep -q '"started_at":' "$file" && echo true || echo false)"
    rm -rf "$HETERO_LOCK_DIR"
  )
}

# T4: dispatch 在 opencode 可用 + serve 可用时走 opencode 通道
test_t4_dispatch_opencode_channel() {
  echo "T4: opencode 可用 + serve 可用 → 走 opencode 通道 (EVIDENCE_ONLY)"
  (
    setup_mock_repo
    source_dispatch
    local fake_dir
    fake_dir=$(mktemp -d)
    make_fake_opencode "ok" "$fake_dir"
    make_fake_curl "ok" "$fake_dir"
    make_fake_nohup "$fake_dir"
    export PATH="$fake_dir:$PATH"
    # Disable all other channels
    export HETERO_BIN_PASEO=/nonexistent-paseo
    export HETERO_BIN_CODEX=/nonexistent-codex
    export HETERO_BIN_CODEBUDDY=/nonexistent-codebuddy
    hetero_dispatch "reviewer" "test prompt" 0 2>/dev/null
    assert "channel == opencode (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == "opencode" ]] && echo true || echo false)"
    assert "capability == EVIDENCE_ONLY" "$([[ "${HETERO_DISPATCH_CAPABILITY:-}" == "EVIDENCE_ONLY" ]] && echo true || echo false)"
    assert "verify_run_id 已设" "$([[ -n "${HETERO_DISPATCH_VERIFY_RUN_ID:-}" ]] && echo true || echo false)"
    rm -rf "$fake_dir" "$HETERO_LOCK_DIR"
    teardown_mock_repo
  )
}

# T5: dispatch 在 opencode 可用 + serve 不可用时不裸跑（fail-closed）
test_t5_dispatch_fail_closed_no_bare_run() {
  echo "T5: opencode 可用 + serve 不可用 → fail-closed 降级（不裸跑 opencode）"
  (
    setup_mock_repo
    source_dispatch
    local fake_dir
    fake_dir=$(mktemp -d)
    make_fake_opencode "fail" "$fake_dir"
    make_fake_curl "fail" "$fake_dir"
    make_fake_nohup "$fake_dir"
    export PATH="$fake_dir:$PATH"
    export HETERO_BIN_PASEO=/nonexistent-paseo
    export HETERO_BIN_CODEX=/nonexistent-codex
    export HETERO_BIN_CODEBUDDY=/nonexistent-codebuddy
    hetero_dispatch "reviewer" "test prompt" 0 2>/dev/null
    assert "channel != opencode (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" != "opencode" ]] && echo true || echo false)"
    assert "降级到 exhausted (实际 ${HETERO_DISPATCH_CHANNEL:-})" "$([[ "${HETERO_DISPATCH_CHANNEL:-}" == "exhausted" ]] && echo true || echo false)"
    rm -rf "$fake_dir" "$HETERO_LOCK_DIR"
    teardown_mock_repo
  )
}

# T6: dispatch 写 dispatch 产物 JSON
test_t6_dispatch_writes_json_artifact() {
  echo "T6: dispatch 原子写 .agent/verify/<verify_run_id>.dispatch.json"
  (
    setup_mock_repo
    source_dispatch
    local fake_dir
    fake_dir=$(mktemp -d)
    make_fake_opencode "ok" "$fake_dir"
    make_fake_curl "ok" "$fake_dir"
    make_fake_nohup "$fake_dir"
    export PATH="$fake_dir:$PATH"
    export HETERO_BIN_PASEO=/nonexistent-paseo
    export HETERO_BIN_CODEX=/nonexistent-codex
    export HETERO_BIN_CODEBUDDY=/nonexistent-codebuddy
    hetero_dispatch "reviewer" "test prompt" 0 2>/dev/null
    local json="${HETERO_DISPATCH_DISPATCH_JSON:-}"
    assert "DISPATCH_JSON 路径已设" "$([[ -n "$json" ]] && echo true || echo false)"
    assert "JSON 文件存在 ($json)" "$([[ -f "$json" ]] && echo true || echo false)"
    assert "JSON 含 verify_run_id" "$(grep -q '"verify_run_id":' "$json" 2>/dev/null && echo true || echo false)"
    assert "JSON 含 channel=opencode" "$(grep -q '"channel": "opencode"' "$json" 2>/dev/null && echo true || echo false)"
    assert "JSON 含 capability=EVIDENCE_ONLY" "$(grep -q '"capability": "EVIDENCE_ONLY"' "$json" 2>/dev/null && echo true || echo false)"
    assert "JSON 含 HEAD" "$(grep -q '"HEAD":' "$json" 2>/dev/null && echo true || echo false)"
    assert "JSON 含 staged_diff_hash" "$(grep -q '"staged_diff_hash":' "$json" 2>/dev/null && echo true || echo false)"
    local tmp_count
    tmp_count=$(ls .agent/verify/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')
    assert "无 .tmp 残留 (实际 $tmp_count)" "$([[ "$tmp_count" == "0" ]] && echo true || echo false)"
    rm -rf "$fake_dir" "$HETERO_LOCK_DIR"
    teardown_mock_repo
  )
}

# T7: 墙钟 watcher 在超时后杀进程组
test_t7_wall_clock_watcher_kills_group() {
  echo "T7: 墙钟 watcher 在超时后杀进程组"
  (
    source_dispatch
    export HETERO_AGENT_MAX_WALL_S=1
    export HETERO_KILL_GRACE_S=0
    hetero_spawn_pg sleep 30
    local pgid=$HETERO_LAST_PGID
    local root_pid=$HETERO_LAST_ROOT_PID
    hetero_register_wall_watcher "$pgid" "${HETERO_AGENT_MAX_WALL_S}"
    sleep 2.2  # wait for watcher to fire (WALL=1 + grace=0)
    local alive=0
    kill -0 "$root_pid" 2>/dev/null && alive=1
    assert "watcher 触发后 root_pid 已死" "$([[ "$alive" == "0" ]] && echo true || echo false)"
    local group_alive
    group_alive=$(pgrep -g "$pgid" 2>/dev/null | wc -l | tr -d ' ')
    assert "pgid 内 0 进程 (实际 $group_alive)" "$([[ "$group_alive" == "0" ]] && echo true || echo false)"
    rm -rf "$HETERO_LOCK_DIR"
  )
}

# T8: 最小熔断——连续 3 次即死后停用该 key
test_t8_breaker_trips_after_3_cold_starts() {
  echo "T8: 连续 3 次 cold-start 死亡 → 熔断停用"
  (
    source_dispatch
    local exits_dir="$HETERO_LOCK_DIR/exits"
    mkdir -p "$exits_dir"
    local key="opencode/test-breaker"
    local key_safe="${key//\//_}"
    local now
    now=$(date +%s)
    # 3 cold-start death records (started, exited within 1s, non-zero exit)
    local i started exited
    for i in 1 2 3; do
      started=$((now - i * 10))
      exited=$((started + 1))  # 1s < cold_start_s (default 10)
      cat > "$exits_dir/${key_safe}.${started}.json" <<EOF
{"key": "$key", "root_pid": $((1000+i)), "exit_code": 1, "started_at": $started, "exited_at": $exited}
EOF
    done
    _hetero_check_breaker "$key"
    local rc=$?
    assert "3 次连续即死 → 熔断 (rc=$rc, 期望 1)" "$([[ "$rc" == "1" ]] && echo true || echo false)"
    # Only 2 deaths — should NOT trip
    rm -f "$exits_dir"/${key_safe}.*.json
    for i in 1 2; do
      started=$((now - i * 10))
      exited=$((started + 1))
      cat > "$exits_dir/${key_safe}.${started}.json" <<EOF
{"key": "$key", "root_pid": $((1000+i)), "exit_code": 1, "started_at": $started, "exited_at": $exited}
EOF
    done
    _hetero_check_breaker "$key"
    rc=$?
    assert "2 次连续即死 → 不熔断 (rc=$rc, 期望 0)" "$([[ "$rc" == "0" ]] && echo true || echo false)"
    rm -rf "$HETERO_LOCK_DIR"
  )
}

# T9: oc-review serve 失败 → exit 75 不裸跑
# Key design: fake `run` SUCCEEDS with output. Without fail-closed, oc-review would
# exit 0 (bare run succeeded). With fail-closed, oc-review exits 75 BEFORE calling `run`.
# This distinguishes "fail-closed" from "bare run that happened to fail".
test_t9_oc_review_fail_closed_exit_75() {
  echo "T9: oc-review serve 失败 → exit 75（不裸跑 opencode）"
  (
    local fake_dir
    fake_dir=$(mktemp -d)
    # Custom fake: serve fails (oc_serve_ensure fails), but run SUCCEEDS with a marker.
    # If bare-run path is taken, rc would be 0 and marker in $out.
    cat > "$fake_dir/opencode" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  serve) exit 1 ;;
  run)   echo "BARE_RUN_SUCCEEDED"; exit 0 ;;
  *)     exit 1 ;;
esac
FAKE
    chmod +x "$fake_dir/opencode"
    make_fake_curl "fail" "$fake_dir"
    make_fake_nohup "$fake_dir"
    export PATH="$fake_dir:$PATH"
    unset OC_SERVE_DISABLED  # must attempt serve integration and fail
    local out rc
    out=$(OC_REVIEW_OPENCODE="$fake_dir/opencode" OC_SERVE_OPENCODE="$fake_dir/opencode" \
          OC_SERVE_START_RETRIES=2 \
          bash "$OC_REVIEW" run -m x "p" 2>&1)
    rc=$?
    assert "exit 75 (实际 $rc)" "$([[ "$rc" == "75" ]] && echo true || echo false)"
    assert "未走裸跑路径 (no BARE_RUN_SUCCEEDED in output)" "$([[ "$out" != *"BARE_RUN_SUCCEEDED"* ]] && echo true || echo false)"
    rm -rf "$fake_dir"
  )
}

test_t1_spawn_pg_new_pgid
test_t2_kill_tree_kills_grandchild
test_t3_register_spawn_writes_attribution
test_t4_dispatch_opencode_channel
test_t5_dispatch_fail_closed_no_bare_run
test_t6_dispatch_writes_json_artifact
test_t7_wall_clock_watcher_kills_group
test_t8_breaker_trips_after_3_cold_starts
test_t9_oc_review_fail_closed_exit_75

echo ""
read -r PASS FAIL < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

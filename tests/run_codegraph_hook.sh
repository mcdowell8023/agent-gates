#!/usr/bin/env bash
# Tests for codegraph-chpwd.zsh — auto-init CodeGraph on cd into git repos.
# Strategy: source the hook script in bash (zsh-specific bits stubbed),
# call _agent_gates_codegraph_should_init directly, assert exit codes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/shell/codegraph-chpwd.zsh"
RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

setup_mock_env() {
  MOCK_HOME=$(mktemp -d)
  MOCK_PROJECT=$(mktemp -d)
  export HOME="$MOCK_HOME"
  export AGENT_GATES_CODEGRAPH_AUTO_INIT=1
  export AGENT_GATES_CODEGRAPH_DIRS="$MOCK_PROJECT"
  # Create a fake git repo
  mkdir -p "$MOCK_PROJECT/myrepo/.git"
  # Create a fake codegraph binary
  mkdir -p "$MOCK_HOME/bin"
  cat > "$MOCK_HOME/bin/codegraph" <<'FAKECG'
#!/usr/bin/env bash
echo "codegraph-mock: $*" >> "${CODEGRAPH_MOCK_LOG:-/dev/null}"
FAKECG
  chmod +x "$MOCK_HOME/bin/codegraph"
  export PATH="$MOCK_HOME/bin:$PATH"
  export CODEGRAPH_MOCK_LOG="$MOCK_HOME/codegraph-calls.log"
  # Clean lock dir
  export AGENT_GATES_CODEGRAPH_LOCKDIR="$MOCK_HOME/locks"
  mkdir -p "$AGENT_GATES_CODEGRAPH_LOCKDIR"
}

teardown_mock_env() {
  [[ -n "${MOCK_HOME:-}" && -d "$MOCK_HOME" ]] && rm -rf "$MOCK_HOME"
  [[ -n "${MOCK_PROJECT:-}" && -d "$MOCK_PROJECT" ]] && rm -rf "$MOCK_PROJECT"
}

source_hook() {
  # Source the hook script, stripping zsh-specific lines (autoload, add-zsh-hook)
  local tmp
  tmp=$(mktemp)
  grep -v -E '^(autoload|add-zsh-hook)' "$HOOK_SCRIPT" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

assert() {
  local name="$1"
  local cond="$2"
  local p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then
    echo "  ✓ $name"
    echo "$((p + 1)) $f" > "$RESULTS_FILE"
  else
    echo "  ✗ $name"
    echo "$p $((f + 1))" > "$RESULTS_FILE"
  fi
}

# --- Test 1: skip when AGENT_GATES_CODEGRAPH_AUTO_INIT is unset ---
test_skip_when_disabled() {
  echo "T1: skip when auto-init disabled"
  (
    setup_mock_env
    source_hook
    unset AGENT_GATES_CODEGRAPH_AUTO_INIT
    cd "$MOCK_PROJECT/myrepo" || exit 1
    _agent_gates_codegraph_should_init
    result=$?
    assert "returns non-zero when disabled" "$([[ $result -ne 0 ]] && echo true || echo false)"
    teardown_mock_env
  )
}

# --- Test 2: skip when codegraph not installed ---
test_skip_when_no_codegraph() {
  echo "T2: skip when codegraph not on PATH"
  (
    setup_mock_env
    rm "$MOCK_HOME/bin/codegraph"
    # Isolate PATH so system codegraph is not found
    export PATH="$MOCK_HOME/bin:/usr/bin:/bin"
    source_hook
    cd "$MOCK_PROJECT/myrepo" || exit 1
    _agent_gates_codegraph_should_init
    result=$?
    assert "returns non-zero without codegraph" "$([[ $result -ne 0 ]] && echo true || echo false)"
    teardown_mock_env
  )
}

# --- Test 3: skip when not in git repo ---
test_skip_when_not_git() {
  echo "T3: skip when not a git repo"
  (
    setup_mock_env
    source_hook
    local nogit="$MOCK_PROJECT/notgit"
    mkdir -p "$nogit"
    cd "$nogit" || exit 1
    _agent_gates_codegraph_should_init
    result=$?
    assert "returns non-zero outside git repo" "$([[ $result -ne 0 ]] && echo true || echo false)"
    teardown_mock_env
  )
}

# --- Test 4: skip when .codegraph/ already exists ---
test_skip_when_already_indexed() {
  echo "T4: skip when .codegraph/ already exists"
  (
    setup_mock_env
    source_hook
    mkdir -p "$MOCK_PROJECT/myrepo/.codegraph"
    cd "$MOCK_PROJECT/myrepo" || exit 1
    _agent_gates_codegraph_should_init
    result=$?
    assert "returns non-zero when .codegraph exists" "$([[ $result -ne 0 ]] && echo true || echo false)"
    teardown_mock_env
  )
}

# --- Test 5: skip when outside allowed directories ---
test_skip_when_outside_allowed() {
  echo "T5: skip when outside allowed directories"
  (
    setup_mock_env
    source_hook
    local outside
    outside=$(mktemp -d)
    mkdir -p "$outside/.git"
    cd "$outside" || exit 1
    _agent_gates_codegraph_should_init
    result=$?
    assert "returns non-zero outside allowed dirs" "$([[ $result -ne 0 ]] && echo true || echo false)"
    rm -rf "$outside"
    teardown_mock_env
  )
}

# --- Test 6: skip when lock file exists ---
test_skip_when_locked() {
  echo "T6: skip when lock file exists (duplicate prevention)"
  (
    setup_mock_env
    source_hook
    cd "$MOCK_PROJECT/myrepo" || exit 1
    # Create lock dir for this repo (atomic mkdir lock)
    local repo_hash
    repo_hash=$(echo -n "$(pwd -P)" | md5 2>/dev/null || echo -n "$(pwd -P)" | md5sum | cut -d' ' -f1)
    mkdir "$AGENT_GATES_CODEGRAPH_LOCKDIR/codegraph-init-${repo_hash}.lock"
    _agent_gates_codegraph_should_init
    result=$?
    assert "returns non-zero when locked" "$([[ $result -ne 0 ]] && echo true || echo false)"
    teardown_mock_env
  )
}

# --- Test 7: should init when all conditions met ---
test_should_init_when_all_clear() {
  echo "T7: should init when all conditions met"
  (
    setup_mock_env
    source_hook
    cd "$MOCK_PROJECT/myrepo" || exit 1
    _agent_gates_codegraph_should_init
    result=$?
    assert "returns zero when all conditions met" "$([[ $result -eq 0 ]] && echo true || echo false)"
    teardown_mock_env
  )
}

# --- Test 8: multiple allowed dirs (colon-separated) ---
test_multiple_allowed_dirs() {
  echo "T8: respects colon-separated allowed dirs"
  (
    setup_mock_env
    source_hook
    local extra
    extra=$(mktemp -d)
    mkdir -p "$extra/repo2/.git"
    export AGENT_GATES_CODEGRAPH_DIRS="$MOCK_PROJECT:$extra"
    cd "$extra/repo2" || exit 1
    _agent_gates_codegraph_should_init
    result=$?
    assert "allows repo in second dir" "$([[ $result -eq 0 ]] && echo true || echo false)"
    rm -rf "$extra"
    teardown_mock_env
  )
}

# --- Test 9: git worktree (.git is a file, not dir) ---
test_git_worktree_file() {
  echo "T9: detects git worktree (.git is a file)"
  (
    setup_mock_env
    source_hook
    local wt="$MOCK_PROJECT/worktree-repo"
    mkdir -p "$wt"
    echo "gitdir: /some/path" > "$wt/.git"
    cd "$wt" || exit 1
    _agent_gates_codegraph_should_init
    result=$?
    assert "returns zero for .git file (worktree)" "$([[ $result -eq 0 ]] && echo true || echo false)"
    teardown_mock_env
  )
}

# --- Run all tests ---
echo "=== codegraph-chpwd.zsh tests ==="
echo ""

test_skip_when_disabled
test_skip_when_no_codegraph
test_skip_when_not_git
test_skip_when_already_indexed
test_skip_when_outside_allowed
test_skip_when_locked
test_should_init_when_all_clear
test_multiple_allowed_dirs
test_git_worktree_file

echo ""
read -r PASS_COUNT FAIL_COUNT < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS_COUNT pass · $FAIL_COUNT fail"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1

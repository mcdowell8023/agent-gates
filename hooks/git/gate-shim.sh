#!/usr/bin/env bash
# agent-gates per-project gate shim (v1.9.0+).
#
# Installed into a project as `.githooks/agent-quality-gate.sh`. Instead of a frozen
# full copy of the gate, this thin shim DELEGATES to the globally-installed authority
# gate — so `install.sh --upgrade` upgrades EVERY project at once, no per-project
# re-init. (Pre-v1.9.0 projects had a full copy that went stale on each release.)
#
# If agent-gates isn't installed here (e.g. a teammate's machine without it), the
# commit is NOT blocked — consistent with the AGENT_MODE=1 "humans pass through"
# design: the gate only constrains agents, which run where agent-gates is installed.
#
# AGENT_GATES_GATE overrides the authority path (used by tests).
# Source: https://github.com/mcdowell8023/agent-gates

AUTH="${AGENT_GATES_GATE:-$HOME/.agent-gates/hooks/git/agent-quality-gate.sh}"

if [[ -x "$AUTH" ]]; then
  # exec preserves exit code, signals, stdout/stderr — identical semantics to running
  # the authority gate directly. cwd is the repo root (git invokes the hook there), so
  # the gate's relative paths (.agent/, openspec/, features/, git diff) resolve correctly.
  exec "$AUTH" "$@"
fi

echo "agent-gates: authority gate not found at $AUTH — skipping (install agent-gates to enable the quality gate)" >&2
exit 0

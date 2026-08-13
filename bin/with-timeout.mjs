#!/usr/bin/env node
// with-timeout.mjs <secs> <cmd> [args...]
// Cross-platform timeout wrapper (Node API — works on macOS/Linux/Windows).
// macOS has no `timeout` command (GNU coreutils); agent-gates already requires Node ≥18,
// so this is the only portable option across all three platforms.
//
// On timeout the whole process group is killed, not just the direct child — see the
// comment at the spawn call for why that distinction decides whether the timeout works.
//
// Exit codes:
//   124  command timed out (same convention as GNU timeout)
//   127  command not found
//   130  interrupted (SIGINT forwarded to the child's group)
//   143  terminated (SIGTERM forwarded to the child's group)
//   *    child's exit code (transparent pass-through)
//
// Source: https://github.com/mcdowell8023/agent-gates
import { spawn } from 'node:child_process';
import { constants } from 'node:os';
const { signals } = constants;
const argv = process.argv.slice(2);
if (argv.length < 2) {
  process.stderr.write('Usage: with-timeout.mjs <seconds> <command> [args...]\n');
  process.exit(1);
}
const secs = Number(argv[0]);
const [cmd, ...args] = argv.slice(1);
// detached:true makes the child its own process-group leader so the timeout can kill
// the whole group. Killing only the direct child is not enough: grandchildren inherit
// the child's stdout, so a caller using command substitution — `raw=$(with-timeout ...)`
// — keeps blocking on the still-open pipe and the timeout accomplishes nothing. That is
// exactly how a review invocation ran for 80 minutes despite a timeout being in place.
const child = spawn(cmd, args, { stdio: 'inherit', detached: true });

const killGroup = (signal) => {
  try { process.kill(-child.pid, signal); }
  catch { try { child.kill(signal); } catch {} }
};

let handled = false;
const t = setTimeout(() => { handled = true; killGroup('SIGKILL'); process.exit(124); }, secs * 1000);

// detached also detaches the child from the terminal's foreground process group, so
// Ctrl-C would no longer reach it — forward the signals explicitly.
//
// Forward and then WAIT for the group to actually die. Exiting the moment the signal is
// sent would leave a group that ignores or defers it still running, still holding the
// inherited stdout — which is precisely the hang this wrapper exists to prevent.
// Escalate to SIGKILL if the group has not exited within the grace period.
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    if (handled) return;
    handled = true;
    clearTimeout(t);
    const code = sig === 'SIGINT' ? 130 : 143;
    killGroup(sig);
    const grace = setTimeout(() => { killGroup('SIGKILL'); process.exit(code); }, 3000);
    child.on('exit', () => { clearTimeout(grace); process.exit(code); });
  });
}

// A signal-terminated child reports code === null. Returning a flat 1 there would hide
// the difference between "the command failed" and "the command was killed", so preserve
// the 128+signal convention instead.
child.on('exit', (code, signal) => {
  clearTimeout(t);
  if (handled) return;   // the signal path above owns its own exit code
  if (code != null) { process.exit(code); }
  const n = signal ? signals[signal] : undefined;
  process.exit(n ? 128 + n : 1);
});
child.on('error', () => { clearTimeout(t); process.exit(127); });

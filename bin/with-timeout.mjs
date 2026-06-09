#!/usr/bin/env node
// with-timeout.mjs <secs> <cmd> [args...]
// Cross-platform timeout wrapper (Node API — works on macOS/Linux/Windows).
// macOS has no `timeout` command (GNU coreutils); agent-gates already requires Node ≥18,
// so this is the only portable option across all three platforms.
//
// Exit codes:
//   124  command timed out (same convention as GNU timeout)
//   127  command not found
//   *    child's exit code (transparent pass-through)
//
// Source: https://github.com/mcdowell8023/agent-gates
import { spawn } from 'node:child_process';
const argv = process.argv.slice(2);
if (argv.length < 2) {
  process.stderr.write('Usage: with-timeout.mjs <seconds> <command> [args...]\n');
  process.exit(1);
}
const secs = Number(argv[0]);
const [cmd, ...args] = argv.slice(1);
const child = spawn(cmd, args, { stdio: 'inherit' });
const t = setTimeout(() => { try { child.kill('SIGKILL'); } catch {} ; process.exit(124); }, secs * 1000);
child.on('exit', (c) => { clearTimeout(t); process.exit(c == null ? 1 : c); });
child.on('error', () => { clearTimeout(t); process.exit(127); });

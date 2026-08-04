# Independent verification

- `git diff --cached --check`: exit 0.
- `bash -n bin/agent-gates-review hooks/git/agent-quality-gate.sh tests/run_gate.sh tests/run_review_cmd.sh`: exit 0.
- `tests/run_gate.sh`: 51 pass, 0 fail.
- `tests/run_review_cmd.sh`: 57 pass, 0 fail.
- Content-anchor coverage includes file-set BLOCK, covered-byte WARN, negative-verdict precedence, and checkout-refreshed legacy review rejection.

VERIFY_TOOL: opencode/oc-review
VERIFY_MODEL: github-copilot/gemini-3.1-pro-preview
VERIFY_VERDICT: PASS

#!/usr/bin/env bash
# lib/oc-serve.sh — DEPRECATED shim (v2.0.0).
# This file is a compatibility shim. The library has moved to lib/hetero/serve.sh.
# This shim will be removed in a future minor version.
echo "[agent-gates] lib/oc-serve.sh is deprecated, moved to lib/hetero/serve.sh" >&2
source "${BASH_SOURCE[0]%/*}/hetero/serve.sh"

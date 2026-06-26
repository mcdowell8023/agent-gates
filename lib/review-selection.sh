#!/usr/bin/env bash
# lib/review-selection.sh — DEPRECATED shim (v2.0.0).
# This file is a compatibility shim. The library has moved to lib/hetero/select.sh.
# This shim will be removed in a future minor version.
echo "[agent-gates] lib/review-selection.sh is deprecated, moved to lib/hetero/select.sh" >&2
source "${BASH_SOURCE[0]%/*}/hetero/select.sh"

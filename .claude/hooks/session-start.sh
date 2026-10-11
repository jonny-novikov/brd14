#!/bin/bash
# SessionStart hook (Claude Code cloud sessions only): provisions the pinned
# brd14 toolchains via scripts/setup.sh and puts them on PATH for the session.
# Synchronous on purpose: tests and parity runs need every toolchain present.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
"$ROOT/scripts/setup.sh" core >&2

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo ". \"$ROOT/scripts/env.sh\"" >> "$CLAUDE_ENV_FILE"
fi

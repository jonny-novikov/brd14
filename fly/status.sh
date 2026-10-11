#!/usr/bin/env bash
# status.sh — what the brd-build app Machine serves. Fly keeps one app Machine per deploy (a
# deploy re-seeds an app scaled to zero), so it is put to use: it reports what this image is —
# the pinned toolchains and the jobs scripts/ci.sh runs — and fly.toml stops it when idle.
# The suite itself runs in the release command's temporary Machine, not here.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p /tmp/brd-status
{
  echo "<!doctype html><meta charset=utf-8><title>brd-build</title><pre>"
  echo "brd-build — the brd14 CI image (docs/ci.md)"
  echo "The suite runs once per deploy as the release command: scripts/ci.sh."
  echo
  echo "Toolchains:"
  scripts/ci.sh --versions
  echo
  echo "Jobs:"
  scripts/ci.sh --list
  echo "</pre>"
} >/tmp/brd-status/index.html
exec python3 -m http.server 8080 --bind :: --directory /tmp/brd-status

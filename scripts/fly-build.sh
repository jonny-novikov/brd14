#!/usr/bin/env bash
# fly-build.sh — run the CI suite on Fly by hand (the GitHub integration does it on push).
#
#   scripts/fly-build.sh                deploy brd-build: build fly/Dockerfile, run scripts/ci.sh
#                                       once as the release command; exits non-zero when it fails
#   scripts/fly-build.sh run JOB...     a one-off Machine for some jobs, removed when it exits;
#                                       follow it with `fly logs -a brd-build`
#   scripts/fly-build.sh setup          create the app (once), then deploy
#
# Needs flyctl, logged in (`fly auth login`) or FLY_API_TOKEN set (`fly tokens create deploy -a
# brd-build`). BRD_FLY_APP overrides the app name; BRD_FLY_REGION the region for `setup`.
set -euo pipefail
cd "$(dirname "$0")/.."
app=${BRD_FLY_APP:-brd-build}
case ${1:-} in -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
fly=$(command -v fly || command -v flyctl) || { echo "fly-build: flyctl not found (https://fly.io/docs/flyctl/install/)" >&2; exit 2; }

case ${1:-deploy} in
  deploy)
    shift $(($# > 0))
    exec "$fly" deploy --app "$app" --remote-only "$@"
    ;;
  run)
    shift
    exec "$fly" machine run --app "$app" --dockerfile fly/Dockerfile --rm \
      --vm-size performance-8x --vm-memory 32768 --env BRD_CI_TMPFS=20g . scripts/ci.sh "$@"
    ;;
  setup)
    "$fly" apps create "$app" || echo "fly-build: app $app exists (or create it in the dashboard)"
    exec "$fly" deploy --app "$app" --remote-only ${BRD_FLY_REGION:+--primary-region "$BRD_FLY_REGION"}
    ;;
  *) echo "fly-build: unknown command '$1' (deploy | run JOB... | setup)" >&2; exit 64 ;;
esac

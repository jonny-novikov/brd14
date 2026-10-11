#!/usr/bin/env bash
# ci.sh — the brd14 CI suite: every tree's tests, gates and hardening, then the parity run.
#
# One script wherever the suite runs: a laptop, a container, or the Fly app brd-build — where
# fly.toml makes it the deploy's release_command, run once on a temporary Machine from the new
# image, a non-zero exit stopping the deploy (docs/ci.md).
#
#   scripts/ci.sh                  every job, in order (oracle docs go native harden python ts ex parity)
#   scripts/ci.sh go ex parity     only these jobs, in this order
#   scripts/ci.sh --list           the jobs and what each runs
#   scripts/ci.sh --versions       the toolchains this environment provides
#
# Every selected job runs even after one fails; a summary follows, and the exit status is the
# number of failed jobs (0 = green). BRD_CI_TMPFS=<size> (e.g. 20g), on a Linux VM where you are
# root, first copies the tree into a RAM disk and runs there: a Fly Machine's root filesystem is
# about 8 GB and slow to write, and the Rust, Go and Miri builds write gigabytes.
set -uo pipefail
export LC_ALL=C.UTF-8
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

JOBS=(oracle docs go native harden python ts ex parity)
declare -A WHAT=(
  [oracle]="oracle + champ oracle self-tests, parity harness self-test, vectors reproducible, the shell CLI"
  [docs]="the KAN documentation contract: frontmatter, ids, #toc, explicit anchors, navigation, every link (tools/doclint.py)"
  [go]="vet, tests, race, fuzz smoke (pinned Go), then vet + tests on the floor toolchain"
  [native]="C cores (tests, gates, sanitizers), Rust workspace (tests, clippy, alloc-check), the NIF link check"
  [harden]="Miri (core, ffi, wasm ABI) and libFuzzer (differential speed vs memory, 20 s per target)"
  [python]="pytest on every installed CPython (3.12, 3.13, 3.14, 3.14t with the GIL off)"
  [ts]="npm ci, typecheck, vitest on Node, bun test on Bun, frozen-intrinsics smoke"
  [ex]="echo_data: compile --warnings-as-errors, suite with the NIF and pure, harden, the Hex package built alone"
  [parity]="every shim vs the oracle (--require: a missing shim fails)"
)

job_oracle() {
  local py out
  py=$(command -v python3.14 || command -v python3)
  "$py" tools/oracle.py
  "$py" tools/champ_oracle.py
  "$py" tools/parity.py --self-test
  out=$(mktemp -d)
  "$py" tools/vectorgen.py --out "$out" >/dev/null
  # (no `cmd && echo` in a job: set -e does not fire on the left of &&, so a failure would pass)
  diff -r vectors "$out"
  echo "vectors: reproducible from the oracle"
  rm -rf "$out"
  make -C scripts test harden
}

job_docs() { python3 tools/doclint.py; }

job_go() {
  cd go
  go vet ./...
  go test -count=1 ./...
  go test -race -count=1 ./...
  go test -run '^$' -fuzz '^FuzzParse$' -fuzztime 10s .
  go test -run '^$' -fuzz '^FuzzAppendEncode$' -fuzztime 10s .
  GOTOOLCHAIN="go${GO_FLOOR_VERSION}" go vet ./...
  GOTOOLCHAIN="go${GO_FLOOR_VERSION}" go test -count=1 ./...
}

job_native() {
  make -C native/c test gates harden
  make -C native/rust test
  make -C native/rust clippy alloc-check
  make -C native/beam check
}

job_harden() {
  make -C native/rust miri
  make -C native/c fuzz FUZZ_SECONDS=20
}

job_python() { make -C python test; }

job_ts() {
  (cd ts && npm ci --no-audit --no-fund --silent)
  make -C ts test harden
}

job_ex() { make -C ex test harden package-check; }

job_parity() { python3 tools/parity.py --require --json build/parity.json; }

versions() {
  local v
  for v in "go version" "env GOTOOLCHAIN=go${GO_FLOOR_VERSION} go version" "python3.14 -V" "python3.14t -V" \
           "python3.13 -V" "python3.12 -V" "node --version" "bun --version" "rustc --version" \
           "rustc +nightly --version" "clang-18 --version" "elixir --version" "make --version"; do
    printf '%-40s %s\n' "$v" "$($v 2>/dev/null | grep -v '^$' | grep -v 'Erlang/OTP.*\[' | head -1 || echo absent)"
  done
  printf '%-40s %s\n' "erlang otp_release" "$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo absent)"
}

# ── the RAM disk (Fly Machines) ─────────────────────────────────────────────
if [[ -n ${BRD_CI_TMPFS:-} && -z ${BRD_CI_IN_TMPFS:-} ]]; then
  if [[ $(id -u) == 0 ]] && mkdir -p /work && mount -t tmpfs -o "size=${BRD_CI_TMPFS}" tmpfs /work 2>/dev/null; then
    echo "ci: running in a ${BRD_CI_TMPFS} RAM disk (/work)"
    cp -a "$root/." /work/brd14
    BRD_CI_IN_TMPFS=1 GOCACHE=/work/cache/go-build exec bash /work/brd14/scripts/ci.sh "$@"
  fi
  echo "ci: BRD_CI_TMPFS is set but a tmpfs cannot be mounted here; running in place" >&2
fi

cd "$root"
. scripts/env.sh
export BRD14_REQUIRE_VECTORS=1

case ${1:-} in
  --list) for j in "${JOBS[@]}"; do printf '%-8s %s\n' "$j" "${WHAT[$j]}"; done; exit 0 ;;
  --versions) versions; exit 0 ;;
  -h | --help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

selected=("$@")
((${#selected[@]})) || selected=("${JOBS[@]}")
for j in "${selected[@]}"; do
  [[ -n ${WHAT[$j]:-} ]] || { echo "ci: unknown job '$j' (scripts/ci.sh --list)" >&2; exit 64; }
done

echo "ci: brd14 at $(git rev-parse --short HEAD 2>/dev/null || echo "${BRD_CI_COMMIT:-unknown commit}") — jobs: ${selected[*]}"
versions | sed 's/^/ci: /'

declare -A STATUS SECONDS_OF
failed=0
for j in "${selected[@]}"; do
  echo
  echo "════ ci: ${j} — ${WHAT[$j]}"
  start=$SECONDS
  (set -e; "job_${j}")
  rc=$?
  SECONDS_OF[$j]=$((SECONDS - start))
  if ((rc == 0)); then STATUS[$j]=PASS; else STATUS[$j]="FAIL ($rc)"; failed=$((failed + 1)); fi
  echo "════ ci: ${j} ${STATUS[$j]} in ${SECONDS_OF[$j]}s"
done

echo
echo "ci: summary"
for j in "${selected[@]}"; do printf 'ci:   %-8s %-10s %5ss\n' "$j" "${STATUS[$j]}" "${SECONDS_OF[$j]}"; done
if ((failed)); then echo "ci: ${failed} job(s) failed"; else echo "ci: all green"; fi
exit "$failed"

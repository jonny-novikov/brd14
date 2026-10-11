#!/bin/sh
# fuzzcov.sh — source coverage of each core, replaying the fuzz corpora
# (run by `make fuzz-cov`, after `make fuzz` has grown them).
#
#   fuzz/fuzzcov.sh <build-dir> <corpus-dir>
#
# One core is instrumented per run: both cores export identically named
# functions (branded_encode, ...), and in a single llvm profile their records
# would collide and merge. The other cores are linked uninstrumented, so the
# fuzz targets' differential checks still run exactly as under `make fuzz`.
set -eu
B=$1/fuzzcov
CORPUS=$2
CLANG=${CLANG:-clang}
PROFDATA=${LLVM_PROFDATA:-llvm-profdata}
COV=${LLVM_COV:-llvm-cov}
FLAGS="-g -fprofile-instr-generate -fcoverage-mapping"
INC=-I../include

ren() {
  objcopy --redefine-sym "branded_encode=$1_branded_encode" --redefine-sym "branded_decode=$1_branded_decode" \
    --redefine-sym "branded_hash32=$1_branded_hash32" --redefine-sym "branded_unix_ms=$1_branded_unix_ms" "$2" "$3"
}

for which in speed memory; do
  d=$B/$which
  rm -rf "$d"
  mkdir -p "$d"
  fs=""; fm=""
  [ "$which" = speed ] && fs=$FLAGS
  [ "$which" = memory ] && fm=$FLAGS
  # shellcheck disable=SC2086 # word splitting of the flag lists is intended
  $CLANG -std=c11 -O2 -fPIC $fs $INC -c speed/branded_id.c -o "$d/speed.o"
  # shellcheck disable=SC2086
  $CLANG -std=c11 -Os -fPIC $fm $INC -c memory/branded_id.c -o "$d/memory.o"
  $CLANG -std=c11 -Os -fPIC -DBRANDED_NO_INT128 $INC -c memory/branded_id.c -o "$d/memory_noint128.o"
  for c in speed memory memory_noint128; do ren "$c" "$d/$c.o" "$d/$c.ren.o"; done
  for t in fuzz_decode fuzz_encode; do
    $CLANG -std=c11 -O2 -fprofile-instr-generate -fsanitize=fuzzer $INC "fuzz/$t.c" \
      "$d/speed.ren.o" "$d/memory.ren.o" "$d/memory_noint128.ren.o" -o "$d/$t"
    LLVM_PROFILE_FILE="$d/$t.profraw" "$d/$t" -runs=0 "$CORPUS/$t" > "$d/$t.log" 2>&1
  done
  $PROFDATA merge -o "$d/all.profdata" "$d"/*.profraw
  echo "== $which core, regions per function (fuzz_decode + fuzz_encode corpora)"
  $COV report --show-functions "$d/fuzz_decode" -object "$d/fuzz_encode" -instr-profile="$d/all.profdata" \
    "$which/branded_id.c" 2>/dev/null |
    awk '$1 ~ /^(branded_|branded_id\.c:)/ { sub(/^branded_id\.c:/, "", $1); printf "  %-16s %3d regions, %d missed\n", $1, $2, $3 }
         $1 == "TOTAL" { printf "  %-16s %3d regions, %d missed (%s)\n", "total", $2, $3, $4 }'
done

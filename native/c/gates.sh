#!/bin/sh
# gates.sh — object-code gates for the C cores (run by `make gates`).
#
#   gates.sh <build-dir> <variant>...
#
# Each gate checks a property of the machine code that ships, not of the
# source, so a compiler or flag change that silently breaks it fails here:
#
#   (a) no div/idiv anywhere in a core's .text — branded_encode and
#       branded_decode plus any static helper the compiler kept out of line —
#       because every divisor is a constant and must be strength-reduced
#       (speed: by gcc at -O2; memory: by hand, since gcc -Os emits `div`).
#       The detector proves itself first on a probe that must contain one.
#   (b) no allocator in any core's undefined symbols (`nm -u`); the memory
#       core must have no undefined symbols at all (no libc calls).
#   (c) the footprint, from `size -A`: .text and .rodata (all .rodata*
#       sections) per core, written to <build-dir>/gates/size.txt. The memory
#       core must carry 0 bytes of .rodata (no tables); no core may have
#       .data or .bss (no mutable state, so every entry point is reentrant).
set -eu

BUILD=$1
shift
OBJDUMP=${OBJDUMP:-objdump}
NM=${NM:-nm}
SIZE=${SIZE:-size}
CC=${CC:-gcc}
OUT=$BUILD/gates
mkdir -p "$OUT"
fail=0
DIV_RE='[[:space:]]i?div[bwlq]?[[:space:]]'

bad() { echo "FAIL gates: $*"; fail=1; }

# ── (a) the detector must find a div where there certainly is one ─────────
printf 'unsigned probe(unsigned x, unsigned y) { return x / y; }\n' > "$OUT/probe.c"
"$CC" -O2 -c "$OUT/probe.c" -o "$OUT/probe.o"
if [ "$("$OBJDUMP" -d --no-show-raw-insn "$OUT/probe.o" | grep -cE "$DIV_RE" || true)" -lt 1 ]; then
  bad "div detector found nothing in a runtime division probe"
fi
# Informational: does this compiler emit div for a CONSTANT divisor at -Os?
printf 'unsigned probe(unsigned x) { return x / 62u; }\n' > "$OUT/probe_os.c"
"$CC" -Os -c "$OUT/probe_os.c" -o "$OUT/probe_os.o"
os_divs=$("$OBJDUMP" -d --no-show-raw-insn "$OUT/probe_os.o" | grep -cE "$DIV_RE" || true)
echo "gates: $CC -Os emits $os_divs div for x / 62u (why the memory core writes its reciprocals out)"

echo "gates (a): div/idiv per function"
printf '  %-8s %-18s %6s %5s\n' core function insns divs
for v in "$@"; do
  obj=$BUILD/$v/branded_id.o
  "$OBJDUMP" -d --no-show-raw-insn "$obj" > "$OUT/$v.dis"
  # one row per function: name, instruction count, div count
  awk -v re="$DIV_RE" '
    /^[0-9a-f]+ <[^>]+>:$/ { fn = $2; gsub(/[<>:]/, "", fn); order[++n] = fn; next }
    fn != "" && /^ +[0-9a-f]+:/ { ins[fn]++; if ($0 ~ re) divs[fn]++ }
    END { for (i = 1; i <= n; i++) printf "%s %d %d\n", order[i], ins[order[i]], divs[order[i]] + 0 }
  ' "$OUT/$v.dis" > "$OUT/$v.funcs"
  while read -r fn ins divs; do
    printf '  %-8s %-18s %6s %5s\n' "$v" "$fn" "$ins" "$divs"
    [ "$divs" -eq 0 ] || bad "$v: $divs div/idiv in $fn"
  done < "$OUT/$v.funcs"
  for fn in branded_encode branded_decode; do
    n=$(awk -v f="$fn" '$1 == f { print $2 }' "$OUT/$v.funcs")
    [ "${n:-0}" -gt 5 ] || bad "$v: $fn missing or empty in the disassembly (gate would be vacuous)"
  done
done

# ── (b) no allocator; the memory core links against nothing ──────────────
echo "gates (b): undefined symbols (nm -u)"
for v in "$@"; do
  obj=$BUILD/$v/branded_id.o
  undef=$("$NM" -u "$obj" | awk '{ print $NF }' | tr '\n' ' ')
  printf '  %-8s %s\n' "$v" "${undef:-(none)}"
  for s in $undef; do
    case $s in
      malloc | calloc | realloc | free | reallocarray | aligned_alloc | posix_memalign | memalign | \
      valloc | pvalloc | strdup | strndup | __libc_malloc | _Znwm | _Znam)
        bad "$v references allocator symbol $s" ;;
    esac
  done
  if [ "$v" = memory ] && [ -n "$undef" ]; then bad "memory core must not call libc: $undef"; fi
done

# ── (c) footprint ─────────────────────────────────────────────────────────
echo "gates (c): footprint (size -A, bytes)"
printf '%-8s %8s %8s %6s %6s\n' core .text .rodata .data .bss > "$OUT/size.txt"
for v in "$@"; do
  obj=$BUILD/$v/branded_id.o
  "$SIZE" -A "$obj" | awk -v v="$v" '
    $1 == ".text" || $1 ~ /^\.text\./ { t += $2 }
    $1 ~ /^\.rodata/ { r += $2 }
    $1 == ".data" || $1 ~ /^\.data\./ { d += $2 }
    $1 == ".bss" || $1 ~ /^\.bss\./ { b += $2 }
    END { printf "%-8s %8d %8d %6d %6d\n", v, t, r, d, b }
  ' >> "$OUT/size.txt"
done
sed 's/^/  /' "$OUT/size.txt"
while read -r v t r d b; do
  [ "$v" = core ] && continue
  [ "$d" -eq 0 ] && [ "$b" -eq 0 ] || bad "$v has mutable state (.data $d, .bss $b)"
  if [ "$v" = memory ] && [ "$r" -ne 0 ]; then bad "memory core has $r bytes of .rodata (tables)"; fi
done < "$OUT/size.txt"

if [ "$fail" -ne 0 ]; then
  echo "gates: FAIL"
  exit 1
fi
echo "gates: ok ($*)"

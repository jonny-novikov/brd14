#!/usr/bin/env bash
# test_brd.sh — the behaviour of scripts/brd.sh and scripts/mint.sh that the
# parity run cannot see: minting, settings precedence, the census, the CLI
# surface. (The codec itself is proven against the oracle by tools/parity.py,
# shim sh-bash.) Fast: a few seconds.
#
#   bash scripts/test_brd.sh
set -u -o pipefail
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=${here%/*}
BRD=("bash" "$here/brd.sh")
MINT=("bash" "$here/mint.sh")
pass=0 fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*" >&2; }
eq() { if [[ $2 == "$3" ]]; then ok; else no "$1: got [$2] want [$3]"; fi; }
rc() { local want=$1; shift; "$@" >/dev/null 2>&1; local got=$?; eq "exit of $*" "$got" "$want"; }

# ── frozen vectors through the human CLI ────────────────────────────────────
eq "V-1 encode" "$("${BRD[@]}" --no-rc encode USR 274557032793636864)" USR0KHTOWnGLuC
eq "V-2 decode" "$("${BRD[@]}" --no-rc decode --as int USR0NgWEfAEJfs)" 320636799581945856
eq "V-6 hash32" "$("${BRD[@]}" --no-rc hash USR0KHTOWnGLuC)" 234878118
eq "E-1 date" "$("${BRD[@]}" --no-rc date USR0KHTOWnGLuC)" 2026-01-27T15:11:37.641Z
eq "E-2 date by snowflake" "$("${BRD[@]}" --no-rc date 320636799581945856)" 2026-06-03T18:56:10.164Z
eq "N-1 node" "$("${BRD[@]}" --no-rc node hosta 100)" 585
eq "at == V-1 (node 0, seq 0 at that instant)" "$("${BRD[@]}" --no-rc at 2026-01-27T15:11:37.641Z USR)" USR0KHTOWnGLuC
eq "at -> date round-trip" "$("${BRD[@]}" --no-rc at 2026-06-03T18:56:10.164Z | "${BRD[@]}" --no-rc date -)" 2026-06-03T18:56:10.164Z
eq "hex" "$("${BRD[@]}" --no-rc decode --as hex USR0KHTOWnGLuC)" 03cf6c2aaa400000

if [[ -f $root/vectors/valid.tsv ]]; then
  n=0 bad=0
  while IFS=$'\t' read -r ns snow id h _; do
    [[ $ns == \#* ]] && continue
    out=$("${BRD[@]}" --no-rc encode "$ns" "$snow")
    [[ $out == "$id" ]] || bad=$((bad + 1))
    n=$((n + 1)); ((n >= 64)) && break
  done <"$root/vectors/valid.tsv"
  eq "valid.tsv encode (64 rows)" "$bad" 0
elif [[ -n ${BRD14_REQUIRE_VECTORS:-} ]]; then
  no "vectors/ absent but BRD14_REQUIRE_VECTORS is set"
fi

# ── refusal classes and exit codes ──────────────────────────────────────────
eq "valid classes" "$("${BRD[@]}" --no-rc valid USR0KHTOWnGLuC usr0KHTOWnGLuC USRzzzzzzzzzzz USR0KHTOWnGLu 'USR0KHTOWnGLu!' | cut -f1 | tr '\n' ,)" \
  "OK,ERR NAMESPACE,ERR RANGE,ERR LENGTH,ERR CHARSET,"
rc 0 "${BRD[@]}" --no-rc valid -q USR0KHTOWnGLuC
rc 1 "${BRD[@]}" --no-rc valid -q USR0KHTOWnGLuC usr0KHTOWnGLuC
rc 1 "${BRD[@]}" --no-rc encode usr 1
rc 1 "${BRD[@]}" --no-rc encode USR 9223372036854775808
rc 0 "${BRD[@]}" --no-rc encode USR 9223372036854775807
rc 2 "${BRD[@]}" --no-rc frobnicate
rc 2 "${BRD[@]}" --no-rc --as yaml mint

# ── minting ─────────────────────────────────────────────────────────────────
ids=$("${BRD[@]}" --no-rc mint 2000 --node 613)
eq "mint 2000: count" "$(wc -l <<<"$ids" | tr -d ' ')" 2000
eq "mint 2000: unique" "$(sort -u <<<"$ids" | wc -l | tr -d ' ')" 2000
if sort -c <<<"$ids" 2>/dev/null; then ok; else no "mint 2000: byte order != mint order"; fi
eq "mint: node pinned" "$("${BRD[@]}" --no-rc mint --node 613 --as json | grep -o '"node":[0-9]*')" '"node":613'
# A frozen clock: 5000 mints in "one millisecond" must still be strictly
# increasing, borrowing into the timestamp after seq 4095.
burst=$(BRD_FAKE_NOW_MS=1769526697641 "${BRD[@]}" --no-rc mint 5000 --node 1 --as int)
if sort -n -c <<<"$burst" 2>/dev/null && [[ $(sort -u <<<"$burst" | wc -l) -eq 5000 ]]; then ok; else no "burst: not strictly increasing"; fi
eq "burst: 4097th id borrows into ts" "$(BRD_FAKE_NOW_MS=1769526697641 "${BRD[@]}" --no-rc mint 4097 --node 1 --as tsv | sed -n 4097p | cut -f4-6 | tr '\t' ' ')" \
  "65459497642 1 0"

# ── mint.sh shorthand ───────────────────────────────────────────────────────
eq "mint" "$(BRD_NO_RC=1 "${MINT[@]}" | cut -c1-3)" KAN
eq "mint 3" "$(BRD_NO_RC=1 "${MINT[@]}" 3 | wc -l | tr -d ' ')" 3
eq "mint ORD" "$(BRD_NO_RC=1 "${MINT[@]}" ORD | cut -c1-3)" ORD
eq "mint ORD 2" "$(BRD_NO_RC=1 "${MINT[@]}" ORD 2 | cut -c1-3 | sort -u)" ORD
ln -s "$here/mint.sh" "$tmp/mint"
eq "mint via symlink" "$(BRD_NO_RC=1 "$tmp/mint" 2 | wc -l | tr -d ' ')" 2

# ── settings: precedence, walk-up, safety ───────────────────────────────────
mkdir -p "$tmp/proj/a/b" "$tmp/xdg/brd"
printf 'ns = AAA\ncount = 2\n' >"$tmp/proj/.brdrc"
printf 'ns = XDG\ntz = local\n' >"$tmp/xdg/brd/config"
run() { (cd "$1" && shift && HOME=$tmp XDG_CONFIG_HOME=$tmp/xdg "$@"); }
eq "walk-up finds the nearest .brdrc" "$(run "$tmp/proj/a/b" "${BRD[@]}" mint | cut -c1-3 | sort -u)" AAA
eq "rc count" "$(run "$tmp/proj/a/b" "${BRD[@]}" mint | wc -l | tr -d ' ')" 2
eq "user config under the project rc" "$(run "$tmp/proj" "${BRD[@]}" config | awk '$1=="tz"{print $2}')" local
eq "user config alone" "$(run "$tmp" "${BRD[@]}" mint | cut -c1-3)" XDG
eq "env beats rc" "$(run "$tmp/proj" env BRD_NS=ENV "${BRD[@]}" mint -n 1 | cut -c1-3)" ENV
eq "flag beats env" "$(run "$tmp/proj" env BRD_NS=ENV "${BRD[@]}" mint --ns FLG -n 1 | cut -c1-3)" FLG
eq "argument beats flag" "$(run "$tmp/proj" "${BRD[@]}" mint --ns FLG ARG -n 1 | cut -c1-3)" ARG
eq "--no-rc: built-in default" "$(run "$tmp/proj" "${BRD[@]}" --no-rc mint | cut -c1-3)" KAN
eq "config shows the origin" "$(run "$tmp/proj/a" "${BRD[@]}" config | awk '$1=="ns"{print $3}')" "$tmp/proj/.brdrc:1"
printf 'ns = $(touch %s/pwned)\n' "$tmp" >"$tmp/evil.brdrc"
rc 2 env BRD_CONFIG="$tmp/evil.brdrc" "${BRD[@]}" mint
if [[ -e $tmp/pwned ]]; then no "a .brdrc executed code"; else ok; fi
printf 'colour = blue\nns = BBB\n' >"$tmp/warn.brdrc"
eq "unknown key: warned, rest applied" "$(BRD_CONFIG=$tmp/warn.brdrc "${BRD[@]}" mint 2>/dev/null | cut -c1-3)" BBB
eq "bad value names file:line" "$(printf 'node = 4096\n' >"$tmp/bad.brdrc"; BRD_CONFIG=$tmp/bad.brdrc "${BRD[@]}" mint 2>&1 >/dev/null | grep -c 'bad.brdrc:1')" 1

# ── census: the gate runs first ─────────────────────────────────────────────
rc 3 "${BRD[@]}" --no-rc --census "KAN ORD" mint USR
rc 3 "${BRD[@]}" --no-rc --census "KAN ORD" mint usr # off-census AND malformed: the policy refusal wins
rc 0 "${BRD[@]}" --no-rc --census "KAN, ORD" mint ORD
rc 1 "${BRD[@]}" --no-rc mint usr

# ── init ────────────────────────────────────────────────────────────────────
(cd "$tmp" && "${BRD[@]}" init QQQ >/dev/null)
eq "init writes a working rc" "$(cd "$tmp" && "${BRD[@]}" mint | cut -c1-3)" QQQ
rc 2 bash -c "cd '$tmp' && bash '$here/brd.sh' init QQQ"

printf 'test_brd: %d passed, %d failed\n' "$pass" "$fail"
((fail == 0))

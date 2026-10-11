#!/usr/bin/env bash
# brd — brd14 ids from the shell. Pure bash (>= 4.2), no dependencies.
#
#   brd mint [NS] [N]           mint 1 (or N) ids, strictly increasing
#   brd encode NS SNOW          snowflake -> id
#   brd decode ID... | -        id -> ns, snowflake, ts, node, seq, unix_ms, date
#   brd date ID|SNOW... | -     the mint instant (ISO-8601, ms)
#   brd at DATE [NS]            the smallest id minted at/after DATE (a range-scan cursor)
#   brd valid ID... | -         exit 0 when every id is valid; prints the refusal class
#   brd hash ID|SNOW...         the contract's hash32 (trie placement)
#   brd node [HOST PID]         the node id derived from host + pid (FNV-32a & 1023)
#   brd config                  every setting, its value, and where it came from
#   brd init [NS]               write a commented .brdrc here
#   brd conform                 the parity shim (docs/contract.md § Parity shim protocol)
#
# Settings resolve flags > environment (BRD_*) > the nearest .brdrc (walking up
# from the working directory) > $XDG_CONFIG_HOME/brd/config > built-in defaults.
# Config files are PARSED, never sourced: a .brdrc in a cloned repository cannot
# run code on your machine.
#
# The contract (docs/contract.md) is the spec; tools/parity.py proves this file
# byte-identical to the oracle (`brd conform` is shim "sh-bash").

set -u -o pipefail
export LC_ALL=C # strings are bytes: ${#s} counts bytes, ${s:i:1} is one byte

readonly BRD_VERSION=0.1.0
readonly ALPHABET=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz
readonly EPOCH_MS=1704067200000
readonly MAX_SNOW=9223372036854775807 # 2^63 - 1
readonly P62_6=56800235584            # 62^6
readonly QA=162382637 RB=503620799    # 2^63 - 1 == QA * 62^6 + RB: the arithmetic range guard
readonly M32=4294967295
readonly CLASS_NAMES=(OK LENGTH NAMESPACE CHARSET RANGE)
PROG=${0##*/}
PROG=${PROG%.sh}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# ── the codec ───────────────────────────────────────────────────────────────
# Results travel in globals (R_*): bash functions return status codes only, and
# a subshell per call would cost a fork per id.

# is_u64 S: S is a decimal string. dec_lt_2_63 S: its value is < 2^63.
# Range is checked TEXTUALLY so a value >= 2^63 never reaches $(( )), where it
# would overflow.
is_u64() { [[ $1 =~ ^[0-9]+$ ]]; }
dec_lt_2_63() {
  local s=${1##+(0)}
  shopt -s extglob; s=${1##+(0)}; shopt -u extglob
  [[ -z $s ]] && return 0
  (( ${#s} < 19 )) && return 0
  (( ${#s} > 19 )) && return 1
  [[ ! $s > $MAX_SNOW ]]
}

# ns_ok_bytes A B C: three bytes of A-Z.
ns_ok_bytes() {
  (( $# == 3 && $1 >= 65 && $1 <= 90 && $2 >= 65 && $2 <= 90 && $3 >= 65 && $3 <= 90 ))
}

# encode_snow SNOW (decimal < 2^63) -> R_PAYLOAD, the 11 base62 digits.
encode_snow() {
  local -i v=$((10#$1)) i d
  local out=
  for ((i = 0; i < 11; i++)); do
    d=$((v % 62)); v=$((v / 62))
    out=${ALPHABET:d:1}$out
  done
  R_PAYLOAD=$out
}

# decode_bytes: reads the byte values in the global array B.
# Sets R_CODE (0 = OK, else the class index), R_NS and R_SNOW on success.
# Precedence: LENGTH, NAMESPACE, CHARSET, RANGE (namespace-first, docs/contract.md).
decode_bytes() {
  local -i n=${#B[@]} i v d hi=0 lo=0
  R_NS= R_SNOW=
  if (( n != 14 )); then R_CODE=1; return; fi
  if ! ns_ok_bytes "${B[0]}" "${B[1]}" "${B[2]}"; then R_CODE=2; return; fi
  for ((i = 3; i < 14; i++)); do
    v=${B[i]}
    if ((v >= 48 && v <= 57)); then d=$((v - 48))
    elif ((v >= 65 && v <= 90)); then d=$((v - 55))
    elif ((v >= 97 && v <= 122)); then d=$((v - 61))
    else R_CODE=3; return; fi
    if ((i < 8)); then hi=$((hi * 62 + d)); else lo=$((lo * 62 + d)); fi
  done
  if ! ((hi < QA || (hi == QA && lo <= RB))); then R_CODE=4; return; fi
  printf -v R_NS '%b' "\\x$(printf '%02x' "${B[0]}")\\x$(printf '%02x' "${B[1]}")\\x$(printf '%02x' "${B[2]}")"
  R_SNOW=$((hi * P62_6 + lo))
  R_CODE=0
}

# str_bytes S -> B: the bytes of S (LC_ALL=C makes every char one byte).
str_bytes() {
  local s=$1 c
  local -i i v
  B=()
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    printf -v v '%d' "'$c"
    ((v < 0)) && v=$((v + 256))
    B+=("$v")
  done
}

# hex_bytes H -> B ("-" is empty).
hex_bytes() {
  local h=$1
  local -i i
  B=()
  [[ $h == - ]] && return
  for ((i = 0; i < ${#h}; i += 2)); do B+=("$((16#${h:i:2}))"); done
}

# u64_limbs DEC -> R_HI R_LO: any decimal in [0, 2^64) as two 32-bit limbs
# (wrapping mod 2^64), with no intermediate above 2^37.
u64_limbs() {
  local s=$1
  local -i i hi=0 lo=0
  for ((i = 0; i < ${#s}; i++)); do
    lo=$((lo * 10 + ${s:i:1}))
    hi=$(((hi * 10 + (lo >> 32)) & M32))
    lo=$((lo & M32))
  done
  R_HI=$hi R_LO=$lo
}

# mul32 A B -> R_MH R_ML: the full 64-bit product of two 32-bit values, via
# 16-bit halves so no partial product exceeds 2^48.
mul32() {
  local -i a0=$(($1 & 65535)) a1=$(($1 >> 16)) b0=$(($2 & 65535)) b1=$(($2 >> 16))
  local -i p00=$((a0 * b0)) mid=$((a0 * b1 + a1 * b0)) p11=$((a1 * b1)) low
  low=$((p00 + ((mid & 65535) << 16)))
  R_ML=$((low & M32))
  R_MH=$(((p11 + (mid >> 16) + (low >> 32)) & M32))
}

# hash32 DEC -> R_HASH: MurmurHash3 fmix64, first half, truncated (contract V-6).
hash32() {
  local -i hi lo h2 l2
  u64_limbs "$1"; hi=$R_HI lo=$R_LO
  lo=$((lo ^ (hi >> 1)))                       # k ^= k >> 33
  mul32 "$lo" 3981806797; l2=$R_ML h2=$R_MH    # lo * 0xED558CCD
  mul32 "$lo" 4283543511; h2=$(((h2 + R_ML) & M32)) # + lo * 0xFF51AFD7 (mod 2^32)
  mul32 "$hi" 3981806797; h2=$(((h2 + R_ML) & M32)) # + hi * 0xED558CCD (mod 2^32)
  R_HASH=$((l2 ^ (h2 >> 1)))                   # k ^= k >> 33, low 32 bits
}

# node_from_bytes PID (host bytes in B) -> R_NODE: FNV-32a(host ++ pid) & 1023.
node_from_bytes() {
  local -i h=2166136261 i b
  local pid=$1
  for b in "${B[@]}"; do h=$((((h ^ b) * 16777619) & M32)); done
  for ((i = 0; i < ${#pid}; i++)); do
    printf -v b '%d' "'${pid:i:1}"
    h=$((((h ^ b) * 16777619) & M32))
  done
  R_NODE=$((h & 1023))
}

# ── the parity shim ─────────────────────────────────────────────────────────
conform() {
  local op a b out
  printf 'HELLO sh bash EDHUFN\n'
  while IFS=' ' read -r op a b; do
    case $op in
      E)
        hex_bytes "$a"
        if (( ${#B[@]} != 3 )) || ! ns_ok_bytes "${B[@]}"; then out='ERR NAMESPACE'
        elif ! dec_lt_2_63 "$b"; then out='ERR RANGE'
        else
          encode_snow "$b"
          printf -v out 'OK %b%s' "\\x${a:0:2}\\x${a:2:2}\\x${a:4:2}" "$R_PAYLOAD"
        fi ;;
      D)
        hex_bytes "$a"; decode_bytes
        if ((R_CODE)); then out="ERR ${CLASS_NAMES[R_CODE]}"; else out="OK $R_NS $R_SNOW"; fi ;;
      H) hash32 "$a"; out="OK $R_HASH" ;;
      U) out="OK $(((10#$a >> 22) + EPOCH_MS))" ;;
      F) out="OK $((10#$a >> 22)) $(((10#$a >> 12) & 1023)) $((10#$a & 4095))" ;;
      N) hex_bytes "$a"; node_from_bytes "$b"; out="OK $R_NODE" ;;
      '') continue ;;
      *) printf '%s: unknown request %q\n' "$PROG" "$op" >&2; exit 2 ;;
    esac
    printf '%s\n' "$out"
  done
}

# ── settings ────────────────────────────────────────────────────────────────
# One table: key -> value and key -> origin. Precedence is applied by loading
# the weakest source first and letting each stronger source overwrite.
declare -A CFG=([ns]=KAN [node]=auto [as]=auto [count]=1 [census]= [tz]=utc)
declare -A ORIGIN=([ns]=default [node]=default [as]=default [count]=default [census]=default [tz]=default)
readonly CFG_KEYS=(ns node as count census tz)

# check_setting KEY VALUE: the whitelist and its validation, shared by every source.
check_setting() {
  local k=$1 v=$2
  case $k in
    ns) [[ $v =~ ^[A-Z]{3}$ ]] || { echo "ns must be 3 letters A-Z (got '$v')"; return 1; } ;;
    node) [[ $v == auto || ($v =~ ^[0-9]{1,4}$ && 10#$v -le 1023) ]] || { echo "node must be 'auto' or 0..1023 (got '$v')"; return 1; } ;;
    as) [[ $v =~ ^(auto|id|int|hex|json|tsv|pretty)$ ]] || { echo "as must be one of auto id int hex json tsv pretty (got '$v')"; return 1; } ;;
    count) [[ $v =~ ^[0-9]{1,7}$ && 10#$v -ge 1 ]] || { echo "count must be 1..9999999 (got '$v')"; return 1; } ;;
    census) [[ -z $v || $v =~ ^[A-Z]{3}([[:space:],]+[A-Z]{3})*$ ]] || { echo "census must be namespaces separated by commas or spaces (got '$v')"; return 1; } ;;
    tz) [[ $v =~ ^(utc|local)$ ]] || { echo "tz must be 'utc' or 'local' (got '$v')"; return 1; } ;;
    *) echo "unknown key '$k'"; return 3 ;;
  esac
}

set_setting() { # KEY VALUE ORIGIN
  local msg rc
  msg=$(check_setting "$1" "$2"); rc=$?
  if ((rc == 3)); then warn "$3: $msg (ignored)"; return 0; fi
  ((rc)) && die "$3: $msg"
  CFG[$1]=$2 ORIGIN[$1]=$3
}

# load_rc FILE: `key = value` lines; '#' or ';' start a comment. Parsed, never sourced.
load_rc() {
  local file=$1 line key val
  local -i n=0
  [[ -r $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n+=1
    line=${line%%[#;]*}
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    if [[ $line =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
      key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
      set_setting "$key" "$val" "$file:$n"
    else
      die "$file:$n: expected 'key = value'"
    fi
  done <"$file"
}

# find_rc: the nearest .brdrc from the working directory up to /.
find_rc() {
  local d=$PWD
  while :; do
    [[ -f $d/.brdrc ]] && { R_RC=$d/.brdrc; return 0; }
    [[ -z $d || $d == / ]] && return 1
    d=${d%/*}; [[ -z $d ]] && d=/
  done
}

load_settings() {
  local k var
  if [[ -z ${BRD_NO_RC:-} ]]; then
    load_rc "${XDG_CONFIG_HOME:-$HOME/.config}/brd/config"
    if [[ -n ${BRD_CONFIG:-} ]]; then load_rc "$BRD_CONFIG"
    elif find_rc; then load_rc "$R_RC"; fi
  fi
  for k in "${CFG_KEYS[@]}"; do
    var=BRD_${k^^}
    [[ -n ${!var:-} ]] && set_setting "$k" "${!var}" "env $var"
  done
}

# ── time ────────────────────────────────────────────────────────────────────
# now_ms -> R_NOW: wall-clock Unix milliseconds. EPOCHREALTIME (bash 5) costs no
# fork; older shells fall back to GNU date, python3, then perl.
now_ms() {
  local t=${EPOCHREALTIME:-}
  if [[ -n $t ]]; then
    local s=${t%[.,]*} f=${t#*[.,]}000
    R_NOW=$((10#$s * 1000 + 10#${f:0:3}))
    return
  fi
  t=$(date +%s%3N 2>/dev/null)
  if [[ ! $t =~ ^[0-9]{13,}$ ]]; then
    t=$(python3 -c 'import time; print(time.time_ns() // 1000000)' 2>/dev/null) ||
      t=$(perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null) ||
      die "no millisecond clock (needs bash 5, GNU date, python3 or perl)"
  fi
  R_NOW=$t
}

# iso_ms MS -> R_ISO: 2026-01-27T15:11:37.641Z (UTC) or with the local offset.
iso_ms() {
  local -i ms=$1 sec=$(($1 / 1000)) frac=$(($1 % 1000))
  local d z
  if [[ ${CFG[tz]} == local ]]; then
    printf -v d '%(%Y-%m-%dT%H:%M:%S)T' "$sec"
    printf -v z '%(%z)T' "$sec"
    printf -v R_ISO '%s.%03d%s:%s' "$d" "$frac" "${z:0:3}" "${z:3:2}"
  else
    TZ=UTC0 printf -v d '%(%Y-%m-%dT%H:%M:%S)T' "$sec"
    printf -v R_ISO '%s.%03dZ' "$d" "$frac"
  fi
}

# parse_when DATE -> R_WHEN (Unix ms). Accepts: now, unix ms (13+ digits),
# @unix-seconds, or anything GNU/BSD date understands (ISO-8601, "1 hour ago").
parse_when() {
  local w=$1 s
  case $w in
    now) now_ms; R_WHEN=$R_NOW; return ;;
    @*) [[ ${w#@} =~ ^[0-9]+$ ]] || die "bad epoch seconds '$w'"; R_WHEN=$((10#${w#@} * 1000)); return ;;
  esac
  if [[ $w =~ ^[0-9]{13,}$ ]]; then R_WHEN=$((10#$w)); return; fi
  if s=$(date -u -d "$w" +%s%3N 2>/dev/null) && [[ $s =~ ^[0-9]+$ ]]; then R_WHEN=$((10#$s)); return; fi
  if s=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$w" +%s 2>/dev/null); then R_WHEN=$((10#$s * 1000)); return; fi
  die "cannot read date '$w' (try ISO-8601, @<unix seconds>, <unix ms> or now)"
}

# ── output ──────────────────────────────────────────────────────────────────
# emit ID SNOW: one record in the configured format. "auto" means pretty on a
# terminal and tab-separated in a pipe, except for mint, whose auto is the id.
emit() {
  local id=$1 snow=$2 fmt=$3
  local -i ts=$((snow >> 22)) node=$(((snow >> 12) & 1023)) seq=$((snow & 4095)) ms
  ms=$((ts + EPOCH_MS))
  case $fmt in
    id) printf '%s\n' "$id" ;;
    int) printf '%s\n' "$snow" ;;
    hex) printf '%016x\n' "$snow" ;;
    tsv) iso_ms "$ms"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${id:0:3}" "$snow" "$ts" "$node" "$seq" "$ms" "$R_ISO" ;;
    json) iso_ms "$ms"
      printf '{"id":"%s","ns":"%s","snow":%s,"ts":%s,"node":%s,"seq":%s,"unix_ms":%s,"date":"%s"}\n' \
        "$id" "${id:0:3}" "$snow" "$ts" "$node" "$seq" "$ms" "$R_ISO" ;;
    pretty) iso_ms "$ms"
      printf '%s\n  ns       %s\n  snow     %s\n  date     %s\n  unix_ms  %s\n  ts       %s\n  node     %s\n  seq      %s\n' \
        "$id" "${id:0:3}" "$snow" "$R_ISO" "$ms" "$ts" "$node" "$seq" ;;
  esac
}

resolve_fmt() { # DEFAULT_FOR_PIPE
  local f=${CFG[as]}
  if [[ $f == auto ]]; then if [[ -t 1 ]]; then f=pretty; else f=$1; fi; fi
  R_FMT=$f
}

# ── commands ────────────────────────────────────────────────────────────────
cmd_mint() {
  local ns=${CFG[ns]} a
  local -i count=$((10#${CFG[count]})) node cell=0 now part i snow
  for a in "${ARGS[@]}"; do
    if [[ $a =~ ^[0-9]+$ ]]; then count=$((10#$a))
    else ns=$a; ORIGIN[ns]=argument; fi
  done
  ((count >= 1)) || die "count must be at least 1"
  # The gate runs FIRST, on the raw namespace, like Minter: a census refusal is
  # the more specific diagnostic (exit 3), and it quotes what was asked for.
  if [[ -n ${CFG[census]} ]]; then
    local c=" ${CFG[census]//,/ } "
    [[ $c == *" $ns "* ]] || { printf '%s: refusing to mint %q: not in the census (%s, from %s)\n' "$PROG" "$ns" "${CFG[census]}" "${ORIGIN[census]}" >&2; exit 3; }
  fi
  [[ $ns =~ ^[A-Z]{3}$ ]] || { printf '%s: invalid namespace %q: NAMESPACE (3 letters A-Z)\n' "$PROG" "$ns" >&2; exit 1; }
  if [[ ${CFG[node]} == auto ]]; then
    str_bytes "${HOSTNAME:-}"; node_from_bytes "$$"; node=$R_NODE
  else node=$((10#${CFG[node]})); fi
  resolve_fmt id; [[ $R_FMT == pretty && $count -gt 1 ]] && R_FMT=id
  # The generator cell holds ts<<12|seq and advances to max(now, last + 1):
  # strictly increasing within the call, a burst past 4096/ms borrows into ts,
  # a backward clock step keeps minting off the logical clock.
  for ((i = 0; i < count; i++)); do
    now_ms; part=$(((R_NOW - EPOCH_MS) << 12))
    cell=$((part > cell ? part : cell + 1))
    snow=$(((cell >> 12) << 22 | node << 12 | (cell & 4095)))
    encode_snow "$snow"
    emit "$ns$R_PAYLOAD" "$snow" "$R_FMT"
  done
}

cmd_encode() {
  ((${#ARGS[@]} == 2)) || die "usage: $PROG encode NS SNOWFLAKE"
  local ns=${ARGS[0]} snow=${ARGS[1]}
  [[ $ns =~ ^[A-Z]{3}$ ]] || { printf '%s: NAMESPACE: %q is not 3 letters A-Z\n' "$PROG" "$ns" >&2; exit 1; }
  is_u64 "$snow" || die "snowflake must be a non-negative decimal (got '$snow')"
  dec_lt_2_63 "$snow" || { printf '%s: RANGE: %s is not below 2^63\n' "$PROG" "$snow" >&2; exit 1; }
  encode_snow "$snow"
  resolve_fmt id; [[ $R_FMT == pretty ]] && R_FMT=id
  emit "$ns$R_PAYLOAD" "$((10#$snow))" "$R_FMT"
}

# each_input FN: run FN on every argument, or on every stdin line for "-" / no args in a pipe.
each_input() {
  local fn=$1 x
  local -i bad=0
  if ((${#ARGS[@]} == 0)) || [[ ${ARGS[0]} == - ]]; then
    [[ -t 0 && ${#ARGS[@]} -eq 0 ]] && die "usage: $PROG ${CMD} ID... (or pipe ids on stdin)"
    while IFS= read -r x || [[ -n $x ]]; do [[ -z $x ]] && continue; "$fn" "$x" || bad=1; done
  else
    for x in "${ARGS[@]}"; do "$fn" "$x" || bad=1; done
  fi
  return $bad
}

decode_one() {
  str_bytes "$1"; decode_bytes
  if ((R_CODE)); then printf '%s: %s: %q\n' "$PROG" "${CLASS_NAMES[R_CODE]}" "$1" >&2; return 1; fi
  emit "$1" "$R_SNOW" "$R_FMT"
}
cmd_decode() { resolve_fmt tsv; each_input decode_one; }

# A token is an id when it decodes; a bare decimal below 2^63 is a snowflake.
snow_of() {
  if [[ $1 =~ ^[0-9]+$ ]]; then
    dec_lt_2_63 "$1" || { printf '%s: RANGE: %s\n' "$PROG" "$1" >&2; return 1; }
    R_SNOW=$((10#$1)); return 0
  fi
  str_bytes "$1"; decode_bytes
  ((R_CODE == 0)) || { printf '%s: %s: %q\n' "$PROG" "${CLASS_NAMES[R_CODE]}" "$1" >&2; return 1; }
}
date_one() { snow_of "$1" || return 1; iso_ms "$(((R_SNOW >> 22) + EPOCH_MS))"; printf '%s\n' "$R_ISO"; }
cmd_date() { each_input date_one; }
hash_one() { snow_of "$1" || return 1; hash32 "$R_SNOW"; printf '%s\n' "$R_HASH"; }
cmd_hash() { each_input hash_one; }

VALID_QUIET=
valid_one() {
  str_bytes "$1"; decode_bytes
  if ((R_CODE)); then
    [[ -z $VALID_QUIET ]] && printf 'ERR %s\t%s\n' "${CLASS_NAMES[R_CODE]}" "$1"
    return 1
  fi
  [[ -z $VALID_QUIET ]] && printf 'OK\t%s\n' "$1"
  return 0
}
cmd_valid() { each_input valid_one; }

cmd_at() {
  ((${#ARGS[@]} >= 1 && ${#ARGS[@]} <= 2)) || die "usage: $PROG at DATE [NS]"
  local ns=${ARGS[1]:-${CFG[ns]}}
  [[ $ns =~ ^[A-Z]{3}$ ]] || { printf '%s: NAMESPACE: %q\n' "$PROG" "$ns" >&2; exit 1; }
  parse_when "${ARGS[0]}"
  local -i t=$((R_WHEN - EPOCH_MS))
  ((t >= 0 && t < (1 << 41))) || die "date is outside the brd14 epoch window [2024-01-01Z, +2^41 ms)"
  local -i snow=$((t << 22))
  encode_snow "$snow"
  resolve_fmt id; [[ $R_FMT == pretty ]] && R_FMT=id
  emit "$ns$R_PAYLOAD" "$snow" "$R_FMT"
}

cmd_node() {
  if ((${#ARGS[@]} == 2)); then
    [[ ${ARGS[1]} =~ ^[0-9]+$ ]] || die "pid must be a decimal"
    str_bytes "${ARGS[0]}"; node_from_bytes "${ARGS[1]}"
    printf '%s\n' "$R_NODE"
  elif ((${#ARGS[@]} == 0)); then
    if [[ ${CFG[node]} != auto ]]; then printf '%s\t(pinned by %s)\n' "${CFG[node]}" "${ORIGIN[node]}"; return; fi
    str_bytes "${HOSTNAME:-}"; node_from_bytes "$$"
    printf '%s\t(derived: host %s, pid %s; each process derives its own, residual ~1/1024 per same-host pair)\n' "$R_NODE" "${HOSTNAME:-?}" "$$"
  else die "usage: $PROG node [HOST PID]"; fi
}

cmd_config() {
  local k
  for k in "${CFG_KEYS[@]}"; do printf '%-7s %-12s %s\n' "$k" "${CFG[$k]:-(none)}" "${ORIGIN[$k]}"; done
}

cmd_init() {
  local ns=${ARGS[0]:-${CFG[ns]}} f=.brdrc
  [[ $ns =~ ^[A-Z]{3}$ ]] || die "namespace must be 3 letters A-Z (got '$ns')"
  [[ -e $f && -z $FORCE ]] && die "$f exists (use --force to overwrite)"
  cat >"$f" <<EOF
# .brdrc — defaults for the brd / mint commands (brd14 ids).
# Parsed, never sourced. Precedence: flags > BRD_* env > nearest .brdrc > ~/.config/brd/config.
# Inspect the effective values and where each came from with:  brd config

# Default namespace: 3 letters A-Z. The brand IS the type.
ns = $ns

# Node id 0..1023, or auto (FNV-32a over hostname + pid). Pin it when ids must stay
# attributable to one minter, or when two processes on one host mint concurrently.
node = auto

# Output: auto (pretty on a terminal, tsv in a pipe; ids for mint) | id | int | hex | json | tsv | pretty
as = auto

# How many ids 'mint' prints when no count is given.
count = 1

# Namespaces this project may mint (the census). Empty = any well-formed namespace.
# A namespace outside it is refused before minting (exit 3), like a Minter gate.
census =

# Dates: utc | local
tz = utc
EOF
  printf 'wrote %s (ns = %s)\n' "$f" "$ns"
}

usage() {
  cat <<EOF
$PROG $BRD_VERSION — brd14 ids from the shell (14 bytes: 3-letter namespace + base62 snowflake)

usage: $PROG <command> [args] [options]

  mint [NS] [N]          mint 1 or N ids (strictly increasing)       mint 5 · mint ORD 3
  encode NS SNOWFLAKE    snowflake -> id                              encode USR 274557032793636864
  decode ID... | -       id -> ns, snowflake, date, ts, node, seq     decode USR0KHTOWnGLuC
  date ID|SNOW... | -    the mint instant, ISO-8601 with ms           date USR0KHTOWnGLuC
  at DATE [NS]           smallest id at/after DATE (scan cursor)      at 2026-01-01T00:00:00Z
  valid ID... | -        exit 0 when every id is valid                valid -q USR0KHTOWnGLuC
  hash ID|SNOW...        hash32 (trie placement)
  node [HOST PID]        the derived node id
  config                 effective settings and their origin
  init [NS]              write a commented .brdrc here
  conform                parity shim (tools/parity.py)

options:
  --ns NS                namespace (mint, at)
  -n, --count N          how many ids to mint
  --as FORMAT            auto | id | int | hex | json | tsv | pretty
  --node N|auto          pin the node id (0..1023)
  --census "A, B"        namespaces mint may use
  --local / --utc        dates in local time or UTC
  -q, --quiet            valid: exit status only
  --no-rc                ignore every .brdrc and the user config
  --force                init: overwrite
  -h, --help · -V, --version

Exit status: 0 ok · 1 an id or namespace was refused (the class is printed) ·
2 usage or config error · 3 refused by the census.
Settings: flags > BRD_NS, BRD_NODE, BRD_AS, BRD_COUNT, BRD_CENSUS, BRD_TZ > nearest .brdrc >
\${XDG_CONFIG_HOME:-~/.config}/brd/config > defaults.
EOF
}

main() {
  local -a flags=()
  ARGS=() CMD= FORCE=
  while (($#)); do
    case $1 in
      -h | --help) usage; exit 0 ;;
      -V | --version) printf '%s %s\n' "$PROG" "$BRD_VERSION"; exit 0 ;;
      --no-rc) BRD_NO_RC=1 ;;
      --force) FORCE=1 ;;
      -q | --quiet) VALID_QUIET=1 ;;
      --local) flags+=(tz local) ;;
      --utc) flags+=(tz utc) ;;
      --ns | -n | --count | --as | --node | --census)
        (($# >= 2)) || die "$1 needs a value"
        case $1 in --ns) flags+=(ns "$2") ;; -n | --count) flags+=(count "$2") ;; --as) flags+=(as "$2") ;;
          --node) flags+=(node "$2") ;; --census) flags+=(census "$2") ;; esac
        shift ;;
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
      -) ARGS+=(-) ;;
      -*) die "unknown option '$1' (see $PROG --help)" ;;
      *) if [[ -z $CMD ]]; then CMD=$1; else ARGS+=("$1"); fi ;;
    esac
    shift
  done
  [[ -z $CMD ]] && { usage; exit 2; }
  if [[ $CMD == conform ]]; then conform; exit 0; fi
  load_settings
  local -i i
  for ((i = 0; i < ${#flags[@]}; i += 2)); do set_setting "${flags[i]}" "${flags[i + 1]}" "flag --${flags[i]}"; done
  case $CMD in
    mint) cmd_mint ;;
    encode) cmd_encode ;;
    decode) cmd_decode ;;
    date) cmd_date ;;
    at) cmd_at ;;
    valid) cmd_valid ;;
    hash) cmd_hash ;;
    node) cmd_node ;;
    config) cmd_config ;;
    init) cmd_init ;;
    help) usage ;;
    version) printf '%s %s\n' "$PROG" "$BRD_VERSION" ;;
    *) die "unknown command '$CMD' (see $PROG --help)" ;;
  esac
}

main "$@"

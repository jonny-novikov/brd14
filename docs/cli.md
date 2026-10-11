# The shell tools: `brd` and `mint`

[`scripts/brd.sh`](../scripts/brd.sh) is a complete brd14 implementation in pure bash (≥ 4.2, no
dependencies). [`scripts/mint.sh`](../scripts/mint.sh) is its shorthand for minting. Both read their
defaults from [`.brdrc`](../.brdrc). The codec is proven byte-identical to the oracle: the parity run
registers `brd conform` as shim **sh-bash**, which handles 30,651 requests with 0 mismatches.

## Install

```bash
ln -s "$PWD/scripts/brd.sh"  ~/.local/bin/brd
ln -s "$PWD/scripts/mint.sh" ~/.local/bin/mint      # mint resolves its symlink to find brd.sh
```

## Mint

```bash
mint                       # KAN0R9P5pHj8mu          one id, ns from .brdrc
mint 5                     # five ids, strictly increasing within the call
mint ORD                   # ORD0R9P5pUg1Kq
mint ORD 3 --as json       # {"id":"ORD…","ns":"ORD","snow":…,"ts":…,"node":…,"seq":…,"unix_ms":…,"date":"…"}
brd mint --node 7 -n 1000  # a pinned node (0..1023)
```

Minting follows the contract's generator. One cell holds `ts<<12|seq` and advances to
`max(now, last+1)`:
- ids are strictly increasing within a call;
- a burst past 4096 ids/ms borrows into the timestamp;
- a backward clock step keeps minting off the logical clock.

Across calls, uniqueness rests on the node. With `node = auto` each process derives its own (FNV-32a
over hostname + pid), with a residual collision of about 1 in 1024 per same-host process pair. Pin
`node` when several processes mint at once on one host, or when ids must stay attributable.

## Inspect

```bash
brd decode USR0KHTOWnGLuC          # pretty on a terminal, tab-separated in a pipe
brd decode --as json USR0NgWEfAEJfs
brd date USR0KHTOWnGLuC            # 2026-01-27T15:11:37.641Z     (--local for your offset)
brd date 274557032793636864        # the same, from the snowflake
brd valid USR0KHTOWnGLuC usr0KHTOWnGLuC   # OK / ERR NAMESPACE; exit 1 if any is refused
brd valid -q "$id" && echo ok      # exit status only
brd hash USR0KHTOWnGLuC            # 234878118 (hash32, trie placement)
brd node                           # this process's derived node; brd node HOST PID computes one
mint 1000 | brd valid -q -         # every command takes ids on stdin with '-'
```

## Convert

```bash
brd encode USR 274557032793636864  # USR0KHTOWnGLuC
brd decode --as int USR0KHTOWnGLuC # 274557032793636864
brd decode --as hex USR0KHTOWnGLuC # 03cf6c2aaa400000
```

`--as` is the analogue of uuid7's `as_type`:

| Value | Output |
|---|---|
| `id` | the 14-character id |
| `int` | the snowflake in decimal |
| `hex` | the snowflake as 16 hex digits |
| `json` | the full record |
| `tsv` | `id ns snow ts node seq unix_ms date` |
| `pretty` | one field per line |
| `auto` | ids for mint/encode/at; for decode, pretty on a terminal and tsv in a pipe |

## Time-range scans

Byte order equals time order between milliseconds, so the smallest id of an instant is a cursor:

```bash
brd at 2026-10-01T00:00:00Z ORD    # ORD0QsNVlAaY6a — use as  WHERE id >= 'ORD0QsNVlAaY6a'
brd at "1 hour ago"                # anything GNU/BSD date understands, @unix-seconds, unix ms, now
```

## Settings: `.brdrc`

| Key | Values | Default | Meaning |
|---|---|---|---|
| `ns` | 3 letters A-Z | `KAN` | default namespace |
| `node` | `auto` or `0..1023` | `auto` | pin the node, or derive it from host + pid |
| `as` | `auto id int hex json tsv pretty` | `auto` | output format |
| `count` | `1..9999999` | `1` | ids per `mint` when no count is given |
| `census` | namespaces separated by commas or spaces | empty (any) | namespaces `mint` may use |
| `tz` | `utc` or `local` | `utc` | how dates print |

**Precedence, strongest first:**
1. flags (`--ns`, `--as`, `--node`, `--count`, `--census`, `--local`);
2. environment (`BRD_NS`, `BRD_NODE`, `BRD_AS`, `BRD_COUNT`, `BRD_CENSUS`, `BRD_TZ`);
3. the nearest `.brdrc`, walking up from the working directory;
4. `${XDG_CONFIG_HOME:-~/.config}/brd/config`;
5. built-in defaults.

`BRD_CONFIG=<file>` reads that file instead of searching; `--no-rc` or `BRD_NO_RC=1` reads none.
`brd config` prints every key with its value and the file:line, env var or flag it came from.

**The census is a gate, and it runs first.** `mint` refuses a namespace outside it before checking
its shape, so `mint usr` under `census = KAN ORD` is a policy refusal (exit 3), not a NAMESPACE
error. That is the same precedence as the Go `Minter`. `encode` and `decode` are codec operations
and are never gated.

**Safe by design.** The file is **parsed, never sourced**: each line is `key = value`, `#` or `;`
start a comment, and only the keys above are read, each validated. An unknown key is a warning; a
bad value is an error naming the file and line. A `.brdrc` in a repository you cloned cannot run
code on your machine; `scripts/test_brd.sh` tries exactly that and asserts nothing ran.

`brd init [NS]` writes a commented `.brdrc` in the current directory.

## Exit status

| Code | Meaning |
|---:|---|
| 0 | ok |
| 1 | an id or namespace was refused by the contract (the class is printed: LENGTH, NAMESPACE, CHARSET, RANGE) |
| 2 | a usage or configuration error |
| 3 | refused by the census |

## How it stays exact in bash

- Every snowflake is below 2⁶³, so bash's signed 64-bit `$(( ))` holds it exactly. Decimal input
  is range-checked as text before it reaches arithmetic.
- `hash32` keys can reach 2⁶⁴, so the hash runs on two 32-bit limbs with 16-bit partial products.
  No intermediate exceeds 2⁴⁹.
- `LC_ALL=C` makes every string a byte string, so classification matches the byte APIs of the other
  implementations.
- The parity shim works on byte values parsed from hex, because bash strings cannot hold NUL.
- The clock is `EPOCHREALTIME` (bash 5, no fork). Older shells fall back to GNU `date`, then
  `python3`, then `perl`.

## Tests

```bash
make -C scripts test                      # 48 checks: vectors via the CLI, exit codes, mint
                                          # monotonicity and burst, settings precedence,
                                          # untrusted rc, census, init
python3 tools/parity.py --only sh-        # the codec vs the oracle (≈ 30 s)
```

# The brd14 contract

This page is **normative**. Every implementation in this repository — Go, C (speed, memory),
Rust (speed, memory, ffi, wasm), Python, TypeScript (pure, wasm) — and the Elixir reference
outside it implement exactly what is written here. Where a page under `docs/` disagrees with
this one, this one wins. The executable form of this page is [`tools/oracle.py`](../tools/oracle.py);
the frozen form is [`vectors/`](../vectors/).

## The shape

```
USR0KHTOWnGLuC
└┬┘└─────┬────┘
 │       └─ payload: 11 chars of base62 over a 63-bit snowflake
 └───────── namespace: 3 bytes of A-Z — the brand IS the type
```

| Field | Value |
|---|---|
| Length | **14 bytes, fixed.** `3 × [A-Z]` + `11 × [0-9A-Za-z]` |
| Alphabet | `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz` — ASCII order, so byte order == numeric order |
| Snowflake layout | `ts(41) << 22 \| node(10) << 12 \| seq(12)` |
| Epoch | `1704067200000` ms — 2024-01-01T00:00:00Z |
| Domain | `[0, 2^63)` — an int64, not a full uint64 |
| Max payload | `AzL8n0Y58m7` = base62(2^63 − 1) |
| Payload width | always 11 digits, left-padded with `0`, never trimmed |

### The range guard, two equivalent forms

Because the payload is fixed-width over an ASCII-ordered alphabet, *lexicographic order equals
numeric order* (vector T-4). So "value < 2^63" can be checked either way:

- **Lexicographic** — `payload <= "AzL8n0Y58m7"` (bytewise). Used by Go `Parse` and the C/Rust speed cores.
- **Arithmetic** — split the payload at 62^6: `hi` = value of the first 5 digits, `lo` = value of the last 6.
  With `QA = 162382637` and `RB = 503620799` (since `2^63 − 1 = QA·62^6 + RB`), the value is in range iff
  `hi < QA || (hi == QA && lo <= RB)`. Used by the memory cores, Go `ParseBytes`, and TypeScript.

Both are exact and either is conforming (the "used by" lists above are informative, not
normative); the vectors pin the boundary from both sides (`AzL8n0Y58m7` accepted, `AzL8n0Y58m8` refused).

## Operations

| Operation | Definition |
|---|---|
| `encode(ns, snow) → id` | ns must be exactly 3 bytes of `A-Z`; snow must be `< 2^63`. Writes ns, then the 11 base62 digits of snow, most significant first. |
| `decode(id) → (ns, snow)` | inverse of encode; total over every byte string (never panics/throws anything but the contract error). |
| `hash32(k) → u32` | first half of MurmurHash3 `fmix64`, truncated: `k ^= k >> 33; k *= 0xFF51AFD7ED558CCD (mod 2^64); k ^= k >> 33; return k mod 2^32`. Defined on the full u64. |
| `unix_ms(snow)` | `(snow >> 22) + 1704067200000` |
| `min_for(t_ms)` | `(t_ms − 1704067200000) << 22` — the half-open lower bound for time-range scans. Defined for `t_ms` in `[epoch, epoch + 2^41)`; outside it the result is implementation-defined (Rust saturates, Go wraps) and is not parity-tested. |
| `node_of(snow)`, `seq_of(snow)` | `(snow >> 12) & 1023`, `snow & 4095` |
| `node_from(host, pid)` | FNV-32a over `host bytes ++ ASCII-decimal(pid)`, `& 1023`. Empty host hashes the pid alone. |

### The generator

A generator owns one monotonic cell holding `ts << 12 | seq` (ts relative to the epoch). Each
mint advances it to `max(now_part, last + 1)` atomically (CAS, or a lock where the runtime has no
CAS), and returns `ts << 22 | node << 12 | seq`. Consequences every implementation must keep:

- strictly increasing within one generator under every clock regime;
- a burst past 4096 ids/ms borrows into the timestamp (no blocking, no sleeping);
- a backward clock step keeps minting off the logical clock (no duplicates).

Generators are *not* differential-tested (they read the clock); each language proves these
properties in its own suite.

### The minter (policy seam)

`Minter(generator, gate)`. The gate runs **first**, on the raw namespace, and its refusal reaches
the caller **unchanged**. Only an admitted namespace reaches `encode`, whose shape check still
applies. A nil/absent gate means "no policy", never "no validation".

## Errors and precedence

Typed implementations use these classes (the C ABI's `branded_status` values):

| Code | Class | Meaning |
|---:|---|---|
| 0 | `OK` | |
| 1 | `LENGTH` | decode input is not exactly 14 bytes |
| 2 | `NAMESPACE` | namespace is not exactly 3 bytes of `A-Z` |
| 3 | `CHARSET` | a payload byte is outside the alphabet |
| 4 | `RANGE` | value outside `[0, 2^63)` |

**Precedence is namespace-first, in both directions** — the most specific, most actionable
diagnostic wins, the same rule as the minter's gate-first:

- **encode:** `NAMESPACE` → `RANGE`. A namespace of any length other than 3 is `NAMESPACE`
  (a fixed-width ABI that cannot see the length leaves that check to its caller).
- **decode:** `LENGTH` → `NAMESPACE` → `CHARSET` → `RANGE`. A payload that is both off-alphabet
  and lexicographically above the max is `CHARSET`.

Go keeps one sentinel, `ErrInvalid`, and exposes the classes as preallocated causes
(`ErrLength`, `ErrNamespace`, `ErrCharset`, `ErrRange`) whose `Is` method matches `ErrInvalid`,
so `errors.Is(err, ErrInvalid)` keeps holding and a refusal allocates nothing. Python raises `InvalidIdError(ValueError)` with `.code`; TypeScript throws
`InvalidIdError` with `.code`. The Elixir NIF maps every class to `:error`.

String-typed APIs (Python `str`, JS `string`) classify on the **UTF-8 bytes** of the input, so a
14-character string with a non-ASCII character is a `LENGTH` refusal, exactly as the byte APIs see it.

## Vectors

Frozen literals every suite asserts (Go carries them inline; everyone else via `vectors/`):

| Id | Vector |
|---|---|
| V-1 | `encode("USR", 274557032793636864) == "USR0KHTOWnGLuC"` and its inverse |
| V-2 | `decode("USR0NgWEfAEJfs") == ("USR", 320636799581945856)` |
| V-3 | `encode("ABC", 0) == "ABC00000000000"` |
| V-4 | `encode("ABC", 2^63 − 1)` payload `== "AzL8n0Y58m7"` |
| V-5 | refused: `USRzzzzzzzzzzz` (RANGE), `usr0KHTOWnGLuC` (NAMESPACE), 13 and 15 bytes (LENGTH) |
| V-6 | `hash32(274557032793636864) == 234878118` |
| V-7 | a byte-wise sort of encoded ids reproduces numeric order (incl. every alphabet index in the low digit) |
| E-1 | `unix_ms(274557032793636864) == 1769526697641` (2026-01-27T15:11:37.641Z) |
| E-2 | `unix_ms(320636799581945856) == 1780512970164` (2026-06-03T18:56:10.164Z) |
| N-1 | `node_from("hosta",100)=585`, `("hosta",101)=182`, `("hosta",4242)=290`, `("",100)=156`, `("",101)=559` |

### `vectors/` schema

Generated by `python3 tools/vectorgen.py` from the oracle (pinned seeds), committed, LF line
endings. Lines starting with `#` are comments; columns are TAB-separated; an empty byte string is
written `-`; arbitrary bytes are written as lowercase hex.

| File | Columns |
|---|---|
| `valid.tsv` | `ns  snow  id  hash32  unix_ms  ts  node  seq` |
| `invalid.tsv` | `id_hex  class` — decode refusals |
| `encode_invalid.tsv` | `ns_hex  snow  class` — encode refusals (`snow` may be ≥ 2^63) |
| `node.tsv` | `host_hex  pid  node` |

Suites that read `vectors/` **skip** when the directory is absent (published module/sdist/tarball)
and **fail** when it is absent but `BRD14_REQUIRE_VECTORS=1` is set (root Makefile, CI).

## Parity shim protocol

Every implementation ships a *shim*: a program that reads requests on stdin and writes one
response line per request on stdout. `tools/parity.py` feeds every shim the same request file and
diffs every response against the oracle.

First output line: `HELLO <impl> <variant> <ops>` — e.g. `HELLO c speed EDHUFN`; `<ops>` lists the
request letters the shim supports. Then, per request line:

| Request | Response |
|---|---|
| `E <ns_hex> <snow>` | `OK <id>` or `ERR <CLASS>` |
| `D <id_hex>` | `OK <ns> <snow>` or `ERR <CLASS>` |
| `H <k>` | `OK <hash32>` — `k` in `[0, 2^64)` |
| `U <snow>` | `OK <unix_ms>` — `snow` in `[0, 2^63)` |
| `F <snow>` | `OK <ts> <node> <seq>` — `snow` in `[0, 2^63)` |
| `N <host_hex> <pid>` | `OK <node>` |
| `L <n> <s> <m> <snow>` | `OK <ts> <node> <seq> <meta>` or `ERR LAYOUT` / `ERR RANGE` — [extension](#layout-profiles) |
| `P <n> <s> <m> <ts> <node> <seq> <meta>` | `OK <snow>` or `ERR LAYOUT` / `ERR RANGE` — [extension](#layout-profiles) |

`E D H U F N` are the base: every shim answers them. `L P` belong to an extension: a shim answers
them only when it advertises them, and `tools/parity.py` sends a shim only the ops it advertises.

Integers are unsigned decimal; `<snow>` in `E` may be any value in `[0, 2^64)`; hex is lowercase
and `-` means empty. A shim must not print anything else on stdout; diagnostics go to stderr.

## The WebAssembly ABI (`native/rust/crates/brd14-wasm`)

No imports, no allocator, fixed memory (never grows, so JS views never detach). A static 64 KiB
IO region is exposed by `io_ptr()`.

| Export | Semantics |
|---|---|
| `io_ptr() → i32` | address of the IO region |
| `encode(ns: i32, snow: i64) → i32` | `ns` = the 3 namespace bytes packed little-endian (`b0 \| b1<<8 \| b2<<16`), `0` bytes for non-ASCII/short; a non-zero fourth byte is `NAMESPACE`. `snow` = the value as i64, `-1` for anything outside `[0, 2^63)`. Writes 14 bytes at `io[0..14]`; returns the status code (0 = OK). |
| `decode(len: i32) → i64` | reads `len` bytes at `io[0..]`; returns the snowflake (≥ 0), or `−code` (−1..−4). The namespace is `io[0..3]` on success. |
| `hash32(k: i64) → i32` | as defined above (reinterpret the result as u32) |
| `encode_many(ns: i32, n: i32) → i32` | input `n` i64 at `io[0..8n]`, output `14n` bytes at `io[8n..]`; returns the count encoded before the first error |
| `decode_many(n: i32) → i32` | input `n × 14` bytes at `io[0..14n]`, output `n` i64 (same sign convention) at offset `(14n + 7) & ~7`; returns `n` |

Batch calls clamp `n` to `[0, 2978]` — the most that fits the 64 KiB IO region (`22n ≤ 65536`
plus alignment) — so a loader chunks larger batches.

## The format family

brd14's width never changes. A wider namespace is a **different format with its own name and
length**, so the length alone tells a reader which contract applies, and a brd14 parser can never
accept a wider id (it refuses with `LENGTH`).

| Format | Length | Namespace | Status |
|---|---:|---|---|
| **brd14** | 14 | `3 × [A-Z]` — the **system-reserved** census (26³ = 17,576 brands) | frozen, implemented |
| brd15 | 15 | `4 × [A-Z]` — **user space** (26⁴ = 456,976 brands) | reserved, not implemented |
| brd16 | 16 | `4 × [A-Z]` + 1 metadata char (one base62 digit, ~5.95 bits) | reserved, not implemented |

The payload (11 × base62 over the same snowflake) is identical across the family, so the epoch,
ordering, and range laws above carry over unchanged. The open design questions for brd16 — where
the metadata character sits (namespace-adjacent vs suffix), what it may mean, and why it must be
fixed at mint time — remain open (see [roadmap.md](roadmap.md)); metadata *inside* brd14's
length is the layout profile extension below. Nothing in this
section is normative for brd15/brd16 beyond the reservation of their names and lengths.

## Extensions

An extension adds operations without changing any base behaviour: every base vector, every base
parity request and every existing id keeps its answer. Extensions land in the runtimes the
Operator names; a shim advertises an extension's ops in its `HELLO` line, and the runtimes that do
not yet implement it are listed as deferred in [roadmap.md](roadmap.md). The branded structures
are the other extension, specified in [structures.md](structures.md).

### Layout profiles

A **layout profile** `(n, s, m)` re-splits the 22 bits under the timestamp into
`node(n) | seq(s) | meta(m)`, meta lowest:

```
bit 63   62 ........ 22   21 ....... s+m   s+m-1 ..... m   m-1 ..... 0
  0      ts (41 bits)     node (n bits)    seq (s bits)    meta (m bits)
```

- A profile is valid when `0 ≤ n, s, m ≤ 22` and `n + s + m = 22`. **`(10, 12, 0)` is the base
  layout**, bit for bit: `node_of`, `seq_of` and the generator are unchanged under it.
- The id is still a brd14 id: 14 bytes, the same codec, the same order, the same range. A profile
  is not recorded in the id; a reader must know the namespace's profile to split out `meta`.
  **A namespace's profile is fixed once ids exist** — bind it where the namespace policy lives
  (Go `Gate`, Elixir `EchoData.Namespace`, the CLI census).

| Operation | Definition |
|---|---|
| `fields(n, s, m, snow)` | `(snow >> 22, (snow >> (s+m)) & (2^n − 1), (snow >> m) & (2^s − 1), snow & (2^m − 1))` for `snow` in `[0, 2^63)` |
| `pack(n, s, m, ts, node, seq, meta)` | `ts << 22 \| node << (s+m) \| seq << m \| meta`, for `ts < 2^41`, `node < 2^n`, `seq < 2^s`, `meta < 2^m` |
| generator | the cell is `ts << s \| seq`, advanced to `max(now_part, last + 1)` exactly as in the base; each mint packs `(cell >> s, node, cell & (2^s − 1), meta)` |

**Errors**, in precedence order: `LAYOUT` (code 5) when the profile is invalid, then `RANGE` when
`snow ≥ 2^63` (`fields`) or a field does not fit its width (`pack`).

**Why meta is lowest:** one generator stays strictly increasing whatever meta each id carries. For
cells `c₁ < c₂` with equal timestamps, `seq₁ < seq₂`, so `seq₁·2^m + meta₁ < (seq₁ + 1)·2^m ≤
seq₂·2^m`. Meta placed above the sequence would let an id minted later in the same millisecond sort
first. The oracle's self-test mints 20 000 ids under `(6, 12, 4)` with random meta and checks it.

**Vectors:** `vectors/layout.tsv` (every valid profile × six snowflakes, both directions) and
`vectors/layout_invalid.tsv` (refusals, including both precedence orders). **Scope** (Operator
ruling): Go, Rust and Elixir, whose shims advertise `L P` once they implement it. **Deferred:** C,
Python, TypeScript, WebAssembly, bash.

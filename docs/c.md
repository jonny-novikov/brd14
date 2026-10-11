---
id: "KAN0R9YJSz0Bme"
slug: "DOCS-C"
type: "guide"
version: "1.3"
path: "docs/c.md"
title: "The C cores"
summary: "The C cores — speed and memory variants — their footprint, ABI, tests, benches and fuzzing."
tags: ["c", "speed", "memory"]
group: "implementations"
language: "en"
audience: ["developer", "agent"]
---

# The C cores

Two C11 implementations of the brd14 contract sit behind one header,
[`native/include/branded_id.h`](../native/include/branded_id.h):

| Core | Goal | Source | Built with | Tables |
|---|---|---|---|---|
| **speed** | Fewest cycles per op | [`native/c/speed/branded_id.c`](../native/c/speed/branded_id.c) | `-O2` | 8,063 B `.rodata` |
| **memory** | Smallest footprint | [`native/c/memory/branded_id.c`](../native/c/memory/branded_id.c) | `-Os` | **0 B** |

Both cores are libc-only (the memory core does not call libc at all). They allocate nothing, hold no
mutable state, and take caller-owned buffers. A consumer switches cores by linking a different object.
The header, the call sites and the observable behaviour stay the same, and the parity run holds both
cores to the oracle byte for byte.

[Index](index.md#toc) · [Contract](contract.md#toc) · [Structures](structures/README.md#toc) · [Parity](parity.md#toc) · [KAN story](kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [Layout](#layout)
- [The ABI](#abi)
- [The speed core](#speed-core)
- [The memory core](#memory-core)
- [Footprint](#footprint)
- [Tests, gates, fuzzing, sanitizers](#tests-gates-fuzzing-sanitizers)
- [Benchmarks](#benchmarks)
- [Vendoring](#vendoring)
- [Make targets](#make-targets)

<a id="layout"></a>

## Layout

| Path | What it is |
|---|---|
| `native/include/branded_id.h` | The ABI: four functions, five status codes, the precedence rules |
| `native/c/speed/branded_id.c` | Speed core: split chains, a 62×62 pair table, a 256-byte decode table, a lexicographic range guard |
| `native/c/memory/branded_id.c` | Memory core: arithmetic digit mapping, range masks, the arithmetic `(QA, RB)` guard, hand-written reciprocals |
| `native/c/test/support.h` | Shared helpers: hex, strict u64 parsing, splitmix64, the caller-level namespace wrapper, and a naive reference model |
| `native/c/test/cores.h` | Links every core into one binary through objcopy-renamed symbols |
| `native/c/test/test_vectors.c` | The frozen corpus (`vectors/*.tsv`) against one core |
| `native/c/test/test_props.c` | Property and differential suite across all cores |
| `native/c/test/conform.c` | The parity shim (`build/conform-speed`, `build/conform-memory`) |
| `native/c/bench/bench.c` | Micro-benchmarks, following the [bench protocol](../bench/README.md) |
| `native/c/gates.sh` | Object-code gates: no `div`, no allocator, footprint |
| `native/c/fuzz/` | libFuzzer targets, the dictionary, and the coverage replay |

<a id="abi"></a>

## The ABI

```c
#include "branded_id.h"

typedef enum {
  BRANDED_OK = 0, BRANDED_ERR_LENGTH = 1, BRANDED_ERR_NAMESPACE = 2,
  BRANDED_ERR_CHARSET = 3, BRANDED_ERR_RANGE = 4
} branded_status;

branded_status branded_encode(const char ns[3], uint64_t snowflake, char out[14]);
branded_status branded_decode(const char *id, size_t len, char ns_out[3], uint64_t *snowflake_out);
uint32_t       branded_hash32(uint64_t key);       /* first half of fmix64, low 32 bits */
uint64_t       branded_unix_ms(uint64_t snowflake); /* (snow >> 22) + 1704067200000 */
```

**Precedence is namespace-first in both directions** ([contract](contract.md#errors-and-precedence)):

| Call | Order | Consequence |
|---|---|---|
| `branded_encode` | `NAMESPACE` → `RANGE` | `encode("usr", 2^63)` is `NAMESPACE` |
| `branded_decode` | `LENGTH` → `NAMESPACE` → `CHARSET` → `RANGE` | `"USR!zzzzzzzzzz"` is off-alphabet and lexicographically above the maximum, so it is `CHARSET` |

**The namespace length is the caller's check.** `branded_encode` takes exactly 3 bytes and cannot see a
length. If a caller holds a namespace of variable length (bytes from a protocol, an Erlang binary, a
string), it must refuse `len != 3` as `BRANDED_ERR_NAMESPACE` before calling. Calling anyway would
read past a shorter buffer, or accept the 3-byte prefix of a longer one (`"USRR"` would pass as
`"USR"`). The parity shim, the vector test and the NIF all do this check.
[`support.h`](../native/c/test/support.h) has the wrapper:

```c
static inline branded_status brd_encode_bytes(brd_encode_fn enc, const unsigned char *ns,
                                              size_t ns_len, uint64_t snowflake, char out[14]) {
  if (ns_len != BRANDED_NS_LEN) return BRANDED_ERR_NAMESPACE;
  return enc((const char *)ns, snowflake, out);
}
```

Further guarantees, all tested:

- **Outputs only on success.** A refused call leaves `out`, `ns_out` and `*snowflake_out` untouched.
- **Totality.** `branded_decode` classifies any `len` and any byte values. It reads `id` only when
  `len == 14`, and then reads exactly 14 bytes.
- **Reentrancy.** There are no globals, no locks and no allocation, so every function is thread-safe.
- **No NUL.** `out` receives exactly 14 bytes and no terminator.

<a id="speed-core"></a>

## The speed core

**encode.** The naive encoder runs eleven u64 divmods by 62 in one serial dependency chain. The
speed core splits the value at 62^6:

- `hi = v / 62^6` holds 5 digits and is at most `QA = 162,382,637`, so it is below 2^28.
- `lo = v % 62^6` holds 6 digits.

The two halves are independent dependency chains, and the CPU overlaps them. Both chains are in
32-bit registers after their first step. Each chain then emits **two digits per divmod** through
`PAIRS`, a 62×62 table of digit pairs (7,688 bytes). That is the base-100 `itoa` technique carried to
base 62², so the chains run 2 + 2 divmods instead of 5 + 6. Every divisor is a compile-time
constant, which the compiler strength-reduces to multiply-high and shift (Granlund & Montgomery,
PLDI 1994). `make gates` proves that from the object code: zero `div` instructions.

That proof depends on `-O2`. **Built with `-Os`, gcc 13 emits five real `div`s in this encoder**,
because at `-Os` it prefers the shorter instruction. The gate catches that.

**decode.** `B62`, a 256-byte table, maps every byte to `digit + 1`, with 0 meaning invalid. Charset
validation and digit extraction therefore share one load, and invalidity is OR-folded without a
branch. The range check uses the format itself: a fixed-width base62 payload over an ASCII-ordered
alphabet sorts lexicographically. So `value < 2^63` is `memcmp(payload, "AzL8n0Y58m7") <= 0`. The
sortability property doubles as the overflow guard, and after it the accumulation (the same two
chains, recombined as `hi·62^6 + lo`) cannot wrap.

<a id="memory-core"></a>

## The memory core

The memory core has no lookup tables of any kind: no pair table, no decode table, no alphabet string
and no max-payload constant. `size -A` shows `.rodata` as 0 bytes, and `nm -u` shows no undefined
symbols, so it does not call libc.

**encode** keeps the hi/lo split at 62^6, with the two chains interleaved in one loop so that every
iteration issues one step of each. Each step emits **one digit per divmod**, and the digit becomes a
character arithmetically. The alphabet is three ASCII runs, so:

```
c = d + '0' + 7·[d > 9] + 6·[d > 35]       d ∈ [0, 62)
      '0'..'9'  →  48..57    (d + 48)
      'A'..'Z'  →  65..90    (d + 48 + 7)
      'a'..'z'  →  97..122   (d + 48 + 7 + 6)
```

Each bracket is the sign bit of an unsigned subtraction: `(9u - d) >> 31` is 1 exactly when `d > 9`.
That makes the mapping branch-free and table-free. The property suite checks all 62 digits at every
payload position.

**The reciprocals are written out by hand.** The memory core is built with `-Os`, and at `-Os` gcc 13
compiles a constant division into a real `div` (`make gates` prints the probe result). A 64-bit
`div` costs tens of cycles of latency, roughly 14 to 90 depending on the x86 generation, where a
multiply costs 3. So the core spells out the multiply-high itself, and "no `div`" then holds at
every optimisation level:

| Step | Domain | Reciprocal | Exactness bound |
|---|---|---|---|
| `v / 62^6` (the split) | `v < 2^63` | `mulhi(v, 0x4D6E196812289D0F) >> 34` | error `e = m·62^6 − 2^98` is just under 2^35, so `(2^63−1)·e < 2^98` holds with almost no slack |
| `lo / 62` (first lo step) | `lo < 62^6` | `mulhi(lo, 0x0421084210842109)` | `e = 46`, and `(62^6−1)·46 < 2^64` |
| `x / 62` (all other steps) | `x < 2^30` | `(x · 554189329) >> 35` | `e = 30`, and `(2^30−1)·30 < 2^35` |

Each bound is a `_Static_assert` in the source, so every build re-proves the constants. Mutating `RB`
by one makes the core fail to compile. `mulhi` is a single `mul` where the compiler has
`unsigned __int128`. Elsewhere, or with `-DBRANDED_NO_INT128`, it is exact schoolbook multiplication
on 32-bit limbs. The test suite builds and checks that portable path as a third core,
`memory-noint128`.

**decode** classifies each byte with three disjoint unsigned-wrap range masks:

```c
dig = (b - '0') < 10u;   up = (b - 'A') < 26u;   low = (b - 'a') < 26u;
digit = b - '0' - 7·up - 13·low;
```

A byte below a range's start wraps to a huge unsigned value, so one compare checks both ends of the
range. Validity travels inside the value: an invalid byte comes back tagged with bit 8, so its
result is at least 208, while a valid digit is below 62. One OR across the eleven results, tested
against 64, therefore detects any bad byte, and the loop has no data-dependent branch.

The tag replaces a flag passed by pointer for a reason. With a pointer, Ubuntu's default
`-fstack-protector-strong` planted a stack canary, which added a `__stack_chk_fail` reference,
whenever `-Os` kept the helper out of line.

**The range guard is arithmetic.** The core reuses the same split, with
`2^63 − 1 = QA·62^6 + RB`, `QA = 162,382,637` and `RB = 503,620,799`:

```
in range  ⇔  hi < QA  ∨  (hi = QA  ∧  lo ≤ RB)
```

It is evaluated after the charset check. That way `hi` (5 digits) always fits in a u32 and `lo`
(6 digits) in a u64.

**Why `-Os`, measured.** The memory core rebuilt at `-O2` had a `.text` of 950 B instead of 694 B
and was barely faster: decode 26.0 vs 29.0 ns, encode 17.0 vs 17.6 ns in the same session. The cost
lies in the one-digit-per-step chains and the per-byte classification, not in `-Os` call overhead.
So `-Os` is the right default for the footprint tier.

<a id="footprint"></a>

## Footprint

From `make gates` (`size -A` on the shipped objects, gcc 13.3, x86-64):

| Core | `.text` | `.rodata` | `.data` | `.bss` | `nm -u` |
|---|---:|---:|---:|---:|---|
| speed (`-O2`) | 806 | **8,063** | 0 | 0 | `memcmp` |
| memory (`-Os`) | 694 | **0** | 0 | 0 | *(none)* |

The speed core's `.rodata` holds `PAIRS` (7,689 B including the literal's NUL), `B62` (256 B), the
alphabet (63 B) and `MAX_PAYLOAD` (11 B): 8,019 B plus alignment. In the speed core these tables
are touched on every call. That costs nothing on a server and real cache lines in a hot loop
shared with other work. The memory core has none of it.

<a id="tests-gates-fuzzing-sanitizers"></a>

## Tests, gates, fuzzing, sanitizers

All commands run from `native/c/`.

| Target | What it proves | Result on this host |
|---|---|---|
| `make test` | The corpus per core and the property suite | 3 × 20,760 vector checks, plus 106,797,304 property checks (10M round trips), **0 failures**, about 3 s |
| `make conform` | Builds the parity shims | `HELLO c speed EDHU`, `HELLO c memory EDHU` |
| `python3 tools/parity.py --only c-` | Every response diffed against the oracle | c-speed and c-memory **PASS**, 28,642 requests each, 0 mismatches (at `--scale 10`: 154,642 each, 0) |
| `make gates` | Object-code properties | 0 `div`/`idiv` in any function of either core, no allocator, memory `.rodata` = 0 |
| `make fuzz FUZZ_SECONDS=30` | libFuzzer + ASan + UBSan, both targets | about 21.5M and 18.1M execs, 0 findings |
| `make fuzz-cov` | Source coverage replayed from the corpora | 100% of regions, both cores |
| `make harden` | Sanitizers, fortify, conversion warnings, clang | all clean |
| `make bench` | The bench protocol | see below |

### `make test`

- **`test_vectors-<core>`** reads [`vectors/`](../vectors/) and checks:
  - for every row of `valid.tsv`: encode, decode, `hash32` and `unix_ms`;
  - for every row of `invalid.tsv`: the class, and that the outputs stay untouched;
  - for every row of `encode_invalid.tsv`: the class, including namespaces whose length is not 3,
    which are refused at the caller level as described above.

  The `ts/node/seq` columns are not checked, because this ABI has no field reader. If `vectors/` is
  absent, the test is a **SKIP**. With `BRD14_REQUIRE_VECTORS=1` set (root Makefile, CI), an absent
  `vectors/` is a **FAIL**.
- **`test_props`** links every core into one binary, and compares each core with the others and with
  a naive reference model. That model works the way `tools/oracle.py` does: one u64 divmod per
  digit, a linear alphabet search, and an overflow-checked Horner sum as the range guard. It shares
  none of the cores' techniques. The cores are the **shipped objects with their four symbols renamed
  by objcopy**, so the suite tests the machine code that ships, not a re-compilation. Sections:

  | Section | What it checks |
  |---|---|
  | literals | V-1..V-6, E-1 and E-2 |
  | digits | all 62 digit mappings at all 11 positions |
  | bytes | all 256 bytes at all 14 positions of six seeds; byte classification exact, cores identical |
  | lengths | every length 0..64 |
  | boundaries | the 62^k edges, `(QA, RB)` from both sides, every position of the max payload bumped up and stepped down, V-7 ordering |
  | precedence | multi-fault inputs in both directions, plus 400k random multi-fault ids |
  | roundtrip | 10M splitmix64 values: identical bytes across cores, `decode∘encode = id`, byte order = numeric order, and 1 in 8 values drawn from the full u64 to cover `RANGE` |
  | noise | 1M near-valid strings |

  The default is 10,000,000 round trips. `PROP_N=...` changes it.

**Mutation check (manual, recorded here).** Eight mutants of the memory core were run against
`test_props`:

- a guard of `hi <= QA`;
- a digit-map threshold shifted by one;
- the lowercase offset 13 → 12;
- swapped encode precedence;
- a weakened validity test (`tags >= 256` instead of `>= 64`);
- an off-by-one in the uppercase payload mask;
- an off-by-one in the namespace mask;
- `RB + 1`.

The suite killed all of them. The `RB + 1` mutant never ran: the `_Static_assert`s rejected it at
compile time.

### `make gates`

```
gates: gcc -Os emits 1 div for x / 62u (why the memory core writes its reciprocals out)
gates (a): div/idiv per function
  core     function            insns  divs
  speed    branded_encode         97     0
  speed    branded_decode        101     0
  speed    branded_hash32         11     0
  speed    branded_unix_ms         5     0
  memory   b62_char               11     0
  memory   b62_digit              24     0
  memory   branded_encode         72     0
  memory   branded_decode         81     0
  memory   branded_hash32         10     0
  memory   branded_unix_ms         6     0
gates (b): undefined symbols (nm -u)
  speed    memcmp
  memory   (none)
gates (c): footprint (size -A, bytes)
  core        .text  .rodata  .data   .bss
  speed         806     8063      0      0
  memory        694        0      0      0
gates: ok (speed memory)
```

**(a)** scans every function in each object: the exported ones, and the static helpers that `-Os`
keeps out of line. The gate does not trust its own regex blindly; it first proves the detector on
a probe that must contain a `div`. It also fails when built `OPT_speed=-Os`: the speed encoder then
has 5 `div`s.

**(b)** fails on any allocator symbol, and on any undefined symbol at all in the memory core.

**(c)** writes `build/gates/size.txt`. It requires 0 bytes of `.rodata` in the memory core and no
`.data` or `.bss` in either core, because a core with no mutable state is reentrant.

### `make fuzz`

Two libFuzzer targets, built by clang with `-fsanitize=fuzzer,address,undefined
-fno-sanitize-recover=all`. Each links every core (speed, memory, memory-noint128) next to the
reference model:

- **`fuzz_decode`** accepts any bytes of any length. It checks totality, then identical status,
  namespace and value across all cores and the reference, then untouched outputs on refusal. On
  success, `encode(ns, value)` must reproduce the input exactly.
- **`fuzz_encode`** takes 3 namespace bytes and a little-endian u64, over the full u64 range. It
  checks identical status and bytes, the decode round trip, and `hash32`/`unix_ms`.

Outputs live in exact-size stack arrays, so ASan catches a core that writes a fourth namespace byte
or a fifteenth id byte. libFuzzer's input buffer is exactly `size` bytes, so any over-read aborts.

Results of one run (`make fuzz FUZZ_SECONDS=30`, fresh corpora, machine shared with concurrent
builds):

| Target | Execs | Execs/s | libFuzzer cov / ft | Corpus | Findings |
|---|---:|---:|---|---|---|
| `fuzz_decode` | 21,489,597 | ~693k | 53 / 88 | 29 units (seeded with 64 ids from `valid.tsv`) | 0 |
| `fuzz_encode` | 18,078,851 | ~583k | 50 / 51 | 9 units | 0 |

The edge counts are small because the cores are mostly branch-free. `make fuzz-cov` measures what
matters more: it replays both corpora under llvm-cov, with **one core instrumented per run**. Both
cores export the same function names, and their records would otherwise merge in a single profile.
Every region of both cores is reached: 39/39 for speed and 47/47 for memory. As a check that the
harness has teeth, a memory core mutated to accept `'['` as a digit was found in about 2,500
executions from an empty corpus.

Corpora live in `native/c/fuzz/corpus/` and crash files in `native/c/fuzz/crash-*`. Git ignores
both.

### `make harden`

1. The whole `make test` under **ASan + UBSan** (gcc, `-fno-sanitize-recover=all`), with the cores
   at their shipped `-O` levels: clean.
2. Again with **`-D_FORTIFY_SOURCE=3 -fstack-protector-strong`**: clean.
3. Every C source under **`-Wconversion -Wsign-conversion -Wpedantic -Werror`**, with both gcc 13.3
   and clang 18: clean. One flag is relaxed. `-Wpedantic` reports only `-Woverlength-strings` for
   the speed core's 7,688-character pair-table literal, which is past C's 4,095-character minimum
   translation limit. gcc, clang and MSVC all accept it, so the harden run passes
   `-Wno-overlength-strings`.
4. The test suite **built by clang**: clean.

The sanitizer, fortify and clang stages each run the full 10M-round-trip property suite. The
whole target takes about 15 s.

<a id="benchmarks"></a>

## Benchmarks

`make bench` follows [bench/README.md](../bench/README.md). It runs the first 4,096 rows of
`valid.tsv`, cycling through them in order inside each timed loop. The iteration count is calibrated
to at least 50 ms per sample, and each op takes 15 samples, reported as median ± MAD. Results reach
a volatile sink. The run is pinned with `taskset -c 2`, and the JSON goes to
`bench/results/c-<core>-gcc-13.3.json`. Every call is a real ABI call into a separate object, with
no LTO and no inlining.

**One run, labelled.** Intel Xeon @ 2.10 GHz (lscpu), 4 vCPUs, gcc 13.3, 2026-10-11. Other agents
were compiling and benchmarking on the same machine. CPU 2 was time-shared with their pinned benches
and doubled every number, so this run used `taskset -c 3`. The CVs were 10–15%, so the numbers
are **indicative only**.

| Op | speed (`-O2`) | memory (`-Os`) |
|---|---:|---:|
| `encode` | 6.6 ns | 17.1 ns |
| `decode` | 11.9 ns | 28.3 ns |
| `hash32` | 1.0 ns | 0.9 ns |

So the trade is about 2.5× on the codec in exchange for zero table bytes. Both cores are far
below the cost of anything that would call them (a NIF call, a hash-map probe, a syscall).

<a id="vendoring"></a>

## Vendoring

A core is two files and no build system:

```
native/include/branded_id.h
native/c/speed/branded_id.c      # or native/c/memory/branded_id.c
```

```bash
cc -std=c11 -O2 -I native/include -c native/c/speed/branded_id.c  -o branded_id.o   # speed
cc -std=c11 -Os -I native/include -c native/c/memory/branded_id.c -o branded_id.o   # memory
```

- **Speed** needs `memcmp` from libc. Build it with `-O2` or higher; at `-Os` gcc reintroduces `div`.
- **Memory** needs nothing: it is freestanding-friendly and fits wasm, embedded or kernel contexts.
  On compilers without `unsigned __int128`, it switches to the portable `mulhi` on its own.
  `-DBRANDED_NO_INT128` forces that path.
- Both need a C11 compiler, for `_Static_assert` and `stdint.h`.
- To switch cores, link the other object. The header and every call site stay the same. The Rust
  `brd14-ffi` crate exports the same ABI as a third drop-in.
- For the Erlang NIF over either core, see [beam.md](beam.md).

<a id="make-targets"></a>

## Make targets

| Target | |
|---|---|
| `make` / `make all` | `build/speed/branded_id.o`, `build/memory/branded_id.o` |
| `make test` | vectors per core, plus `test_props` (`PROP_N=` changes the round-trip count) |
| `make conform` | `build/conform-speed`, `build/conform-memory` (used by `tools/parity.py`) |
| `make bench` | pinned benches, JSON into `bench/results/` (`TASKSET=` overrides the pinning) |
| `make gates` | no `div`, no allocator, footprint |
| `make fuzz` | `FUZZ_SECONDS=30` per target by default; `FUZZ_CC=clang` |
| `make fuzz-cov` | per-core region coverage from the fuzz corpora |
| `make harden` | ASan+UBSan, fortify, conversion warnings, clang build |
| `make clean` | removes `build/` |

The knobs are `OPT_speed` (default `-O2`), `OPT_memory` (default `-Os`), `EXTRA_CFLAGS` (added to
every compile and link), `CC` (default `gcc`) and `VECTORS` (default `../../vectors`).

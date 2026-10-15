---
id: "KAN0R9YJSzHmui"
slug: "DOCS-GO"
type: "guide"
version: "1.3"
path: "docs/go.md"
title: "Go — the reference implementation"
summary: "The Go reference implementation: API, typed errors, zero-allocation guarantees and how they are proven."
tags: ["go", "reference", "zero-alloc"]
group: "implementations"
language: "en"
audience: ["developer", "agent"]
---

# Go — the reference implementation

[`go/`](../go/) is the module `github.com/jonny-novikov/brd14/go`, package `brd14`: standard
library only, `go 1.22.0` floor, developed and benchmarked on Go 1.26.9. It is the repository's
**zero-allocation reference baseline**. Every hot-path call is held to an exact allocation count by
a test, and the parity run holds every answer to the oracle.

```go
import brd14 "github.com/jonny-novikov/brd14/go"

g := brd14.NewGenerator(brd14.DefaultNode())
id, err := g.NextBranded("USR")                // e.g. "USR0KHTOWnGLuC": one allocation, the string

buf := make([]byte, 0, 64)
buf, err = g.AppendNextBranded(buf[:0], "USR") // the same mint into buf: zero allocations
ns, snow, err := brd14.ParseBytes(buf)         // [3]byte{'U','S','R'} and the snowflake: zero

_, _, err = brd14.Parse("USRzzzzzzzzzzz")
errors.Is(err, brd14.ErrInvalid)               // true, as in v0.1.0
errors.Is(err, brd14.ErrRange)                 // true: which rule refused
```

- [API](#api)
- [Errors: typed causes and precedence](#errors-typed-causes-and-precedence)
- [Zero allocation, and how it is proven](#zero-allocation-and-how-it-is-proven)
- [Two range guards, chosen by measurement](#two-range-guards-chosen-by-measurement)
- [Tests, parity, hardening](#tests-parity-hardening)
- [Benchmarks](#benchmarks)
- [Toolchains: the 1.22 floor and the 1.26 dev toolchain](#toolchains-the-122-floor-and-the-126-dev-toolchain)
- [Runtime notes](#runtime-notes)
- [Migrating from v0.1.0](#migrating-from-v010)
- [Layout](#layout)

[Index](index.md#toc) · [Contract](contract.md#toc) · [Structures](structures/README.md#toc) · [Parity](parity.md#toc) · [KAN story](kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [API](#api)
- [Errors: typed causes and precedence](#errors-typed-causes-precedence)
- [Zero allocation, and how it is proven](#zero-allocation-proven)
- [Two range guards, chosen by measurement](#two-range-guards-chosen)
- [Tests, parity, hardening](#tests-parity-hardening)
- [Benchmarks](#benchmarks)
- [Toolchains: the 1.22 floor and the 1.26 dev toolchain](#toolchains-1-22-floor)
- [Runtime notes](#runtime-notes)
- [Migrating from v0.1.0](#migrating-v0-1-0)
- [Layout](#layout)

<a id="api"></a>

## API

"Allocs" is the exact count `alloc_test.go` asserts. It holds on success **and** on every refusal.
A "—" marks a call that is off the hot path and whose count is not asserted.

| Call | Does | Allocs | Refuses with |
|---|---|---:|---|
| `Encode(ns string, snow uint64) (string, error)` | brands a snowflake | 1 (the string) | `ErrNamespace`, `ErrRange` |
| `AppendEncode(dst []byte, ns string, snow uint64) ([]byte, error)` | `Encode` into a caller buffer; `dst` comes back unchanged on refusal | 0 with `Len` bytes spare in `dst` | `ErrNamespace`, `ErrRange` |
| `MustEncode(ns, snow) string` | `Encode`, panicking with the cause | — | (panics) |
| `Parse(id string) (ns string, snow uint64, err error)` | splits an id; `ns` is a substring of `id` | 0 | `ErrLength`, `ErrNamespace`, `ErrCharset`, `ErrRange` |
| `ParseBytes(b []byte) (ns [3]byte, snow uint64, err error)` | `Parse` over bytes; nothing returned aliases `b` | 0 | as `Parse` |
| `Decode(id string) (uint64, error)` / `DecodeBytes(b []byte)` | the snowflake alone | 0 | as `Parse` |
| `Valid(id string) bool` / `ValidBytes(b []byte) bool` | shape and range, total | 0 | — |
| `Hash32(snow uint64) uint32` | the trie-placement hash (first half of `fmix64`) | 0 | — |
| `UnixMs(snow) int64`, `Time(snow) time.Time` | the mint instant | 0 | — |
| `MinFor(t time.Time) uint64` | the half-open lower bound for a time-range scan | 0 | — |
| `NodeOf(snow)`, `SeqOf(snow) uint64` | the node and sequence fields | 0 | — |
| `NodeFrom(host string, pid int) uint64` | the contract's `node_from`: FNV-32a over host ++ decimal pid, `& 1023` | 0 | — |
| `DefaultNode() uint64` | `NodeFrom(os.Hostname(), os.Getpid())` | — | — |
| `NewGenerator(node uint64) *Generator` | a lock-free minter on `node & 1023`, allocated once | — | — |
| `NewGeneratorWithClock(node uint64, clock func() int64) *Generator` | the same minter, reading the given clock (Unix ms); `nil` reads the wall clock. The [virtual clock](contract.md#virtual-clock-experimental) | — | — |
| `(*Generator).Observe(snow uint64, maxAheadMs int64) (bool, error)` | the receive rule: every later `Next` sorts after `snow`. `false` (the clock unchanged) when `snow` is more than `maxAheadMs` ahead | 0 | `ErrRange` (`snow ≥ 2^63`) |
| `(*Generator).VirtualUnixMs() int64` | the generator's virtual time, `(cell >> 12) + EpochMs` | 0 | — |
| `(*Generator).Next() uint64` | the next snowflake: strictly increasing, never blocking | 0 | — |
| `(*Generator).NextBranded(ns) (string, error)` | `Encode(ns, Next())` | 1 | `ErrNamespace` |
| `(*Generator).AppendNextBranded(dst, ns) ([]byte, error)` | `AppendEncode(dst, ns, Next())` | 0 with `Len` bytes spare | `ErrNamespace` |
| `NewMinter(g, gate) *Minter`, `Mint`, `MintSnowflake`, `MustMint` | a generator plus a namespace policy; the gate runs first and its error is returned unchanged | `Mint`: 1 | the gate's error, else `ErrNamespace` |
| `AllowAll`, `DenyAll`, `ErrRefused` | the explicit open and closed gates | — | `ErrRefused` is **not** an `ErrInvalid` |

Constants: `Len = 14`, `EpochMs = 1704067200000`.

<a id="errors-typed-causes-precedence"></a>

## Errors: typed causes and precedence

Every refusal satisfies `errors.Is(err, brd14.ErrInvalid)`, as it did in v0.1.0. The value
actually returned is one of four preallocated causes, the contract's error classes:

| Cause | Contract class (C ABI code) | Meaning |
|---|---|---|
| `ErrLength` | `LENGTH` (1) | decode input is not exactly 14 bytes |
| `ErrNamespace` | `NAMESPACE` (2) | the namespace is not exactly 3 bytes of `A-Z`, whatever its length |
| `ErrCharset` | `CHARSET` (3) | a payload byte is outside `0-9A-Za-z` |
| `ErrRange` | `RANGE` (4) | the value is outside `[0, 2^63)` |

```go
_, _, err := brd14.Parse("USR{0000000000")
errors.Is(err, brd14.ErrInvalid) // true — every refusal
errors.Is(err, brd14.ErrCharset) // true — the cause
errors.Is(err, brd14.ErrRange)   // false — the causes are distinct
err == brd14.ErrInvalid          // false — compare with errors.Is, never ==
```

**Mechanism.** Each cause is a distinct `*invalidError` whose `Is(target)` method reports
`target == ErrInvalid`. The causes are siblings under one sentinel, not an `Unwrap` chain. Because
they are package-level values, returning one allocates nothing, and `errors.Is` answers both
questions without allocating.

**Precedence is namespace-first** ([contract](contract.md#errors-and-precedence)): when an
input breaks several rules, the most specific, most actionable diagnostic wins.

| Direction | Order | Example |
|---|---|---|
| encode | `NAMESPACE` → `RANGE` | `Encode("usr", 1<<63)` → `ErrNamespace` |
| decode | `LENGTH` → `NAMESPACE` → `CHARSET` → `RANGE` | `Parse("usr0KHTOWnGLu")` → `ErrLength`; `Parse("usrzzzzzzzzzz!")` → `ErrNamespace`; `Parse("USRzzzzzzzzzz!")` → `ErrCharset` |

The decode order is why `Parse` runs its range guard **after** the charset loop. v0.1.0 compared the
payload with `"AzL8n0Y58m7"` before the loop. That was harmless with a single sentinel, but it
mis-classifies an off-alphabet payload that sorts above the maximum, such as `"USR{0000000000"` (`'{'`
sorts above `'z'`), as `RANGE`. `TestDecodePrecedence` pins the order with multi-fault rows. The
range-before-charset mutant fails five of them.

`ErrRefused`, the `DenyAll` gate's error, is deliberately **not** an `ErrInvalid`. A policy refusal
and a malformed id are different facts. `TestCausesAreDistinctAndInvalid` keeps the two apart.

<a id="zero-allocation-proven"></a>

## Zero allocation, and how it is proven

**The guarantee.** These calls allocate nothing, on success and on every refusal class:
`AppendEncode` (given `Len` bytes of spare capacity in `dst`), `Parse`, `ParseBytes`, `Decode`,
`DecodeBytes`, `Valid`, `ValidBytes`, `Hash32`, `UnixMs`, `Time`, `MinFor`, `NodeOf`, `SeqOf`,
`NodeFrom`, `(*Generator).Next` and `(*Generator).AppendNextBranded`. `Encode`, `NextBranded` and
`Minter.Mint` allocate exactly one object, the 14-byte string they return (16 B, the
allocator's size class). `AppendEncode` with a too-small `dst` allocates exactly what `append`'s
growth allocates (one allocation for a nil `dst`).

**Proof 1: the test.** `alloc_test.go` `TestAllocs` measures 50 cases with
`testing.AllocsPerRun(1000, …)` and requires the count to be **exactly** the stated number. The cases
are every call above on its success path, every decode refusal class (`LENGTH`, `NAMESPACE`,
`CHARSET`, `RANGE`) through `Parse`, `ParseBytes`, `Decode`, `DecodeBytes`, `Valid` and `ValidBytes`,
both encode refusals through `Encode` and `AppendEncode`, the namespace refusal through
`NextBranded` and `AppendNextBranded` (a minted snowflake is never out of range), and the
one-allocation calls. Before measuring, each case checks that the call took the path being measured,
so a zero count can never come from a call that refused when it should have succeeded. The test
skips under `-race`, whose instrumentation allocates on its own account. A `raceEnabled` constant
set by `race_on_test.go` / `race_off_test.go` build tags handles the skip.

```
$ go test -run '^TestAllocs$' -v .
=== RUN   TestAllocs
--- PASS: TestAllocs (0.00s)
```

Mutation check: wrapping one refusal in `fmt.Errorf("%w …")` turns the test red
(`ValidBytes/LENGTH: 2 allocs/op, want 0`).

**Proof 2: the benches.** Every benchmark reports allocations (`-benchmem`). From the run in
[Benchmarks](#benchmarks):

```
BenchmarkEncode       	35964026	        34.96 ns/op	      16 B/op	       1 allocs/op
BenchmarkEncodeAppend 	80043051	        16.25 ns/op	       0 B/op	       0 allocs/op
BenchmarkDecode       	89256884	        13.90 ns/op	       0 B/op	       0 allocs/op
BenchmarkDecodeBytes  	100000000	        11.65 ns/op	       0 B/op	       0 allocs/op
BenchmarkValid        	86868488	        14.73 ns/op	       0 B/op	       0 allocs/op
BenchmarkHash32       	1000000000	         1.003 ns/op	       0 B/op	       0 allocs/op
BenchmarkMint         	 5685338	       221.8 ns/op	      16 B/op	       1 allocs/op
BenchmarkMintAppend   	11547854	        89.01 ns/op	       0 B/op	       0 allocs/op
BenchmarkNext         	18268138	        67.07 ns/op	       0 B/op	       0 allocs/op
```

These lines are the first of the ten samples of each benchmark, from the run below. The allocation
columns are identical in all ten samples of every benchmark. The 221.8 ns is `mint`'s first sample,
an outlier. The [table](#benchmarks) reports the median.

**Proof 3: escape analysis.** `go build -gcflags=-m .` (Go 1.26.9) reports, for the zero-allocation
entry points:

```
brd14.go:120:19: leaking param: dst to result ~r0 level=0     # AppendEncode: dst flows only to its result
brd14.go:120:31: ns does not escape
brd14.go:125:24: make([]byte, 14) does not escape             # the extension is never a heap object
brd14.go:125:14: append escapes to heap                       # …only append's growth, when dst is too small
brd14.go:229:17: b does not escape                            # ParseBytes
brd14.go:263:18: b does not escape                            # DecodeBytes
brd14.go:269:17: b does not escape                            # ValidBytes
brd14.go:208:12: id does not escape                           # Valid
brd14.go:177:12: leaking param: id to result ns level=0       # Parse: ns is a substring of id, not a copy
snowflake.go:50:15: host does not escape                      # NodeFrom (strconv.AppendInt inlined into a stack buffer)
snowflake.go:98:39: leaking param: dst to result ~r0 level=0  # AppendNextBranded
snowflake.go:98:51: ns does not escape
snowflake.go:78:7: g does not escape                          # Next
brd14.go:109:19: string(buf[:]) escapes to heap               # Encode: the one allocation, by design
```

"Leaking param … to result" means the parameter flows into what the function returns, not onto the
heap. Line numbers refer to the commit that adds this page. Rerun the command to refresh them.

**Why `NodeFrom` writes FNV-32a out by hand.** `hash/fnv.New32a()` returns its state behind a
`hash.Hash32` interface, which allocates, and `Write([]byte(host))` copies the host. The inline form
is the contract's definition verbatim and allocates nothing. `TestNodeFromMatchesHashFNV` holds it to
`hash/fnv` over random host bytes and the full `int` range of pids, negative ones included.

<a id="two-range-guards-chosen"></a>

## Two range guards, chosen by measurement

The contract defines two exact forms of "value < 2^63" ([contract](contract.md#the-range-guard-two-equivalent-forms)).
This package carries both:

- **`Parse` uses the lexicographic guard.** It compares `id[3:]` with `"AzL8n0Y58m7"`, the form the
  contract names for Go `Parse`. It runs after the charset loop, where it must for precedence. The
  loop's accumulator may wrap for an out-of-range payload. The wrapped value is never returned.
- **`ParseBytes` uses the arithmetic guard.** The payload is split at 62⁶ into `hi` (5 digits) and
  `lo` (6 digits). Neither can wrap. The value is in range iff `hi < qa || hi == qa && lo <= rb`,
  with `qa = 162382637`, `rb = 503620799`. `TestArithmeticGuardConstants` derives both with
  `math/big`.

The choice for `ParseBytes` was measured: the same decode loop with each guard, in one test binary,
pinned with `taskset -c 2`, 15 samples × 300 ms, on the bench corpus.

| Variant (same loop, same binary) | median ns/op |
|---|---:|
| bytes, arithmetic guard | **11.08** |
| bytes, lexicographic guard (`string(b[3:]) > maxPayload`) | 12.60 |
| string, arithmetic guard | 9.87 |
| string, lexicographic guard (today's `Parse`) | 12.92 |

The arithmetic guard needs no out-of-line `runtime.cmpstring` call. It also turns one 11-step
multiply-add chain into a 5-step and a 6-step chain, which are independent. Two consequences:

1. Having both forms in one package is a test asset. `TestParseBytesAgreesWithParse`,
   `TestArithmeticGuardBoundary` (a `math/big` walk of ±300 around 2^63−1 and the `(hi, lo)` grid
   around `(qa, rb)`), the shared vectors and `FuzzParse` hold the two forms to identical answers.
   If either guard drifts, the other catches it.
2. The arithmetic guard is also faster for strings, by about 24% on this machine. `Parse` keeps the
   lexicographic form because the contract names it, and because the cross-check above needs two
   forms. This is reported to the contract owner rather than changed here.

**A finding on the way: a store-forwarding stall.** The first `ParseBytes` built its result
as `[3]byte{b[0], b[1], b[2]}`. Under Go's register ABI, an array longer than one element is not
register-assigned, so the namespace travels through memory. The callee wrote it as three 1-byte
stores. Callers read it back with a 2-byte and a 1-byte load (`MOVWLZX (SP)`). A load that spans two
separate stores cannot be forwarded from the store buffer, and it stalls. Returning `[3]byte(b[:3])`
makes the callee store 2+1 bytes too. Pinned, the function went from 15.7 to 10.2 ns/op.
The comment at the return statement records why the conversion must stay.

<a id="tests-parity-hardening"></a>

## Tests, parity, hardening

`make test` (`go vet` plus `go test -count=1 ./...`) runs 56 top-level tests in three packages:
54 test functions, plus the seed corpora of the 2 fuzz targets. All are green on Go 1.26.9 and on
the 1.22.12 floor.

| File | Holds |
|---|---|
| `contract_test.go`, `epoch_test.go`, `vectors_test.go` | the frozen literals V-1…V-7, E-1/E-2 and the totality, round-trip and ordering properties T-1…T-4b (unchanged from v0.1.0) |
| `errors_test.go` | per-class rows through every entry point; multi-fault precedence rows in both directions; the causes are distinct, every one an `ErrInvalid`, none an `ErrRefused` |
| `api_test.go` | `AppendEncode` append and refusal semantics; `Parse` ≡ `ParseBytes` over random bytes at every length 0…20 and every byte at every position of four seeds; the arithmetic-guard boundary under `math/big`; `AppendNextBranded`; `NodeFrom` ≡ `hash/fnv` |
| `alloc_test.go` | the allocation contract (above) |
| `shared_vectors_test.go` | `../vectors/*.tsv`: every valid row through both encoders, both decoders, `Hash32`, `UnixMs`, the fields and `MinFor`; every refusal with its exact class via `errors.Is`; `NodeFrom` over `node.tsv` |
| `corpus_test.go` | the bench corpus, and the proof that its in-test regeneration equals `valid.tsv` rows 1…4096 |
| `fuzz_test.go` | `FuzzParse`, `FuzzAppendEncode`; plain `go test` runs their seed corpora |
| `minter_test.go`, `snowflake_node_test.go` | the gate seam; the generator layout and monotonicity; `NodeFrom` golden vectors and the three-process `DefaultNode` wiring check |
| `internal/conform/main_test.go` | the shim answers known requests and rejects every malformed one |
| `internal/benchjson/main_test.go` | the reducer's parsing, statistics and op naming |

**The shared corpus.** `shared_vectors_test.go` and `corpus_test.go` read `../vectors/`, outside
the module. When the directory is absent, as in a module cache, they **skip**. When it is absent and
`BRD14_REQUIRE_VECTORS=1` is set (the root Makefile, CI), they **fail**. Both behaviours were checked
by running a copy of the module with no `../vectors`.

**Parity.** `make conform` builds `go/internal/conform` to `build/shims/go-conform`, which is the path
`tools/parity.py` runs. The shim answers `E` with `AppendEncode`, passing the hex-decoded namespace
bytes through raw, answers `D` with `ParseBytes`, and names every refusal by `errors.Is`. It never
answers a malformed request. It reports the request on stderr and exits 2.

```
$ python3 tools/parity.py --only go
go               go/reference         DEFHNU      30651         0    5108500  PASS
$ python3 tools/parity.py --only go --scale 10 --no-build
go               go/reference         DEFHNU     174651         0    7938682  PASS
```

**Hardening.** `make harden` runs, in order: `go vet`; `go test -race` (the generator's CAS cell is
the shared state); the whole suite under `GOTOOLCHAIN=go1.22.12`; then each native fuzz target for
`FUZZTIME` (10 s). The fuzz targets judge every input against `refDecode` / `refEncode`, a
restatement of the contract with per-rule byte checks and `math/big` values, the way
`tools/oracle.py` works. They do not just check that two halves of the codec agree. Latest run:
`FuzzParse` 823,505 execs, `FuzzAppendEncode` 674,321 execs, no failures.

<a id="benchmarks"></a>

## Benchmarks

`make bench` follows [bench/README.md](../bench/README.md):

```
taskset -c 2 go test -run '^$' -bench . -benchmem -count 10 .   # raw samples → go/bench.out
go run ./internal/benchjson …                                    # → bench/results/go-reference-go1.26.9.json
```

The corpus is `vectors/valid.tsv` rows 1…4096, cycled in order. When `vectors/` is absent the
benches regenerate the same rows in-test (same splitmix64 stream and seed), so the numbers stay
comparable. Each operation's result reaches a package-level sink through an accumulator. The decode
benches slice each id out of one contiguous buffer, so the string and byte forms walk identical
memory. `internal/benchjson` reduces the ten samples to the median, the MAD and the CV, and reports
the **maximum** allocs/op and B/op over the samples, because an allocation claim should hold for
every sample.

**One run, indicative only.** `make bench` on 2026-10-11 with Go 1.26.9 linux/amd64, on
`Intel(R) Xeon(R) Processor @ 2.10GHz` (4 vCPU VM, clocksource `tsc`), pinned to CPU 2, while other
agents compiled and fuzzed on the remaining cores. Ten samples of 1 s each per op. A CV above 5% is
flagged as noisy, per the protocol.

| op | what | ns/op (median) | MAD | CV | allocs/op | B/op |
|---|---|---:|---:|---:|---:|---:|
| `encode` | `Encode` | 35.12 | 1.48 | 5.6% (noisy) | 1 | 16 |
| `encode_append` | `AppendEncode` | **16.09** | 0.37 | 3.8% | **0** | 0 |
| `decode` | `Parse` (lexicographic guard) | 14.52 | 0.36 | 4.0% | 0 | 0 |
| `decode_bytes` | `ParseBytes` (arithmetic guard) | **11.00** | 0.29 | 8.1% (noisy) | **0** | 0 |
| `valid` | `Valid` | 14.91 | 0.29 | 3.7% | 0 | 0 |
| `hash32` | `Hash32` | 1.07 | 0.05 | 21.6% (noisy) | 0 | 0 |
| `mint` | `NextBranded` | 105.95 | 3.75 | 38.3% (noisy) | 1 | 16 |
| `mint_append` | `AppendNextBranded` | **88.93** | 1.44 | 2.8% | **0** | 0 |
| `next` | `Next` | 65.63 | 1.66 | 4.7% | 0 | 0 |

How to read it:

- **The string is the cost of `Encode`.** `encode_append` does the same work into a reused buffer
  in under half the time. The difference is the 16-byte allocation and its share of GC.
- **`decode_bytes` beats `decode`** by the margin the guard measurement predicts: the arithmetic
  guard against `runtime.cmpstring`. `valid` is `Parse`, so it costs the same.
- **`mint` ≈ `next` + `encode`, and `mint_append` ≈ `next` + `encode_append`.** The generator's cost
  is almost all the clock read (see [Runtime notes](#runtime-notes)).
- **The noisy rows are noisy in their tails.** `mint`'s CV comes from one 221.8 ns first sample, and
  its MAD is 3.75 ns. `hash32` runs at about two cycles per iteration at this clock, so scheduler jitter
  dominates its CV. Use the median and the MAD; treat the CV as a warning.
- **A previous run** under heavier neighbour load (Miri and a fuzzer on other cores) put
  `encode_append` at 25.8 ns with a 32% CV, bimodal between 15–18 ns and 24–34 ns. The protocol's
  CV flag exists for exactly that. The table above is the quieter rerun.

The JSON is `bench/results/go-reference-go1.26.9.json`. It is generated, not committed.

<a id="toolchains-1-22-floor"></a>

## Toolchains: the 1.22 floor and the 1.26 dev toolchain

The module's `go` line stays at **1.22.0**. A dependency's `go` line is a promise to its consumers,
so it states the honest minimum. The production files need Go 1.20: `sync/atomic.Int64` is 1.19,
and the slice-to-array conversion in `ParseBytes` is 1.20. The tests use `math/rand/v2`, which is
1.22. Raising the line would force every consumer's toolchain up for no feature this package uses.

Development, CI and benchmarks use **Go 1.26.9** through `GOTOOLCHAIN` (set by `scripts/env.sh`).
`make harden` proves the floor by running the whole suite under `GOTOOLCHAIN=go1.22.12`. Code here
therefore avoids every 1.23+ API, even in tests:

| Not used | Since | Used instead |
|---|---|---|
| `testing.B.Loop` | 1.24 | `for i := 0; i < b.N; i++` with `b.ResetTimer()` |
| range-over-func iterators, `maps.Keys`, `slices.Collect` | 1.23 | plain loops |
| `strings.SplitSeq`, `strings.Lines`, `bytes.Lines` | 1.24 | `strings.Split` |
| `T.Context`, `T.Chdir` | 1.24 | not needed |

<a id="runtime-notes"></a>

## Runtime notes

- **Clock reads dominate minting.** `Next` is a `time.Now()` plus a CAS on one cell. `time.Now`
  reads both the wall clock and the monotonic clock through the vDSO. Pinned on this VM (clocksource
  `tsc`), `time.Now().UnixMilli()` alone measured 61.3 ns (median of 10), against 65.6 ns for
  `next`. The clock is about 93% of a mint's generator cost. The encode on top is 16 ns, or 35 ns
  when it must allocate the string.
- **One cell, one cache line.** A `Generator` is a single `atomic.Int64`. Goroutines minting from
  one generator in parallel contend on that line, and the CAS retries. For heavy parallel minting,
  give each shard its own generator on its own node id.
- **`GOMAXPROCS` under `taskset`.** Pinned to one CPU, `runtime.NumCPU()` reports 1, so
  `GOMAXPROCS` is 1, benchmark names lose their `-N` suffix, and the generator sees no contention.
  The pinned numbers are single-thread costs by construction.
- **Constant division.** `snow % 62` and `snow / 62` compile to a multiply-high and shifts, never a
  `DIV`. `Hash32`, `UnixMs`, `NodeOf` and `SeqOf` inline into callers. At sub-nanosecond cost,
  `hash32` measures loop overhead as much as the hash.
- **Bounds checks, counted.** `go build -gcflags='-d=ssa/check_bce/debug=1'` reports none in
  `Parse` or `ParseBytes`: after the length test, the prover drops every index. Each inlined `put`
  pays one check, its `_ = b[Len-1]` hint, in place of fourteen. `AppendEncode` pays one more for the
  `dst[n:]` slice.
- **Race builds.** `-race` instruments memory accesses and can allocate. The allocation assertions
  skip there, and every other test runs.
- **`Time` returns local time.** `time.UnixMilli` attaches `time.Local`. Call `.UTC()` before
  formatting when the zone matters, as `epoch_test.go` does.

<a id="migrating-v0-1-0"></a>

## Migrating from v0.1.0

1. **Import path.** v0.1.0 was published at the repository root as
   `github.com/jonny-novikov/brd14`, and it stays resolvable there. The module now lives in the
   `go/` folder:

   ```go
   import brd14 "github.com/jonny-novikov/brd14/go"
   ```

   The alias is optional, since the package name is `brd14`. It keeps call sites reading `brd14.Parse`
   rather than suggesting a package called `go`.
2. **Tags.** A module in a subdirectory is tagged with its folder as prefix: releases are
   `go/vX.Y.Z` tags. `go get github.com/jonny-novikov/brd14/go@vX.Y.Z` resolves the `go/vX.Y.Z` tag.
3. **Compare errors with `errors.Is`.** v0.1.0 returned the bare `ErrInvalid`, so `err == ErrInvalid`
   happened to work. It no longer does: the returned value is a typed cause. `errors.Is(err,
   brd14.ErrInvalid)` holds for every refusal, exactly as before. `errors.Is(err, brd14.ErrRange)`
   (and the others) is new. Error *strings* now name the cause (`"brd14: invalid branded id: snowflake
   outside [0, 2^63)"`). Code that matched the old string exactly should switch to `errors.Is`.
4. **Nothing else observable changed.** The accepted set, every encoded byte and every decoded
   value are identical. The frozen vectors in `contract_test.go` and `epoch_test.go` are untouched
   and green. The decode check order changed only which cause an input reports, never whether it is
   refused. `nodeFrom` is now the exported `NodeFrom`, with the same values (the golden vectors are
   unchanged), and `DefaultNode` derives the same node ids. `MustEncode` and `Minter` refusals carry
   the typed cause, which is still an `ErrInvalid`.
5. **New, opt-in.** `AppendEncode`, `ParseBytes`, `DecodeBytes`, `ValidBytes`, `AppendNextBranded`,
   `NodeFrom`, and the four causes.

<a id="layout"></a>

## Layout

```
go/
├── brd14.go             codec: errors, Encode/AppendEncode, Parse/ParseBytes, readers
├── snowflake.go         Generator, NodeFrom, DefaultNode, field readers
├── minter.go            Gate, Minter — the namespace policy seam
├── doc.go               package documentation
├── *_test.go            the suites above; bench_test.go, fuzz_test.go
├── internal/conform/    the parity shim (make conform → build/shims/go-conform)
├── internal/benchjson/  bench output → bench/results/*.json
└── Makefile             test · conform · bench · harden · clean
```

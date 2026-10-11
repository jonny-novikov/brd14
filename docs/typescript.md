---
id: "KAN0R9YJSzqzAn"
slug: "DOCS-TYPESCRIPT"
type: "guide"
version: "1.3"
path: "docs/typescript.md"
title: "TypeScript — the pure package"
summary: "The pure TypeScript package: exact 64-bit arithmetic without BigInt in the hot path, on Node and Bun."
tags: ["typescript", "node", "bun"]
group: "implementations"
language: "en"
audience: ["developer", "agent"]
---

# TypeScript — the pure package

`ts/packages/brd14` (npm name `brd14`) implements [the contract](contract.md) in erasable-only
TypeScript that runs **unbuilt** on Node 24 and Bun 1.4, and compiles to `dist/` for publishing.
Its distinguishing design: the 63-bit snowflake is handled with **exact 64-bit arithmetic and no
BigInt on the hot path** — the value lives in two u32 halves and every intermediate stays below
2^53, where a JavaScript Number is an exact integer. The companion
[wasm package](wasm.md) shares this workspace, the error classes, the Generator/Minter, the shim
protocol helper and the bench harness.

```
ts/
├── package.json            npm workspaces ["packages/*"]; the dev dependencies live here only
├── package-lock.json
├── tsconfig.base.json      strict · erasableSyntaxOnly · verbatimModuleSyntax · rewriteRelativeImportExtensions
├── tsconfig.json           typecheck of every source, test, shim, bench and script (noEmit)
├── vitest.config.ts
├── Makefile                test · bench · harden · build · conform · clean
├── packages/brd14/         the package: src/, test/, tsconfig.json (emit → dist/), README
├── conform/                protocol.ts (the shim protocol helper) · pure.ts (the shim) · smoke.{req,resp}
├── bench/                  report.ts (protocol-shaped sampling on mitata) · pure.ts
└── scripts/                publish-manifest.ts (the dist/package.json the published package ships)
```

[Index](index.md#toc) · [Contract](contract.md#toc) · [Structures](structures/README.md#toc) · [Parity](parity.md#toc) · [KAN story](kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [API](#api)
- [Exact arithmetic without BigInt](#exact-arithmetic-without-bigint)
- [Allocation profile](#allocation-profile)
- [The generator and the minter](#generator-minter)
- [Node 24 vs Bun 1.4](#node-24-vs-bun)
- [How to](#how-to)
- [For the wasm package](#wasm-package)

<a id="api"></a>

## API

Everything below is exported from `brd14`; `defaultNode` from `brd14/node`.

| Export | Signature | Notes |
|---|---|---|
| `encode` | `(ns: string, snow: bigint) → string` | NAMESPACE then RANGE. The input bigint is split by one `DataView.setBigUint64`; no BigInt is allocated. |
| `encodeParts` | `(ns, ts: number, node: number, seq: number) → string` | Zero BigInt. Each field must be an integer within its width (41/10/12 bits), else RANGE. |
| `encodeInto` | `(buf: Uint8Array, offset, ns, snow: bigint) → void` | Writes 14 ASCII bytes; no string. `RangeError` when fewer than 14 bytes are available. |
| `encodePartsInto` | `(buf, offset, ns, ts, node, seq) → void` | No BigInt, no string. |
| `decode` | `(id: string \| Uint8Array) → { ns, snow: bigint }` | Total: throws `InvalidIdError` and nothing else. Strings are classified on their UTF-8 bytes. |
| `decodePartsInto` | `(id, out) → out` | Fills `out.ns/ts/node/seq`; zero BigInt. |
| `check` | `(id) → 0 \| 1 \| 2 \| 3 \| 4` | The class without throwing. |
| `isValid` | `(id) → boolean` | `check(id) === 0`. |
| `hash32` | `(k: bigint) → number` | fmix64 first half on `k mod 2^64` (negative and ≥ 2^64 inputs wrap, as the contract's "full u64"). |
| `hash32Parts` | `(hi: number, lo: number) → number` | The same on the two u32 halves; zero BigInt. |
| `unixMs` | `(snow: bigint) → number` | `(snow >> 22) + EPOCH_MS`; RANGE outside the domain. |
| `fields` | `(snow: bigint) → { ts, node, seq }` | |
| `snowFromParts` | `(ts, node, seq) → bigint` | The inverse of `fields`. |
| `minFor` | `(ms: number) → bigint` | The half-open lower bound for time-range scans; RANGE outside the epoch window. |
| `nodeFrom` | `(host: string \| Uint8Array, pid: number) → number` | FNV-32a over `host ++ decimal(pid)`, masked to 10 bits. A string host hashes its UTF-8 bytes. |
| `isNamespace` | `(ns: string) → boolean` | Three characters of `A-Z`. |
| `Generator` | `new Generator(node, clock = Date.now)` · `next(): bigint` · `nextParts(out?)` · `nextBranded(ns): string` | See [The generator](#the-generator-and-the-minter). |
| `Minter` | `new Minter(generator, gate?)` · `mint(ns)` · `mintSnowflake(ns)` · `generator` | Gate-first; the gate's throw is passed through unchanged. |
| `allowAll`, `denyAll` | `Gate` | `denyAll` throws `NamespaceRefusedError`, which is **not** an `InvalidIdError`. |
| `InvalidIdError` | `extends Error` with `.code: 1..4`, `.className`, `name === "InvalidIdError"` | |
| `NamespaceRefusedError` | `extends Error` with `.ns` | |
| `ErrorCode` | `{ OK: 0, LENGTH: 1, NAMESPACE: 2, CHARSET: 3, RANGE: 4 }` (frozen; also a type) | No `enum`: the sources must be erasable. |
| `ErrorClass` | `["OK", "LENGTH", "NAMESPACE", "CHARSET", "RANGE"]` | The spelling of the vectors and the shim protocol. |
| constants | `ALPHABET`, `EPOCH_MS`, `ID_LENGTH`, `MAX_SNOW`, `MAX_PAYLOAD`, `MAX_TS` | |
| `defaultNode` (`brd14/node`) | `() → number` | `nodeFrom(os.hostname(), process.pid)`; works on Bun too. |

Type misuse (a Number where a bigint is typed, `undefined` for an id) is a programming fault and may
throw a `TypeError`; totality is a promise over *every string and every byte string*, which the
fuzz suite checks.

<a id="exact-arithmetic-without-bigint"></a>

## Exact arithmetic without BigInt

### Why

A BigInt is a heap object on both engines: every `*`, `/`, `%`, `<<` allocates, and a
`BigInt(…)` conversion allocates again. The naive implementation of the contract (kept in
`packages/brd14/test/naive.ts` as the in-language oracle and the bench baseline) spends 1–3 µs per
encode or decode in those allocations. The snowflake is 63 bits, a Number carries 53; so the
value is carried as two u32 halves `(hi, lo)`, `v = hi·2^32 + lo`, and each operation is arranged so
that every product, sum and quotient is an integer below 2^53.

### The two facts everything rests on

**Lemma 1 (exact floor division).** For integers `0 ≤ q < 2^53` and `1 ≤ d < 2^53`,
`Math.floor(q / d)` in IEEE-754 binary64 equals `⌊q/d⌋`.

*Proof.* `q` and `d` are exactly representable. Let `m = ⌊q/d⌋` and `x = q/d` exactly. If `d`
divides `q`, then `x = m` is an integer below 2^53, hence representable, and the correctly rounded
quotient is `m` itself. Otherwise `m < x < m + 1`, and because `q − m·d` and `(m+1)·d − q` are
positive integers, `x − m ≥ 1/d` and `(m + 1) − x ≥ 1/d`. Let `y = fl(x)` be the correctly rounded
quotient and let `2^(k−1) ≤ x < 2^k`. The spacing of doubles at `x` is at most `2^(k−53)`;
`x < 2^53/d` gives `2^k < 2^54/d`, so the spacing is below `2/d` and the rounding error
`|y − x|` is at most half of it, i.e. strictly below `1/d`. Hence `m < y < m + 1` and
`⌊y⌋ = m`. (If `y` lands on the binade boundary `2^k`, the spacing on that side is no larger than
the bound used, so the argument stands.) ∎

For `q < 2^31` the truncation `(q / d) | 0` is the same quotient, and the code uses it where the
bound is known.

**Lemma 2 (exact products and sums).** A sum or product of non-negative integers whose exact
result is below 2^53 is computed exactly: the result is a representable integer and the operation is
correctly rounded.

Everything below is a chain of operations each of which satisfies one of the two lemmas; the
bound is stated at each step.

### Encode: halves → eleven digits

Input: `(hi, lo)` with `hi < 2^31` (so `v < 2^63`). 62² = 3844.

```
qh = ⌊hi / 3844⌋                     hi < 2^31            → qh < 558,695
t  = (hi − qh·3844)·2^32 + lo        (hi mod 3844) < 3844 → t < 3844·2^32 < 2^44     (Lemma 2)
ql = ⌊t / 3844⌋                      t < 2^44             → exact (Lemma 1), ql < 2^32
p5 = t − ql·3844                     = v mod 3844: the lowest digit pair
q  = qh·2^32 + ql                    = ⌊v / 3844⌋ < 2^63/3844 < 2^52               (Lemma 2)
q1 = ⌊q / 62^4⌋                      < 62^5 < 2^30: the value of the top five digits
r1 = q − q1·62^4                     < 62^4 < 2^24: two pairs
```

`q1` and `r1` are int32, so the rest is integer work: `q1 = d0·62^4 + p1·62^2 + p2`
(`d0 < 62`), `r1 = p3·62^2 + p4`. The eleven digits are `d0, p1, p2, p3, p4, p5` with each pair
rendered through a 62×62 table of ASCII codes (7.7 KB, `PAIR_HI`/`PAIR_LO`). The output is one
`String.fromCharCode(c0, c1, c2, …11 codes)` — a flat 14-character string in one allocation.

`encodeParts(ns, ts, node, seq)` builds the halves directly, without BigInt:
`hi = ⌊ts / 2^10⌋` (since `node·2^12 + seq < 2^22`, this is `⌊v / 2^32⌋`) and
`lo = (ts mod 2^10)·2^22 + node·2^12 + seq < 2^32`. The bigint entry point `encode` gets the halves
from one `DataView.setBigUint64` followed by two `getUint32` — no BigInt allocation, two BigInt
comparisons for the range check.

### Decode: eleven digits → fields and halves

Each character is mapped by a 256-entry table (`DIGIT`, −1 outside the alphabet). The payload is
split as the contract's arithmetic range guard does, at 62^6:

```
h5 = Horner over digits 0..4         < 62^5 < 2^30 (int32)
l6 = Horner over digits 5..10        < 62^6 < 2^36 (exact double)
in range  ⟺  h5 < QA  ∨  (h5 = QA ∧ l6 ≤ RB)      with 2^63 − 1 = QA·62^6 + RB,  QA = 162382637, RB = 503620799
```

The guard is exact because `0 ≤ l6 < 62^6`: comparing `(h5, l6)` with `(QA, RB)` lexicographically
is comparing `v` with `2^63 − 1`. The fields come from `62^6 = 13542·2^22 + 970816`:

```
w     = h5·970816 + l6               h5 ≤ QA → w < 1.6·10^14 < 2^48                 (Lemma 2)
wq    = ⌊w / 2^22⌋                   exact (power of two; also Lemma 1)
low22 = w − wq·2^22                  = v mod 2^22, because h5·13542·2^22 is a multiple of 2^22
ts    = h5·13542 + wq                = ⌊v / 2^22⌋ ≤ 2^41 − 1
node  = low22 >>> 12,  seq = low22 & 4095
```

`decodePartsInto` stops here: three Numbers and the namespace string, no BigInt. `decode` goes
on to the halves — `hi = ⌊ts / 2^10⌋`, `lo = (ts mod 2^10)·2^22 + low22` — and materialises the
result with two `setUint32` and one `getBigUint64`: exactly one BigInt allocation, the result.

### hash32 without a 64-bit multiply

`fmix64`'s first half on `(hi, lo)`, `M = 0xFF51AFD7_ED558CCD = Mh·2^32 + Ml`:

- `k ^= k >> 33` only touches the low word: `lo ^= hi >>> 1`.
- `k·M mod 2^64`: the low word is `Math.imul(lo, Ml)`; the high word is
  `mulhi(lo, Ml) + Math.imul(lo, Mh) + Math.imul(hi, Ml) mod 2^32`, where `mulhi` is the exact high
  word of the 32×32→64 product. With `lo = a1·2^16 + a0`, `Ml = b1·2^16 + b0`:
  `mulhi = a1·b1 + ⌊(a1·b0 + a0·b1 + ⌊a0·b0 / 2^16⌋) / 2^16⌋`. Every partial product is below 2^32,
  the middle sum below 2^34 — exact by Lemma 2, and the nested floors are exact because
  `a0·b0 = c·2^16 + r` with `r < 2^16` cannot carry into the outer quotient.
- The final `k ^= k >> 33` again touches only the low word, which is the result.

### Strings are classified on their UTF-8 bytes

The contract says a 14-character string with a non-ASCII character is a `LENGTH` refusal, exactly
as the byte APIs see it. The fast path accepts only 14 characters that are all ASCII and all in the
grammar; the moment anything else is seen — a different length, a code above 127, a character
outside the grammar — the string is encoded with `TextEncoder` and classified as bytes. That keeps
the hot path on `charCodeAt` and puts the one allocation on the error path. Lone surrogates encode
as U+FFFD (three bytes), per the Encoding standard, so they are `LENGTH` or `CHARSET` like any
other non-ASCII character. A 13-character string containing one 2-byte character is 14 bytes and is
classified as such: `"USR0KHTOWnGLé"` is `CHARSET`, `"USé0KHTOWnGLu"` is `NAMESPACE`.

### The output path, measured

Four ways to build the 14-character result were timed over the bench corpus (pinned, both runtimes):

| builder | Node 24 (V8) | Bun 1.4 (JSC) |
|---|---:|---:|
| **`String.fromCharCode` with all 14 codes** (chosen) | **83 ns** | **143 ns** |
| `ns + String.fromCharCode(11 codes)` | 104 ns | 175 ns |
| `ns + d0 + pair + pair + pair + pair + pair` (2-char string table, rope) | 127 ns | 218 ns |
| the rope, then read one char (forces flattening) | 131 ns | 221 ns |

One call with 14 arguments produces a flat one-byte string in a single allocation; concatenation
builds a rope that is flattened later anyway, which is why the table of pair *strings* loses to
the table of pair *codes* on both engines.

<a id="allocation-profile"></a>

## Allocation profile

| API | BigInt allocated | Other allocations |
|---|---|---|
| `encode(ns, bigint)` | 0 (the input is split by `setBigUint64`) | the 14-char result string |
| `encodeParts` | 0 | the result string |
| `encodeInto`, `encodePartsInto` | 0 | **none** |
| `decode` | **1** — the result | the result object, the 3-char `ns` string |
| `decodePartsInto` | 0 | the 3-char `ns` string |
| `check`, `isValid` | 0 | none on the fast path; a `Uint8Array` when a *string* is not 14 ASCII characters (error path) |
| `hash32`, `hash32Parts` | 0 | none |
| `unixMs` | 0 | none |
| `fields` | 0 | the result object |
| `Generator.next` | 1 — the result | none |
| `Generator.nextParts(out)` | 0 | none when `out` is given |
| `Generator.nextBranded`, `Minter.mint` | 0 | the result string |
| `Minter.mintSnowflake` | 1 | the result object and string |

The package keeps about 8 KB of read-only tables (`DIGIT`, `CODE`, `PAIR_HI`, `PAIR_LO`), one
8-byte `DataView` and one 6-slot `Int32Array` as scratch. The scratch is module-level and is
always consumed before a public function returns, so it is safe in the single-threaded realm;
a Worker gets its own module instance.

<a id="generator-minter"></a>

## The generator and the minter

`Generator` owns one cell holding `ts·4096 + seq` as a Number: `ts < 2^41`, so the cell stays below
2^53 and every step is exact. Each mint sets the cell to `max(nowPart, last + 1)` where
`nowPart = (clock() − EPOCH_MS)·4096`; JavaScript is single-threaded per realm, so the
read-modify-write needs no CAS. Consequences, each proven in `generator.test.ts` with an injected
clock:

- strictly increasing under every clock regime;
- a burst past 4096 ids in one millisecond carries into `ts` (the cell simply keeps counting) —
  no sleeping, no blocking;
- a backward clock step keeps minting off the logical clock (the `last + 1` arm);
- the cell is initialised to the construction instant's `nowPart`, so, as in the Go reference,
  the first mint within that same millisecond carries `seq = 1`;
- a clock before the epoch is clamped to the epoch.

`next()` returns a bigint (one allocation); `nextParts(out)` and `nextBranded(ns)` never touch
BigInt — the latter goes through `encodeParts`. The clock is injectable: `new Generator(node, () =>
fakeNow)`.

`Minter(generator, gate)` is the policy seam. The gate runs **first**, on the raw namespace, and
whatever it throws — an Error, an object, a string — propagates to the caller unchanged (tested by
identity). Only an admitted namespace reaches the codec, whose shape check still applies: an
absent, `null` or `allowAll` gate is "no policy", never "no validation". `denyAll` throws
`NamespaceRefusedError`, deliberately not an `InvalidIdError`. `minter.generator` is the ungated
path, named so every bypass reads as one.

<a id="node-24-vs-bun"></a>

## Node 24 vs Bun 1.4

### Running the sources unbuilt

Both runtimes execute `.ts` files directly, which is why the shim is `node ts/conform/pure.ts` /
`bun ts/conform/pure.ts` and the tests import the package by name without a build step. The rules
that make this work:

- **Erasable syntax only.** Node strips types; it does not transform. No `enum`, no `namespace`, no
  parameter properties, `import type` for types. `erasableSyntaxOnly` and `verbatimModuleSyntax`
  in `tsconfig.base.json` make `tsc` refuse anything else. (`ErrorCode` is a frozen const object
  plus a type of the same name for that reason.)
- **Explicit `.ts` extensions on relative imports.** Node does not probe extensions; `rewriteRelativeImportExtensions` makes `tsc` emit `./codec.js` in `dist/`.
- **Node refuses to strip types under `node_modules`** (`ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`). The workspace install creates `ts/node_modules/brd14 → ../packages/brd14` and Node's ESM
  loader resolves symlinks to their real path by default, so a consumer's `import … from "brd14"`
  loads `ts/packages/brd14/src/index.ts`, which is *not* under `node_modules`, and is stripped.
  Verified both ways: `node ts/conform/pure.ts` from the repository root imports `brd14` and
  `brd14/node` with nothing on stderr, and a `.ts` file placed physically under `node_modules/`
  fails with `ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`. (By the same rule,
  `--preserve-symlinks` would make Node see the symlinked path and refuse; nothing in the repo
  uses it.) Bun runs TypeScript anywhere, `node_modules` included.
- **The package's `exports` point at `src/*.ts`** in the repository. That is what lets Node, Bun,
  vitest and `tsc` (`moduleResolution: nodenext` resolves an export target ending in `.ts` as
  source) all agree on one copy of the code with no build. The published package needs
  `dist/*.js`, and **npm does not apply `publishConfig.exports` when packing** (verified with npm
  11.19: the tarball's manifest kept the `src/` exports). So the publishable manifest is generated
  instead: `make build` runs `tsc -p packages/brd14` and then `scripts/publish-manifest.ts`, which
  writes `dist/package.json` with the exports rewritten to `./index.js` + `./index.d.ts`
  (and `./node.*`), copies the README and LICENSE, and the package is published **from `dist/`**:
  `npm publish ts/packages/brd14/dist`. Nothing in the tree is mutated, so a failed publish leaves
  nothing dirty.
- **TypeScript 7.0.2** (the native compiler) is used for both the typecheck and the emit. Verified
  on this package: `.js` output has `./codec.js`; `.d.ts` output keeps `./codec.ts` — identical to
  TypeScript 5.9.3's behaviour under `rewriteRelativeImportExtensions` — and a consumer compiled
  against the packed `dist/` resolves `./codec.ts` to `./codec.d.ts` with either compiler. Node
  runs the emitted `dist/` as plain ESM.
- `import.meta.url` + `fileURLToPath` locate `vectors/`; `process.versions.bun` tells the runtimes
  apart; `fs.readFileSync(0)` reads a redirected file, a pipe or an empty stdin on both (the shim
  reads stdin once and writes once; an `EAGAIN` fallback loops on `readSync`).
- Neither runtime prints anything to stderr when running these sources; Node's one notice,
  "Frozen intristics is an experimental feature", appears only under `make harden`'s
  `--frozen-intrinsics` run of the shim.

### Test runners

The test files import only `{ describe, test, expect }` (and `test.each`) from `"vitest"`.
**`bun test` maps the `vitest` module to `bun:test`**, so the same files run unchanged under both
runners: `vitest run` on Node and `bun test ./packages` on Bun, 72 tests each. What that buys and
what it costs:

- no mocks (`vi.*`), no runner-specific imports; `make lint-tests` greps for both and fails the
  build on a hit;
- skipping is `(present ? describe : describe.skip)(…)` — supported identically by both — so the
  vectors suite skips when `vectors/` is absent and a plain `test` fails when it is absent under
  `BRD14_REQUIRE_VECTORS=1`;
- assertions are kept to the shared subset (`toBe`, `toEqual`, `toBeInstanceOf`, `toThrow(Class)`,
  `toBeGreaterThanOrEqual`); errors are captured with a tiny `caught(fn)` helper and their
  `.code` asserted, instead of matcher features that differ between the runners.

### V8 vs JSC, as the bench sees them

The numbers below are from `make bench` on the shared 4-vCPU Xeon of the build container
(`Intel(R) Xeon(R) Processor @ 2.10GHz`), pinned to core 2 while five other trees were being built
on the same machine. Treat them as *indicative*: repeated runs alternated between the profile below
and one in which every op, baselines included, was about 2× slower with CVs of 20–40% — another
pinned process sharing the core. Read the `cv` field of the JSON before trusting a difference under
20%, and rerun on an idle machine for publishable figures. The baselines are the naive BigInt
implementation of the same contract, in the same process; the speedups are run-internal ratios and
are stable across the two profiles.

| op (ns/op, median of ≥ 16 samples ≥ 50 ms) | Node 24.21.0 | Bun 1.4.3 | note |
|---|---:|---:|---|
| `encode` (bigint in) | 63 | 123 | one flat string out |
| `encode_parts` | 68 | 149 | zero BigInt |
| `encode_into` | 57 | 60 | zero allocation |
| `decode` (string in) | 83 | 112 | one BigInt out |
| `decode_parts` | 173 † | 38 | zero BigInt |
| `decode_bytes` | 125 † | 87 | |
| `valid` | 117 † | 30 | |
| `hash32` (bigint in) | 15 | 23 | |
| `hash32_parts` | 13 | 8 | |
| `mint` (`nextBranded`) | 281 | 157 | includes `Date.now()` |
| `naive_encode` (BigInt) | 1189 | 1207 | baseline |
| `naive_decode` (BigInt) | 1311 | 2500 | baseline |
| `naive_hash32` (BigInt) | 62 | 272 | baseline |
| **speedup, encode** | **18.9×** | **9.8×** | vs `naive_encode` |
| **speedup, decode** | **15.9×** | **22.3×** | vs `naive_decode` |
| **speedup, hash32** | **4.2×** | **12.0×** | vs `naive_hash32` |

† In this Node run the three ops marked † fell into a contended window (CV 17–19%); in the
uncontended, unpinned run earlier in the same session they measured `decode_parts` 94 ns,
`decode_bytes` 72 ns, `valid` 64 ns against `decode` 96 ns — i.e. on V8 the parts/bytes decoders are
at or below the bigint decoder, as the design predicts.

What the two engines do differently:

- **BigInt.** The naive encoder costs about the same on both (1.2 µs), but the naive *decoder* is
  twice as slow on JSC (2.5 µs vs 1.3 µs) and JSC's BigInt-based `hash32` four times slower than
  V8's. The cost of *materialising* a single BigInt result is visible on Bun: `decode` (112 ns,
  one `getBigUint64`) against `decode_parts` (38 ns, none), and `hash32` (23 ns, one
  `setBigUint64`) against `hash32_parts` (8 ns). On V8 the DataView BigInt round trip is cheap
  (`hash32` 15 vs `hash32_parts` 13 ns).
- **Strings.** V8 builds the 14-character result faster: `encode` vs `encode_into` prices the
  string at ~6 ns on Node and ~63 ns on Bun, and the output-path A/B above shows the same gap
  (83 vs 143 ns). The byte APIs (`encode_into`: 57 vs 60 ns) are where the two runtimes converge.
- **Reading.** JSC's `charCodeAt` loop is faster (`valid`: 30 ns; `decode_parts`: 38 ns); V8 is
  faster at allocating the small result objects (`decode`: 83 vs 112 ns) and at `Date.now()`-heavy
  minting is slower (`mint`: 281 vs 157 ns, the `encodeParts` cost being 68 vs 149 ns of that).

<a id="how-to"></a>

## How to

```bash
. scripts/env.sh                   # Node 24.21.0, Bun 1.4.3 on PATH
make -C ts test                    # tsc typecheck · grep gate · vitest run (Node) · bun test (Bun)
make -C ts bench                   # taskset -c 2 node bench/pure.ts; same on bun → bench/results/ts-pure-*.json
make -C ts harden                  # typecheck · grep gate · the shim under node --frozen-intrinsics and under bun, diffed against the oracle
make -C ts build                   # tsc -p packages/brd14 → dist/ (+ dist/package.json, README, LICENSE)
make -C ts conform                 # what tools/parity.py needs: npm ci when node_modules/ is missing
python3 tools/parity.py --only ts-pure   # ts-pure-node and ts-pure-bun vs the oracle (30,651 requests each)
BRD14_REQUIRE_VECTORS=1 make -C ts test  # fail, rather than skip, when vectors/ is missing
```

Publishing: `make -C ts build && npm publish ts/packages/brd14/dist`. The tarball carries
`index.js`/`index.d.ts`, `node.js`/`node.d.ts` and their internals with source maps (sources inlined),
and the generated manifest with `exports` for `.`, `./node` and `./package.json`; no dependencies.

Running something ad hoc: `node ts/conform/pure.ts < requests`, or from any file inside `ts/`,
`import { encode } from "brd14"` — Node or Bun, no build.

<a id="wasm-package"></a>

## For the wasm package

`ts/packages/brd14-wasm` is designed to sit next to this package and reuse:

- `InvalidIdError`, `ErrorCode`, `ErrorClass`, `NamespaceRefusedError` from `brd14`, so both
  packages throw the same classes;
- `Generator` and `Minter` — a wasm `encode(ns, snow: i64)` can be fed by `Generator.next()`, and a
  `Minter` over it needs no change;
- `ts/conform/protocol.ts`: `serve("ts", "wasm", handlers)` writes the HELLO line, parses the
  requests, maps `InvalidIdError` to `ERR <CLASS>`; `unhex`, `hexs`, `latin1`, `readStdin` are exported;
- `ts/bench/report.ts`: `loadCorpus`, `measure(ops)`, `writeReport("ts-wasm", "wasm", …)`,
  `printTable`, so `bench/results/ts-wasm-*.json` comes out of the same sampler.

The root `.gitignore` already ignores `ts/packages/brd14-wasm/src/wasm-bytes.ts` and `ts/**/dist/`.

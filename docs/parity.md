---
id: "KAN0R9YJSzZO2j"
slug: "DOCS-PARITY"
type: "guide"
version: "1.3"
path: "docs/parity.md"
title: "Parity"
summary: "How agreement across every implementation is proven by the differential parity run, and the latest matrix."
tags: ["parity", "differential"]
group: "contract"
language: "en"
audience: ["developer", "agent"]
---

# Parity

How agreement across implementations is proven. The request format and the shim protocol are
normative and live in [contract.md](contract.md#parity-shim-protocol).

[Index](index.md#toc) · [Contract](contract.md#toc) · [Structures](structures/README.md#toc) · [KAN story](kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [Method](#method)
- [Matrix (measured, scale 1)](#matrix-measured-scale-1)
- [Run it](#run)

<a id="method"></a>

## Method

1. **One oracle.** [`tools/oracle.py`](../tools/oracle.py) is the contract, executed with
   arbitrary-precision divmod, Horner sums and a numeric range guard. It shares no algorithm with
   any fast path, so agreeing with it is real evidence.
2. **One frozen corpus.** [`vectors/`](../vectors/) is generated from the oracle using pinned
   seeds, and every language suite asserts all of it:
   - 4,264 valid rows;
   - 1,725 decode refusals, balanced across LENGTH, NAMESPACE, CHARSET and RANGE;
   - 127 encode refusals;
   - 306 node rows.

   `make vectors` regenerates the files and fails on any drift.
3. **One differential run.** [`tools/parity.py`](../tools/parity.py) builds every shim and sends
   each one the same 30,651 requests (×N with `--scale`):
   - uniform values and boundaries;
   - **every byte value at every position** of four seed ids;
   - lengths 0–20, including 15 and 16 (reserved for brd15/brd16, so LENGTH here);
   - the max-payload neighbourhood;
   - multi-fault precedence probes.

   It then diffs every response line against the oracle.
4. **A harness with teeth.** `parity.py --self-test` must pass the oracle *and* catch a mutant that
   swaps two alphabet characters (`q`↔`r`). That is the "pin-evading permutation" class that
   exact-byte vectors alone can miss. It catches the mutant on 1,145 requests.

<a id="matrix-measured-scale-1"></a>

## Matrix (measured, scale 1)

| Shim | Impl / variant | Ops | Requests | Mismatches | Status |
|---|---|---|---:|---:|---|
| go | go / reference | DEFGHNU | 30,714 | 0 | PASS |
| c-speed | c / speed | DEHU | 28,642 | 0 | PASS |
| c-memory | c / memory | DEHU | 28,642 | 0 | PASS |
| rust-speed | rust / speed | DEFHNU | 30,651 | 0 | PASS |
| rust-memory | rust / memory | DEFHNU | 30,651 | 0 | PASS |
| python-3.14 | python / pure | DEFGHNU | 30,714 | 0 | PASS |
| python-3.14t | python / pure (free-threaded, GIL off) | DEFGHNU | 30,714 | 0 | PASS |
| python-3.12 | python / pure | DEFGHNU | 30,714 | 0 | PASS |
| ts-pure-node | ts / pure on Node 24.21.0 | DEFHNU | 30,651 | 0 | PASS |
| ts-pure-bun | ts / pure on Bun 1.4.3 | DEFHNU | 30,651 | 0 | PASS |
| ts-wasm-node | ts / wasm on Node 24.21.0 | DEH | 27,637 | 0 | PASS |
| ts-wasm-bun | ts / wasm on Bun 1.4.3 | DEH | 27,637 | 0 | PASS |
| sh-bash | sh / bash ([`scripts/brd.sh`](../scripts/brd.sh)) | DEFHNU | 30,651 | 0 | PASS |
| ex-pure | ex / pure ([`ex/echo_data`](../ex/echo_data/README.md)) | DEFHLNPU | 34,224 | 0 | PASS |

**14 of 14 shims pass with 0 mismatches** (`parity.py --require`, on `claude/virtual-clock`).
- `G` is the [virtual clock](contract.md#virtual-clock-experimental) extension: 63 requests,
  answered by Go and Python. Each replays a generator program on an injected clock, so generators
  are differential-tested. `L P` are layout profiles, answered by `ex-pure`.
- At `--scale 10` the Go, C and Rust shims were also checked: 154k–175k requests each, 0
  mismatches.
- Python was also checked at `--scale 4`.
- The C shims declare `DEHU` because the C ABI has no node derivation or field reader. The
  wasm shims declare `DEH`: only encode, decode and hash32 cross the wasm ABI.
- `python/conform.py` also cross-checks the library against itself (decode, check, is_valid and
  parse over bytes, bytearray and str) and answers `ERR DISAGREE` on any split.

<a id="run"></a>

## Run it

```bash
. scripts/env.sh
python3 tools/parity.py                 # every available shim
python3 tools/parity.py --only rust-    # by name prefix
python3 tools/parity.py --require       # CI: a missing shim is a failure
python3 tools/parity.py --self-test     # the harness must pass the oracle and catch the mutant
```

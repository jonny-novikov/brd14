---
id: "KAN0R9YJSz0Bmb"
slug: "BENCH-README"
type: "guide"
version: "1.3"
path: "bench/README.md"
title: "Benchmarks — protocol and result schema"
summary: "The benchmark protocol every tree follows and the JSON schema of bench/results."
tags: ["benchmarks", "protocol"]
group: "measurement"
language: "en"
audience: ["developer", "agent"]
---

# Benchmarks — protocol and result schema

Every tree's `make bench` measures the same operations over the same corpus and writes one JSON
file per (implementation, variant, runtime) into `bench/results/`. `tools/benchreport.py` renders
them into [`docs/benchmarks.md`](../docs/benchmarks.md).

[Index](../docs/index.md#toc) · [Contract](../docs/contract.md#toc) · [Structures](../docs/structures/README.md#toc) · [Parity](../docs/parity.md#toc) · [KAN story](../docs/kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [Protocol](#protocol)
- [Result schema](#result-schema)

<a id="protocol"></a>

## Protocol

- **Corpus:** the first 4096 data rows of [`vectors/valid.tsv`](../vectors/valid.tsv). Use the
  `snow` column for encode, hash32 and fields, and the `id` column for decode. Cycle through all
  4096 rows in order inside the timed loop, so a branch predictor cannot memorise one input.
- **Operations** (required names):
  - `encode`: snow → id, through the idiomatic string-returning API;
  - `decode`: id → (ns, snow);
  - `hash32`;
  - `mint`: next branded id from a generator, where the implementation has one.

  Implementations may add variant-specific ops, for example `encode_append` (Go zero-alloc),
  `decode_parts` (TS, no BigInt), `encode_many` / `decode_many` (wasm batches) and `valid`.
- **Sampling:** warm up first. Take at least 10 samples, each long enough to measure (≥ 50 ms).
  Report `ns_per_op` as the **median** sample and `mad_ns` as the median absolute deviation.
- **Isolation:** run pinned to one core (`taskset -c 2` when available). Report the CV, and treat
  results above 5% as noisy.
- **Sink:** every result must reach a sink (`black_box`, a volatile, an accumulator that is
  printed), so the compiler or JIT cannot delete the work.

<a id="result-schema"></a>

## Result schema

```json
{
  "impl": "go",                  // go | c | rust | python | ts | ts-wasm
  "variant": "reference",        // reference | speed | memory | pure | wasm
  "runtime": "go1.26.9",         // e.g. gcc-13.3 -O2, rustc-1.99.0, cpython-3.14.8, cpython-3.14.8t, node-24.21.0, bun-1.4.3
  "machine": "Intel(R) Xeon(R) Processor @ 2.80GHz",   // lscpu "Model name"
  "pinned": true,
  "corpus": "vectors/valid.tsv rows 1..4096",
  "results": [
    {"op": "encode", "ns_per_op": 12.3, "mad_ns": 0.2, "samples": 10,
     "allocs_per_op": 1, "bytes_per_op": 16}   // allocs/bytes: when the runtime can report them
  ]
}
```

File name: `bench/results/<impl>-<variant>-<runtime>.json` (runtime with `/` and spaces replaced by `-`).

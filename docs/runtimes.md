---
id: "KAN0R9YJSzZO2m"
slug: "DOCS-RUNTIMES"
type: "guide"
version: "1.3"
path: "docs/runtimes.md"
title: "Runtimes"
summary: "Runtime specifics side by side: Node 24 and Bun 1.4, CPython 3.14 and 3.14t, Go 1.26."
tags: ["runtimes", "node", "bun", "cpython"]
group: "environment"
language: "en"
audience: ["developer", "agent"]
---

# Runtimes

Runtime specifics side by side. The per-language pages go deeper: [go.md](go.md),
[python.md](python.md), [typescript.md](typescript.md), [c.md](c.md), [rust.md](rust.md).
Numbers are the W2 baseline in [benchmarks.md](benchmarks.md): single runs on a shared machine,
so read the ratios.

[Index](index.md#toc) · [Contract](contract.md#toc) · [Structures](structures/README.md#toc) · [Parity](parity.md#toc) · [KAN story](kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [Side by side](#side-side)
- [Reading the numbers](#reading-numbers)

<a id="side-side"></a>

## Side by side

| Runtime | What matters for brd14 | Measured |
|---|---|---|
| **Go 1.26** (floor 1.22) | Escape analysis keeps `AppendEncode` and `ParseBytes` on the stack. The string-returning `Encode` pays exactly one 16-byte allocation. Typed errors are preallocated, so refusals allocate nothing. | append-encode 16 ns with 0 allocs; `Encode` 35 ns with 1 alloc; `ParseBytes` 11 ns; `Next` 66 ns, of which `time.Now` is about 61 ns |
| **C (gcc 13.3)** | Constant divisors are strength-reduced. At `-Os`, gcc emits real `div` instructions, so the memory core writes out multiply-high itself (`__int128`, with a portable fallback). | speed: encode 6.7 ns, decode 11.7 ns. memory: 17.7 and 28.6 ns |
| **Rust 1.99** | `no_std`, `forbid(unsafe_code)` in the core. The speed decode's range guard runs in registers (two big-endian words), which removed its last libc import. | speed: 5.7 and 8.6 ns. memory: 16.7 and 21.9 ns |
| **CPython 3.14** | Pure Python. Encode uses a split at 62⁵ plus a 3,844-entry pair table; decode uses C-level string checks plus `translate`. Each call creates its result object. | encode 468 ns, decode 677 ns (3.12: 598 and 779) |
| **CPython 3.14t** (free-threaded) | The generator needs its `Lock`: no lock means duplicates. Lookup tables are literals loaded from `.pyc`, so threads share them without contention. Use one generator per thread. | single-thread about 1.3× slower than 3.14. Encode scales 3.3× on 4 threads; a shared generator scales *down* to 0.3–0.7× |
| **Node 24.21 (V8)** | Runs `.ts` unbuilt through type stripping, but not under `node_modules`; workspace symlinks resolve to realpaths, so it works. Exact 64-bit arithmetic on Numbers (intermediates stay below 2⁵³). | encode 129 ns, decode 184 ns. **19×** faster than naive BigInt for encode |
| **Bun 1.4.3 (JSC)** | Runs `.ts` natively. `bun test` maps `import … from "vitest"` onto `bun:test`, so one test source serves both runtimes. The container exports `BUN_OPTIONS=--smol` (a low-memory GC); clear it for benchmarks. | encode 231 ns, decode 216 ns (baseline under `--smol`). Fastest parity shim: about 295k req/s |
| **BEAM (NIF)** | The NIF is sub-microsecond, so normal schedulers are fine. Every error class collapses to `:error`. A namespace that isn't 3 bytes raises `badarg` (open decision, see [roadmap](roadmap.md)). | not measured here (no ERTS in this container) |

<a id="reading-numbers"></a>

## Reading the numbers

These are the W2 baseline, single runs on a shared machine. Compare ratios within one runtime, not
absolute nanoseconds across machines. The protocol, and how to re-run it pinned to a core, is in
[bench/README.md](../bench/README.md); the consolidated run is a roadmap item
([roadmap.md](roadmap.md)).

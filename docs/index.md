---
id: "KAN0R9YJSxIb0C"
slug: "DOCS-INDEX"
type: "index"
version: "1.3"
path: "docs/index.md"
title: "brd14 documentation"
summary: "The reading route through the brd14 documentation: the contract and its proof, every implementation, the branded structures, measurement, and delivery."
tags: ["brd14", "navigation"]
group: "navigation"
language: "en"
audience: ["Operator", "developer", "agent"]
---

# brd14 documentation

Every page of the corpus is listed here once, by what you get from it. Agents start with
[AGENTS.md](../AGENTS.md#toc) (where things are) and [CLAUDE.md](../CLAUDE.md#toc) (how to work);
the current program is the [KAN story](kan/brd14-pragmatic-guide.md#toc).

[Repository](../README.md#toc) · [AGENTS](../AGENTS.md#toc) · [CLAUDE](../CLAUDE.md#toc) ·
[Contract](contract.md#toc) · [Structures](structures/README.md#toc) · [KAN story](kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [Start here](#start)
- [The contract and its proof](#contract)
- [Implementations](#implementations)
- [Branded structures](#structures)
- [Runtimes, environment, measurement](#measurement)
- [Delivery and operations](#delivery)

<a id="start"></a>

## Start here

| Page | What you get from it |
|---|---|
| [README](../README.md#toc) | What brd14 is, the implementations, the quick start. |
| [AGENTS.md](../AGENTS.md#toc) | Where things are: the map, the sources of truth, search recipes. |
| [CLAUDE.md](../CLAUDE.md#toc) | How to work here: phases, sizing, the repository's laws, KAN delivery. |
| [kan/brd14-pragmatic-guide.md](kan/brd14-pragmatic-guide.md#toc) | The pragmatic programmer's guide as one KAN story: layout profiles, branded structures, the NIF, decisions and rungs. |

<a id="contract"></a>

## The contract and its proof

| Page | What you get from it |
|---|---|
| [contract.md](contract.md#toc) | **Normative.** The format, operations, error precedence, vectors, the parity protocol, the WASM ABI, the format family, and the extensions (layout profiles). |
| [parity.md](parity.md#toc) | How agreement across implementations is proven, and the latest matrix. |
| [structures/spec.md](structures/spec.md#toc) | **Normative** for the structures extension: the champ's exact shape and digest, Tree and Buckets behaviour, the vectors. |

<a id="implementations"></a>

## Implementations

| Page | What you get from it |
|---|---|
| [go.md](go.md#toc) | The Go reference: API, zero-allocation guarantees and how they are proven. |
| [c.md](c.md#toc) | The C cores: speed vs memory, footprint, the ABI, tests, benches, fuzzing. |
| [rust.md](rust.md#toc) | The Rust workspace: `no_std` core, FFI drop-in, the wasm crate. |
| [beam.md](beam.md#toc) | The Erlang NIF over the C ABI and how to build it against either core. |
| [elixir.md](elixir.md#toc) | `ex/echo_data`: the BEAM implementation, standalone on Elixir ≥ 1.14, and how it is proven. |
| [python.md](python.md#toc) | The pure-Python package, CPython 3.14 and free-threaded 3.14t specifics. |
| [typescript.md](typescript.md#toc) | The pure TypeScript package: exact 64-bit arithmetic without BigInt. |
| [wasm.md](wasm.md#toc) | The TypeScript-over-WebAssembly package: ABI, loader, batching. |
| [cli.md](cli.md#toc) | The shell tools: `brd` and `mint`, the `.brdrc` settings file, recipes. |

<a id="structures"></a>

## Branded structures

| Page | What you get from it |
|---|---|
| [structures/README.md](structures/README.md#toc) | What the id knows and the structures that use it; how to choose. |
| [structures/champ.md](structures/champ.md#toc) | The persistent CHAMP forest: nodes, a worked trie, collisions, canonical deletes, the off-heap NIF. |
| [structures/tree.md](structures/tree.md#toc) | The ordered map: cursors, time windows, feeds, pitfalls of time order. |
| [structures/buckets.md](structures/buckets.md#toc) | Generational expiry: bucket arithmetic, what expiry keeps, the namespace caveat. |
| [structures/layout-profiles.md](structures/layout-profiles.md#toc) | Metadata inside the id: the bits, why meta is lowest, binding a profile to a namespace. |
| [structures/proof.md](structures/proof.md#toc) | How equivalence across runtimes is proven, and how to debug a digest mismatch. |

<a id="measurement"></a>

## Runtimes, environment, measurement

| Page | What you get from it |
|---|---|
| [architecture.md](architecture.md#toc) | How the repository is laid out, the variant taxonomy (pure · speed · memory), how the pieces depend on each other. |
| [environment.md](environment.md#toc) | The pinned toolchains, how they are installed, the SessionStart hook. |
| [runtimes.md](runtimes.md#toc) | Runtime specifics side by side: Node 24 vs Bun 1.4, CPython 3.14 vs 3.14t, Go 1.26. |
| [benchmarks.md](benchmarks.md#toc) | Measured numbers, the protocol behind them, how to reproduce them. |
| [hardening.md](hardening.md#toc) | Sanitizers, Miri, fuzzing, race detection, floor toolchains. |
| [bench/README.md](../bench/README.md#toc) | The benchmark protocol and the result schema. |

<a id="delivery"></a>

## Delivery and operations

| Page | What you get from it |
|---|---|
| [ci.md](ci.md#toc) | CI on Fly.io: the `brd-build` app runs `scripts/ci.sh` once per deploy; setup, results, limits. |
| [roadmap.md](roadmap.md#toc) | What is done, what is next — implementation, measurement, CI — and the open decisions. |

Every page follows the KAN documentation contract (frontmatter, `#toc`, explicit anchors, a link
back here), and `python3 tools/doclint.py` checks it.

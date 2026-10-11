---
id: "KAN0R9YJT08aIv"
slug: "DOCS-STRUCTURES-PROOF"
type: "guide"
version: "1.3"
path: "docs/structures/proof.md"
title: "Proving the structures"
summary: "How the structures are proven equivalent across runtimes — oracle, vectors, models, mutants — and how to debug a digest mismatch."
tags: ["proof", "vectors", "mutants"]
group: "structures"
language: "en"
audience: ["developer", "agent"]
---

# Proving the structures

Three runtimes implement the same structures without sharing code. They are proven equivalent
the way the codec is: an independent oracle, generated vectors, and models that a planted bug
must fail.

[Index](../index.md#toc) · [Structures](README.md#toc) · [Spec](spec.md#toc) · [Champ](champ.md#toc) · [Tree](tree.md#toc) · [Buckets](buckets.md#toc) · [Layout profiles](layout-profiles.md#toc)

<a id="toc"></a>

## In this document

- [The layers of proof](#layers)
- [The shape digest](#digest)
- [The vectors](#vectors)
- [Constructing collisions](#constructing)
- [Mutants: proof that the tests can fail](#mutants)
- [Running the proofs](#running)
- [When a digest does not match](#debugging)

<a id="layers"></a>

## The layers of proof

| Layer | What it proves | Where |
|---|---|---|
| **The oracle** | the champ, built from [spec.md](spec.md) alone in plain Python | `tools/champ_oracle.py` |
| **Vectors** | every runtime builds the oracle's trie: same size, same shape digest, same read-back | `vectors/champ.tsv` (generated) |
| **Models** | each structure behaves as a plain map, sorted list or bucket filter on random operation streams | each runtime's property tests |
| **Mutants** | the tests can fail: a planted bug must be caught | the oracle self-test; the Elixir suite |
| **Parity** | layout profiles agree with the oracle on 3 500+ requests | `tools/parity.py`, ops `L` and `P` |

<a id="digest"></a>

## The shape digest

A digest is FNV-1a-64 over the trie written in preorder:
- a bitmap node writes `N`, `datamap`, `nodemap`, its inline keys, then its children;
- a collision node writes `C`, its count and its keys.

Values are left out. Equal digests mean equal shape and equal iteration order. The digest is how
a 100 000-step run in Go is compared with the same run in Elixir without printing the trie.

<a id="vectors"></a>

## The vectors

`vectors/champ.tsv` has two kinds of rows:

- **explicit** rows carry a program of puts and deletes. There are 21, pinning the corners:
  - a split at level 0, at level 1, and at level 6;
  - collisions of two, three and four keys;
  - prepend versus replace;
  - delete with collapse, a delete that keeps a collision, deletes of absent keys, deleting
    everything;
  - the largest snowflake.
- **stream** rows carry a seed, an operation count and a key-pool size. The program is derived
  with SplitMix64 exactly as [spec.md](spec.md#vectors) states. There are 10, from 16 operations
  to 100 000.

Each row pins the final size and digest. A replay must also read back every key of the pool: the
value of its last put, or absent after its last delete.

<a id="constructing"></a>

## Constructing collisions

Random keys rarely collide on all 32 bits, so the vectors construct them. `hash32(k)` is the low
32 bits of `f(k) = g(C · g(k))`, where:
- `g(y) = y ^ (y >> 33)` is an involution, its own inverse;
- `C = 0xFF51AFD7ED558CCD` is odd, so it has an inverse modulo 2⁶⁴.

So `f` is a bijection on 64 bits, and `f⁻¹(y) = g(C⁻¹ · g(y))`. To make keys with a chosen hash,
pick outputs `y` with those low 32 bits, invert, and keep the results below 2⁶³. Choosing only
some low bits gives keys that split at a chosen level.

<a id="mutants"></a>

## Mutants: proof that the tests can fail

| Planted bug | Caught by |
|---|---|
| a collision put appends instead of prepending | the oracle's self-test (the triple-collision digest changes) |
| `page_after` includes the cursor | Elixir property suite |
| `between` closed at the top (`<=`) | Elixir property suite — only after its generator put a quarter of the ids on a millisecond boundary; uniform draws never hit it |
| `between` opened at the bottom | Elixir property suite |
| expiry drops the cutoff's own bucket (`<=`) | Elixir property suite |
| a layout generator with meta above the sequence | the oracle's 20 000-mint monotonicity check |

<a id="running"></a>

## Running the proofs

```bash
python3 tools/champ_oracle.py                       # the oracle's self-test
make vectors                                        # regenerate; fails on drift
make -C ex test                                     # Elixir: champ.tsv replay, properties (NIF and pure)
python3 tools/parity.py --only go,rust-,ex-         # layout profiles vs the oracle
scripts/ci.sh oracle ex parity                      # the same, as CI runs them
```

Go (`go test ./brdata/`) and Rust (`cargo test -p brd14-data`) replay the same file once rung R4
lands.

<a id="debugging"></a>

## When a digest does not match

1. Replay the row in the oracle and print the trie. `tools/champ_oracle.py` exposes `run(program)`
   and the node classes; the worked example in [champ.md](champ.md#worked) was printed that way.
2. Find the first operation where the shapes diverge: replay prefixes of the program and compare
   digests.
3. The usual causes:
   - fragments taken from the most significant end instead of the least;
   - the wrong order in a split (the smaller fragment must come first);
   - a collision put appending;
   - collapse missing at some level;
   - a different hash (the champ must use `hash32` of the snowflake, never a hash of the id
     string).

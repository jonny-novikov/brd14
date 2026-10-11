---
id: "KAN0R9YJSzqzAp"
slug: "DOCS-STRUCTURES-README"
type: "index"
version: "1.3"
path: "docs/structures/README.md"
title: "Branded structures"
summary: "What a brd14 id already knows and the structures that use it — champ, tree, buckets, layout profiles — and how to choose."
tags: ["structures", "champ", "tree", "buckets"]
group: "structures"
language: "en"
audience: ["developer", "agent"]
---

# Branded structures

A brd14 id is not an opaque key. It carries four facts, and each of them can be turned into a
data structure that does not have to rebuild that fact. This folder documents those structures
in Go, Rust and Elixir: what each one is for, how it works, how it is proven, and how to choose
between them.

[Index](../index.md#toc) · [Spec](spec.md#toc) · [Champ](champ.md#toc) · [Tree](tree.md#toc) · [Buckets](buckets.md#toc) · [Layout profiles](layout-profiles.md#toc) · [Proof](proof.md#toc)

<a id="toc"></a>

## In this document

- [What the id already knows](#facts)
- [Choosing a structure](#choose)
- [The pages](#pages)
- [Where each structure lives](#runtimes)

<a id="facts"></a>

## What the id already knows

```
USR0KHTOWnGLuC        same namespace: byte order == mint order
└┬┘└─────┬────┘
 │       └─ base62( ts(41) | node | seq | meta )      the 22 low bits are a layout profile
 └───────── namespace: the partition, the type, the policy key
```

| Fact | Where it is in the id | A generic structure | The branded structure |
|---|---|---|---|
| **Namespace** | the 3-letter prefix | one map for every type; filtering by prefix on every scan | one inner structure **per namespace**; `namespace_size` is O(1); work in one namespace never touches another |
| **Hash** | `hash32(snowflake)`, a contract function | hashes the 14-byte string again on every operation | the [champ](champ.md) routes by `hash32`; trie placement is identical in every runtime |
| **Mint order** | the 41-bit timestamp in the high bits; bytes compare in that order | sort the keys to page, or keep a separate `created_at` index | the [tree](tree.md): `first`, `last`, `page_after(cursor)`, `between(t0, t1)` without a sort |
| **Mint time** | the same timestamp | an `expires_at` per entry and a sweep that visits each one | the [buckets](buckets.md): `bucket = snowflake >> (22 + bits)`; expiry drops whole buckets |

A fifth page covers the bits under the timestamp: [layout profiles](layout-profiles.md) put a
few bits of metadata, such as audit flags or a tenant shard, inside a valid 14-byte id.

<a id="choose"></a>

## Choosing a structure

1. **Do you need the entries in creation order** (a feed, a cursor page, a time window)? Use the
   **tree**.
2. **Do you drop entries by age** (sessions, presence, rate-limit windows, ephemeral caches)?
   Use the **buckets**.
3. **Do you need any of the following?** Use the **champ**:
   - snapshots of the whole map that cost nothing to keep;
   - two versions you can compare by shape;
   - the same placement across Go, Rust and the BEAM;
   - on the BEAM, a large index held off the process heap and passed between processes by
     reference (`EchoData.NativeChamp`).
4. **Otherwise use the plain map of the language, one per namespace.** On the BEAM that is
   `EchoData.BrandedMap`, which rides the VM's native HAMTs and is the default choice.

| | Lookup | Insert | Ordered scan | Expiry | Snapshot | Persistent in |
|---|---|---|---|---|---|---|
| plain map per namespace | O(1) | O(1) | sort first | visit every entry | copy | Elixir (immutable maps) |
| [champ](champ.md) | O(log₃₂ n) | O(log₃₂ n), one path copied | hash order only | visit every entry | **free** | Go, Rust, Elixir |
| [tree](tree.md) | O(log n) | O(log n) | **free** (key order) | range delete | copy (Go, Rust) | Elixir |
| [buckets](buckets.md) | O(1), two hops | O(1), two hops | by bucket | **O(buckets)** | copy (Go, Rust) | Elixir |

Measured costs, against the plain baselines in each language, are in
[docs/benchmarks.md](../benchmarks.md) once the measured runs are committed. The smoke figures
seen during development are not results.

<a id="pages"></a>

## The pages

| Page | What you get |
|---|---|
| [spec.md](spec.md) | **Normative.** The champ exactly, node by node; the shape digest; the vectors; Tree and Buckets behaviour. |
| [champ.md](champ.md) | The CHAMP forest explained: nodes, fragments, a worked trie, collisions, canonical deletes, persistence, the off-heap NIF. |
| [tree.md](tree.md) | The ordered map: cursors, time windows, feeds, and the pitfalls of time order across nodes. |
| [buckets.md](buckets.md) | Generational expiry: the bucket arithmetic, granularity, what expiry keeps, and the namespace caveat. |
| [layout-profiles.md](layout-profiles.md) | Metadata inside the id: the bit layout, why meta is lowest, choosing a profile, binding it to a namespace. |
| [proof.md](proof.md) | How equivalence across runtimes is proven, how to run each proof, and how to debug a digest mismatch. |

<a id="runtimes"></a>

## Where each structure lives

| Structure | Go | Rust | Elixir |
|---|---|---|---|
| champ | `go/brdata` `Champ[V]` | `brd14-data` `Champ<V>` | `EchoData.BrandedChamp` over `EchoData.ChampNode`; `EchoData.NativeChamp` (NIF) |
| tree | `go/brdata` `Tree[V]` | `brd14-data` `Tree<V>` | `EchoData.BrandedTree` (`:gb_trees`) |
| buckets | `go/brdata` `Buckets[V]` | `brd14-data` `Buckets<V>` | `EchoData.Buckets` |
| layout profiles | `brd14.Layout` | `brd14::layout` | `EchoData.Layout` |

The Elixir structures come from the echo umbrella and are proven here. The Go and Rust
structures are built in rung R4 of the [KAN story](../kan/brd14-pragmatic-guide.md#rungs);
their pages gain API sections as each lands.

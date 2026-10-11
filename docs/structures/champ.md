---
id: "KAN0R9YJT08aIr"
slug: "DOCS-STRUCTURES-CHAMP"
type: "guide"
version: "1.3"
path: "docs/structures/champ.md"
title: "The champ: a persistent CHAMP forest"
summary: "The persistent CHAMP forest explained: nodes and fragments, a worked trie, collisions, canonical deletes, persistence, the off-heap NIF."
tags: ["champ", "hamt", "persistent"]
group: "structures"
language: "en"
audience: ["developer", "agent"]
---

# The champ: a persistent CHAMP forest

`BrandedChamp` is a map from branded ids to values, built as one **CHAMP** trie per namespace. A
CHAMP is a Compressed Hash-Array Mapped Prefix-tree. Every write returns a new map and leaves the
old one intact, sharing every node the write did not touch. The trie is placed by the contract's
own `hash32(snowflake)`, so the same operations build the same trie, node for node, in Go, Rust
and Elixir. The exact rules are in [spec.md](spec.md); this page explains them.

[Index](../index.md#toc) · [Structures](README.md#toc) · [Spec](spec.md#toc) · [Tree](tree.md#toc) · [Buckets](buckets.md#toc) · [Layout profiles](layout-profiles.md#toc) · [Proof](proof.md#toc)

<a id="toc"></a>

## In this document

- [Why a CHAMP](#why)
- [Nodes and fragments](#nodes)
- [A worked trie](#worked)
- [Collisions](#collisions)
- [Deletes and canonical form](#deletes)
- [Persistence and structural sharing](#persistence)
- [Cost model](#complexity)
- [Off-heap on the BEAM: EchoData.NativeChamp](#native)
- [API by runtime](#api)

<a id="why"></a>

## Why a CHAMP

A hash-array mapped trie (HAMT) splits a 32-bit hash into 5-bit fragments, one per level. Each
fragment picks one of 32 slots, and a node stores only the occupied slots behind a bitmap.
**CHAMP** (Steindorfer and Vinju, OOPSLA 2015; *cited*) refines it in two ways:

- **Two bitmaps per node.** `datamap` marks inline key-value pairs and `nodemap` marks children.
  Pairs are stored first and children after, so iteration reads all the data of a node before
  descending into it.
- **Canonical deletion.** When a delete leaves a sub-node holding a single entry, that entry
  moves back up into its parent. A given set of keys therefore has one trie shape, whatever
  inserts and deletes produced it. The one exception is collision lists (see
  [Collisions](#collisions)).

The branded variant adds two things. The hash is **not computed from the 14-byte id** but taken
from the contract (`hash32` of the snowflake). And the forest keeps **one trie per namespace**,
with a size counter per namespace.

<a id="nodes"></a>

## Nodes and fragments

```
bitmap node                                   collision node (level 7 only)
┌──────────┬──────────┬──────────────────┐   ┌──────────────────────────────┐
│ datamap  │ nodemap  │ k₀ v₀ k₁ v₁ … c₀ c₁ │   │ [(k, v), (k, v), …]  in order │
└──────────┴──────────┴──────────────────┘   └──────────────────────────────┘
 bit b set → pair at popcount(datamap & (b-1))
 bit b set → child at popcount(nodemap & (b-1))
```

The fragment at level `L` is `(hash32 >> 5L) & 31`. Seven levels (0 to 6) consume the hash. Level
6 sees only bits 30 and 31, so its fragment is in 0..3. Two keys whose 32-bit hashes are equal
cannot be separated by any fragment, and they meet in a **collision node** at level 7.

<a id="worked"></a>

## A worked trie

Four keys in namespace `USR`. Their hashes and fragments, computed by the oracle
(`tools/champ_oracle.py`):

| Key | Id | `hash32` | Fragments L0..L6 |
|---|---|---|---|
| V1 | `USR0KHTOWnGLuC` | `0x0dfff4a6` | 6, 5, 29, 31, 31, 6, 0 |
| V2 | `USR0NgWEfAEJfs` | `0xdc374c2d` | 13, 1, 19, 14, 3, 14, 3 |
| K3 | `USR8RWqeUR9Go7` | `0x0dfff486` | 6, **4**, 29, 31, 31, 6, 0 |
| K4 | `USR8AlvQCQPfcZ` | `0x0dfff4a6` | identical to V1: a full collision |

K3 and K4 were not found by search. They were constructed: `hash32` is the low half of a bijection
on 64 bits, so the oracle inverts it for any wanted hash (see [proof.md](proof.md#constructing)).

**Put V1, V2.** Their level-0 fragments differ (6 and 13), so both sit inline in the root:

```
L0  datamap {6, 13}   data [V1, V2]                                digest d456f44f50d29684
```

**Put K3.** Its level-0 fragment is 6, which V1 already holds. V1 moves down into a new child and
splits at level 1 by fragments 5 and 4. The smaller fragment comes first:

```
L0  datamap {13}  nodemap {6}   data [V2]
└─ L1  datamap {4, 5}           data [K3, V1]                      digest 51de18b43c222aef
```

**Put K4.** It follows V1's path all the way down. Every level holds a single child until the hash
is exhausted, and the two keys meet in a collision node at level 7. The stored pair comes first,
the new one second:

```
L0  datamap {13}  nodemap {6}   data [V2]
└─ L1  datamap {4}  nodemap {5}   data [K3]
   └─ L2 nodemap {29} → L3 {31} → L4 {31} → L5 {6} → L6 {0}
      └─ L7  collision [V1, K4]                                    digest 65b38bcd1ea3a928
```

**Delete K4, then K3.** The collision keeps one pair, which rises level by level to the root; then
K3 leaves and V1 rises again:

```
L0  datamap {6, 13}   data [V1, V2]                                digest d456f44f50d29684
```

The digest is **identical** to the state after the first two puts. That is canonical form: same
keys, same shape.

<a id="collisions"></a>

## Collisions

Full 32-bit collisions are rare but not negligible. By the birthday bound, about 77 000 random
keys give an even chance of one colliding pair (*formula*: √(2³² · 2 ln 2) ≈ 77 163), and a
namespace of millions of entries holds many. The rules are exact:

- a **new** key put into a collision node is **prepended**;
- a put of a key **already** in the list **replaces its value in place**;
- a delete keeps the order of the remaining pairs;
- a collision node left with one pair collapses into its parent.

Prepending means the list order depends on history, so collision lists are the one place where
two tries with the same keys can differ in shape. The vectors pin all three behaviours: prepend,
replace and collapse.

<a id="deletes"></a>

## Deletes and canonical form

After deleting from a child, the parent looks at what is left:

| The child now is | The parent does |
|---|---|
| a collision node with one pair | pulls that pair inline at its own level |
| a bitmap node with no children and one inline pair | pulls that pair inline |
| anything else | keeps the child |

The check runs on the way back up at every level, so a lone survivor rises as far as it can. A
chain of single-child nodes left by a deep split dissolves completely.

<a id="persistence"></a>

## Persistence and structural sharing

A put or delete copies only the nodes on the path from the root to the change: at most 8 nodes,
each holding at most 32 slots. Everything else is shared with the previous version. Holding on to
an old version costs the nodes that were replaced, nothing more. That makes three things cheap:

- **snapshots for readers**: a reader keeps a version while writers move on, with no lock;
- **undo and diff**: keep the previous version and compare it with the new one;
- **handing a map to another thread or process**: on the BEAM, see [off-heap](#native).

In Elixir every value is immutable anyway. In Go and Rust the champ is the persistent choice;
the tree and buckets there are mutable, with an explicit `Clone()`. That decision is SDMR card 3
of the [KAN story](../kan/brd14-pragmatic-guide.md#sdmr).

<a id="complexity"></a>

## Cost model

| Operation | Cost |
|---|---|
| `get` | at most 8 node hops (7 levels + a collision list); each hop is a popcount and an index |
| `put`, `delete` | the same walk, plus copying the nodes on the path |
| `size`, `namespace_size` | O(1): counters kept by the forest |
| iteration | O(n), in trie order: hash order within a namespace, namespaces ascending |
| a snapshot | O(1): keep the reference |

Iteration order is **hash order, not key order**. For creation order use the [tree](tree.md).

<a id="native"></a>

## Off-heap on the BEAM: `EchoData.NativeChamp`

`EchoData.NativeChamp` is the Rust champ (`brd14-data`) behind a Rustler NIF resource. It has the
same API and the same shape as `BrandedChamp`: the same operations give the same digest and the
same iteration order. Its trade-offs:

- **Gains:** the entries live outside the process heap, so garbage collection never scans or
  copies them, and sending the champ to another process copies a reference, not the entries.
- **Costs:** values cross the NIF boundary as external term format, encoded on `put` and decoded
  on `fetch`, so a point read of a large value costs more than in `BrandedChamp`.
- **Semantics:** a write returns a new resource and the old one stays valid, so value semantics
  are kept.
- **Requirement:** it needs the NIF (`EchoData.NativeChamp.available?/0`). It is built by
  `mix compile` when cargo is present.

The NIF arrives with rung R5. Until the measured runs are committed, choose it for **sharing and
GC relief**, not for point-read speed.

<a id="api"></a>

## API by runtime

**Elixir** (`EchoData.BrandedChamp`, verified):

| Call | Result |
|---|---|
| `new()` / `new([{id, value}])` | a forest |
| `put!(c, id, v)` / `put(c, id, v)` | a new forest; `ArgumentError` on an invalid id |
| `fetch(c, id)` / `get(c, id, default)` | `{:ok, v}` or `:error` (an invalid id reads as absent) |
| `delete(c, id)` | a new forest |
| `put_by_snowflake/4`, `fetch_by_snowflake/3`, `delete_by_snowflake/3` | the same by `(ns, snowflake)`, without the codec |
| `size/1`, `namespace_size/2`, `namespaces/1` | counters |
| `to_list/1`, `to_snowflake_list/1`, `Enum.*` | trie order, streamed |

**Go** (`go/brdata`) and **Rust** (`brd14-data`): the API sections land with rung R4. The specs
the implementations were built to are the champ semantics in [spec.md](spec.md), with the same
names: `Put`/`insert`, `Get`/`get`, `Delete`/`remove`, the `*Snow` forms, `Len`,
`NamespaceLen`, `All`/`iter` and `ShapeDigest`/`shape_digest`.

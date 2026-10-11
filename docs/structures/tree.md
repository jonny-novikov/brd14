---
id: "KAN0R9YJT08aIs"
slug: "DOCS-STRUCTURES-TREE"
type: "guide"
version: "1.3"
path: "docs/structures/tree.md"
title: "The tree: creation order without a sort"
summary: "The ordered branded map: creation order without a sort, cursors, time windows, feeds and their pitfalls."
tags: ["tree", "ordered", "cursors"]
group: "structures"
language: "en"
audience: ["developer", "agent"]
---

# The tree: creation order without a sort

`BrandedTree` keeps, per namespace, its entries ordered by snowflake. A snowflake's high 41 bits
are its mint time, so **key order is creation order**. Feeds, cursors and time windows become
range reads on the key: no sort, no `created_at` column, no secondary index.

[Index](../index.md#toc) · [Structures](README.md#toc) · [Spec](spec.md#toc) · [Champ](champ.md#toc) · [Buckets](buckets.md#toc) · [Layout profiles](layout-profiles.md#toc) · [Proof](proof.md#toc)

<a id="toc"></a>

## In this document

- [Why key order is time order](#order)
- [Operations](#operations)
- [Patterns](#patterns)
- [Pitfalls](#pitfalls)
- [By runtime](#runtimes)

<a id="order"></a>

## Why key order is time order

```
snowflake = ts(41) << 22 | node(10) << 12 | seq(12)        epoch 2024-01-01T00:00:00Z
```

- Two snowflakes from **different milliseconds** compare by time.
- Within **one millisecond** they compare by node, then sequence.
- One generator is **strictly increasing** under every clock regime: its cell advances to
  `max(now, last + 1)`.
- Across nodes, order holds **to the millisecond**. Two nodes minting in the same millisecond
  order by node number, not by which came first.

The encoded id keeps that order byte for byte within a namespace (contract vector V-7), so an
ordered store keyed by the id string, such as a database index or an `:ets` `ordered_set`, sees
the same order.

<a id="operations"></a>

## Operations

| Operation | Meaning | Cost |
|---|---|---|
| `put`, `fetch`, `delete` | point operations by id | O(log n) per namespace |
| `first(ns)`, `last(ns)` | the oldest and newest entry | O(log n) |
| `page_after(ns, cursor, n)` | up to `n` entries **strictly after** the cursor's snowflake, ascending; `nil` starts at the beginning | O(log n + n) |
| `between(ns, from, until)` | entries with `min_for(from) ≤ snowflake < min_for(until)`: a half-open window | O(log n + k) |
| `to_list(ns)` | the namespace, ascending | O(n) |

`min_for(t)` is the smallest snowflake of instant `t`: `(t − epoch) << 22`. It is a **synthetic
cursor**, so "everything since 14:00" needs no stored id.

<a id="patterns"></a>

## Patterns

**A paged API.** Return the last id of a page as the `next` cursor; the client sends it back.
The id is opaque-looking, URL-safe, and exact.

```elixir
page = EchoData.BrandedTree.page_after(feed, "ORD", params["after"], 50)
next = case List.last(page) do {id, _} -> id; nil -> nil end
```

**A LiveView feed.** Keep the tree in the socket's assigns. A new entry is a `put`, the newest
fifty are `between(ns, now - window, now)`, and "load older" is `page_after` on the oldest id
shown.

**A time window count.** `between` over a day gives that day's entries. For counts alone over
a frozen set, `EchoData.FrozenIndex.range_count/3` answers with two binary searches.

<a id="pitfalls"></a>

## Pitfalls

- **Clock skew between nodes.** An id minted on a node whose clock runs ahead sorts after ids
  that were minted later elsewhere. Pages stay consistent, since a cursor never skips, but
  "newest" means the largest timestamp, not the latest event.
- **A cursor from another namespace.** `page_after` uses the cursor's snowflake whatever its
  namespace. That is useful (a shared time cursor across namespaces) but surprising if you
  expected an error.
- **Order across namespaces.** The tree orders within a namespace. Across namespaces, merge the
  per-namespace pages by snowflake.
- **Generators that run ahead.** Above 4096 ids per millisecond per node, a generator borrows
  into the next millisecond's timestamps; `between` sees those ids slightly in the future.

<a id="runtimes"></a>

## By runtime

| Runtime | Implementation | Semantics |
|---|---|---|
| Elixir | `EchoData.BrandedTree`: one `:gb_trees` per namespace | persistent; `page_after` and `between` walk `:gb_trees.iterator_from/2` |
| Go | `go/brdata` `Tree[V]` | mutable with `Clone()`; ordered per namespace, O(log n) worst case, append path optimised |
| Rust | `brd14-data` `Tree<V>`: `BTreeMap<u64, V>` per namespace | mutable with `Clone()` |

Behaviour is proven per runtime against a sorted-list model, including both ends of the half-open
window. The Elixir property suite catches four planted mutants, among them "between closed at the
top" — see [proof.md](proof.md#mutants).

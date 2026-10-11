---
id: "KAN0R9YJT08aIt"
slug: "DOCS-STRUCTURES-BUCKETS"
type: "guide"
version: "1.3"
path: "docs/structures/buckets.md"
title: "The buckets: expiry without visiting an entry"
summary: "Generational expiry from the id's own time: bucket arithmetic, what expiry keeps, and the namespace caveat."
tags: ["buckets", "ttl", "expiry"]
group: "structures"
language: "en"
audience: ["developer", "agent"]
---

# The buckets: expiry without visiting an entry

`Buckets` groups entries by the time their id was minted, read straight from the id:
`bucket = snowflake >> (22 + bits)`. Expiry drops whole buckets. It costs O(number of buckets)
and touches no entry, so per-entry TTL bookkeeping becomes a structural operation.

[Index](../index.md#toc) · [Structures](README.md#toc) · [Spec](spec.md#toc) · [Champ](champ.md#toc) · [Tree](tree.md#toc) · [Layout profiles](layout-profiles.md#toc) · [Proof](proof.md#toc)

<a id="toc"></a>

## In this document

- [The arithmetic](#arithmetic)
- [What expire_older_than(t) removes](#expiry)
- [Keyed by snowflake alone](#caveat)
- [Patterns](#patterns)
- [By runtime](#runtimes)

<a id="arithmetic"></a>

## The arithmetic

A snowflake's top 41 bits are milliseconds since the epoch. Shifting away the 22 low bits leaves
the millisecond; shifting `bits` more groups `2^bits` milliseconds into one bucket.

| `bucket_bits` | Bucket span (*formula*: 2^bits ms) | Typical use |
|---:|---|---|
| 10 | 1.024 s | rate-limit windows |
| 12 | 4.096 s (the Elixir default) | presence, short-lived tokens |
| 16 | 65.5 s | sessions with minute-level expiry |
| 20 | 17.5 min | ephemeral caches |
| 24 | 4.66 h | daily retention jobs |

`fetch` is two hops, the bucket and then the entry. The bucket is computed from the key, never
searched for.

<a id="expiry"></a>

## What `expire_older_than(t)` removes

It drops every bucket whose key is below `min_for(t) >> (22 + bits)`: the buckets that **end at
or before** the start of the bucket containing `t`. It returns the number of entries dropped.

```
time ─────────────────────────────────────────────────────────────►
       [bucket k-2 ][bucket k-1 ][  bucket k   ][bucket k+1 ]
                                      ▲ t
       ◄──── dropped ────────────►◄── kept, even the part before t ──►
```

Entries in the cutoff's own bucket survive even when they are older than `t`. Expiry is
**bucket-granular**, so choose `bucket_bits` so that one bucket of overshoot is acceptable. A
bucket of 4 s on a 15-minute session TTL keeps a session at most about 4 s longer.

<a id="caveat"></a>

## Keyed by snowflake alone

`put(b, id, v)` checks the id, **then drops the namespace**: entries are keyed by snowflake. Two
ids with the same snowflake in different namespaces collide in one `Buckets`. Within one generator
that cannot happen, because every mint is a new snowflake. When ids from several generators meet,
use one `Buckets` per namespace.

<a id="patterns"></a>

## Patterns

- **Sessions.** Key sessions by their `SES` id. Run `expire_older_than(now − ttl)` on a timer;
  the result is the number of sessions ended.
- **Rate limiting.** Use one bucket per window; the count of a bucket is the requests in that
  window.
- **An ephemeral cache.** Put on write, expire on a timer; no entry carries a timestamp.

<a id="runtimes"></a>

## By runtime

| Runtime | Implementation | Semantics |
|---|---|---|
| Elixir | `EchoData.Buckets`: `%{bucket => %{snowflake => value}}` | persistent; `expire_older_than/2` returns `{count, buckets}` |
| Go | `go/brdata` `Buckets[V]` | mutable with `Clone()`; `ExpireOlderThan(t) int` |
| Rust | `brd14-data` `Buckets<V>` | mutable with `Clone()`; `expire_older_than(unix_ms) -> usize` |

The expiry boundary is proven against a filter-by-bucket model in each runtime. The Elixir suite
catches a planted `<=` in place of `<` — see [proof.md](proof.md#mutants).

---
id: "KAN0R9YJT08aIu"
slug: "DOCS-STRUCTURES-LAYOUT-PROFILES"
type: "guide"
version: "1.3"
path: "docs/structures/layout-profiles.md"
title: "Layout profiles: metadata inside the id"
summary: "Metadata inside a valid brd14 id: the bit layout, why meta is lowest, choosing a profile, binding it to a namespace."
tags: ["layout-profiles", "metadata"]
group: "structures"
language: "en"
audience: ["developer", "agent"]
---

# Layout profiles: metadata inside the id

A layout profile `(n, s, m)` re-splits the 22 bits under the timestamp into node, sequence and
**metadata**, so a few bits of meaning (audit flags, a tenant shard, a record class) travel inside
a valid 14-byte brd14 id. The codec, the order and the range are unchanged. The normative
definition is the contract's [Extensions section](../contract.md#layout-profiles).

[Index](../index.md#toc) · [Structures](README.md#toc) · [Spec](spec.md#toc) · [Champ](champ.md#toc) · [Tree](tree.md#toc) · [Buckets](buckets.md#toc) · [Proof](proof.md#toc)

<a id="toc"></a>

## In this document

- [The bits](#bits)
- [Why meta sits lowest](#why-lowest)
- [Binding a profile to a namespace](#binding)
- [Refusals](#refusals)
- [By runtime](#runtimes)

<a id="bits"></a>

## The bits

```
bit 63   62 ........ 22   21 ....... s+m   s+m-1 ..... m   m-1 ..... 0
  0      ts (41 bits)     node (n bits)    seq (s bits)    meta (m bits)
```

- **Valid profile:** `0 ≤ n, s, m ≤ 22` and `n + s + m = 22`; there are 276 profiles.
- **`std` = (10, 12, 0) is the base layout**, bit for bit, so every existing id reads the same
  under it.
- **The profile is not in the id.** A reader must know the namespace's profile to split out
  `meta`; under any other profile it reads as part of the sequence.

| Profile | n · s · m | Fleet × throughput (*formula*: 2ⁿ nodes × 2ˢ ids/ms) | Meta values |
|---|---|---|---:|
| `std` | 10 · 12 · 0 | 1024 × 4096 | 1 |
| audit flags | 6 · 12 · 4 | 64 × 4096 | 16 |
| tenant shard | 8 · 10 · 4 | 256 × 1024 | 16 |
| record class | 8 · 12 · 2 | 256 × 4096 | 4 |

Every bit of meta halves the fleet or the per-millisecond throughput. Choose `m` for what must
travel with the id, not for what a database column could hold.

<a id="why-lowest"></a>

## Why meta sits lowest

A generator's cell is `ts << s | seq`, advanced to `max(now, last + 1)`. Each mint packs
`(cell >> s, node, cell & (2^s − 1), meta)`.

Take two mints with cells `c₁ < c₂`:
- **different timestamps:** the snowflakes order by time;
- **the same timestamp:** `seq₁ < seq₂`, so `seq₁·2^m + meta₁ < (seq₁ + 1)·2^m ≤ seq₂·2^m`
  whatever the metas are.

**One generator stays strictly increasing whatever metadata each id carries.** With meta above
the sequence instead, an id minted later in the same millisecond with a smaller meta would sort
first, breaking cursors, commit order and newer-wins coherence. The oracle's self-test mints
20 000 ids under (6, 12, 4) with random meta through a stalled clock and checks the order; Go,
Rust and Elixir repeat that test. This is SDMR card 1 of the
[KAN story](../kan/brd14-pragmatic-guide.md#sdmr).

<a id="binding"></a>

## Binding a profile to a namespace

The namespace is the type, so the namespace is where the profile is declared.
- **Bind it where the namespace policy already lives:** the Go `Gate`, Elixir's
  `EchoData.Namespace` census, the CLI's `census` setting.
- **Treat it like the census: additive and never rewritten.** Once ids of a namespace exist,
  changing its profile changes what their bits mean.

```go
var ord = brd14.MustLayout(6, 12, 4)                 // ORD carries 4 audit flags
gen, _ := brd14.NewLayoutGenerator(ord, node)
snow, _ := gen.Next(flagDeleted)
_, _, _, meta := ord.Fields(snow)                     // meta == flagDeleted
```

```elixir
{:ok, ord} = EchoData.Layout.new(6, 12, 4)
{:ok, gen} = EchoData.Layout.generator(ord, node)
{:ok, snow} = EchoData.Layout.next(gen, flag_deleted)
{:ok, {_ts, _node, _seq, ^flag_deleted}} = EchoData.Layout.fields(ord, snow)
```

<a id="refusals"></a>

## Refusals

| Situation | Class |
|---|---|
| widths outside 0..22, or not summing to 22 | `LAYOUT` (checked first) |
| `fields` of a value at or above 2⁶³ | `RANGE` |
| `pack` with `ts ≥ 2⁴¹`, `node ≥ 2ⁿ`, `seq ≥ 2ˢ` or `meta ≥ 2ᵐ` | `RANGE` |
| a generator's `node` or `meta` too wide | `RANGE` |

<a id="runtimes"></a>

## By runtime

| Runtime | API | Parity |
|---|---|---|
| Elixir | `EchoData.Layout`: `new/3`, `fields/2`, `pack/5`, `generator/3`, `next/2` | shim `ex-pure` advertises `L P` |
| Go | `brd14.Layout`: `NewLayout`, `MustLayout`, `Fields`, `Pack`; `NewLayoutGenerator(...).Next(meta)` | shim `go` (R3) |
| Rust | `brd14::layout`: `Layout::new`, `fields`, `pack`; a profiled generator | shims `rust-*` (R3) |

C, Python, TypeScript, WebAssembly and bash are **deferred**: their shims do not advertise `L P`,
and the parity run sends them none.

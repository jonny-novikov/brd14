# EchoData

Branded identity and the structures built on it, for the BEAM. This is the standalone,
redistributable home of `echo_data` (imported from the fiberfx `echo` umbrella, where it is the
pure base of the BCS data-layer stack). It has no runtime dependencies, runs on Elixir ≥ 1.14 /
OTP ≥ 25, and is proven against the same oracle as every other brd14 implementation.

```
USR0KHTOWnGLuC
└┬┘└─────┬────┘
 │       └─ 11 chars of Base62 over a ts(41)|node(10)|seq(12) snowflake, epoch 2024-01-01Z
 └───────── a 3-letter uppercase namespace — the brand IS the type
```

## What is in the box

| Module | What it gives you |
|---|---|
| `EchoData.BrandedId` | The codec and the hash: `parse/1`, `encode/2`, `hash32/1`, `self_check!/0`, the `~b` sigil |
| `EchoData.Snowflake` | Lock-free `:atomics` generator, `min_for/1` range cursors |
| `EchoData.Namespace` | The namespace census: platform (3 letters) vs developer space (4 letters) |
| `EchoData.BrandedMap` | The default map: one native HAMT per namespace |
| `EchoData.BrandedChamp` | A persistent CHAMP forest, placed by the contract `hash32` |
| `EchoData.BrandedTree` | Creation-ordered map (`:gb_trees` per namespace): first/last, cursors, time windows |
| `EchoData.Buckets` | Generational TTL store: expiry drops whole time buckets |
| `EchoData.FrozenIndex`, `Timeline`, `Edges` | Immutable sorted index, `:ets` feeds, relations |
| `EchoData.Bcs.*` | The BCS systems: property and edge stores, archetypes, projections |
| `EchoData.Native` | Optional NIF; every call falls back to pure Elixir when it is absent |

## Use

```elixir
# mix.exs — from this repository
{:echo_data, path: "../brd14/ex/echo_data"}
```

```elixir
id = EchoData.Snowflake.next_branded("ORD")       # "ORD0R9…"
{:ok, "ORD", snow} = EchoData.BrandedId.parse(id)

feed =
  EchoData.BrandedTree.new()
  |> EchoData.BrandedTree.put(id, %{total: 42})

EchoData.BrandedTree.page_after(feed, "ORD", nil, 20)  # creation order, no sort
```

## Develop

```bash
cd ex/echo_data
TMPDIR=/tmp mix deps.get
TMPDIR=/tmp mix compile --warnings-as-errors
TMPDIR=/tmp mix test
```

`make -C ex test` runs the same from the repository root; `make -C ex conform` is the parity
shim (see [docs/elixir.md](../../docs/elixir.md)).

## License

MIT

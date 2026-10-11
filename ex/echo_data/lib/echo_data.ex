defmodule EchoData do
  @moduledoc """
  Branded-id primitives, structures, and the optional native codec for the BCS stack.

  The core contract — one module owning the codec and the hash:

    * `EchoData.Snowflake` — lock-free `:atomics`-CAS, time-ordered 64-bit ids
      (timestamp · node · sequence), epoch 2024-01-01.
    * `EchoData.BrandedId` — the codec+hash contract (3-letter namespace ++
      `base62(snowflake)`, 14 bytes), single-source `hash32/1`, the boot
      `self_check!/0`, and the compile-time `~b` sigil (`EchoData.BrandedId.Sigil`).
    * `EchoData.Base62` — the wire-compatible `0-9A-Za-z`, width-11 codec.
    * `EchoData.Native` — the optional Rust+C NIF; a pure-Elixir fallback serves
      every call when the shared object is absent.

  The branded structures over that contract:

    * `EchoData.BrandedChamp` / `EchoData.ChampNode` — a persistent CHAMP forest,
      one trie per namespace, the hash routed through `BrandedId.hash32`.
    * `EchoData.BrandedMap` — a persistent map over the BEAM's native HAMTs.
    * `EchoData.BrandedTree` — an ordered (creation-order) map over `:gb_trees`.
    * `EchoData.FrozenIndex` — an immutable membership-and-range index.
    * `EchoData.Timeline` / `EchoData.Edges` — `:ets` `ordered_set` feeds + hierarchies.
    * `EchoData.Buckets` — a generational TTL store keyed by the id's own time.
    * `EchoData.Web` — dependency-free DOM-id helpers.
    * `EchoData.ChampServer` — a GenServer wrapper over `BrandedChamp`.

  Consuming apps wrap this core to mint and decode the 3-letter-namespaced
  branded ids their domain uses — e.g. `EchoData.BrandedId.generate!("JOB")`
  in `:codemojex`.
  """
end

defmodule EchoData.ChampView do
  @moduledoc """
  CHAMP feature: rebuild an in-heap `BrandedChamp` view from the durable Graft commit log.

  `BrandedChamp` and `EchoData.ChampServer` already give a complete persistent map and a
  GenServer around it. What was missing is the *derivation* — the rule from the layered-store
  design that CHAMP is an L0 memory tier whose contents are **rebuildable from L2 (Graft)**,
  never a separate source of truth. This module is that rule as code:

    * `rebuild_view/1` folds a stream of decoded component entries into a fresh `BrandedChamp`.
    * `from_volume/4` reads a Graft Volume's pages at a snapshot, decodes each into a
      `{branded_id, value}`, and builds the view — the "fold the commit stream into a view" step.
    * `rebuild_server/4` swaps a `ChampServer`'s whole map atomically via its existing
      `replace/2`, so a decider/trading view can be re-derived after a crash with no bespoke
      recovery path.

  Two seams keep this module pure and **inside the base layer** — `echo_data` names no store:

    * The **decoder** is injected, because how a page's bytes become a `{branded_id, term}` is the
      caller's component contract (Codemoji stores `:erlang.term_to_binary/1` values keyed by a
      `PLR`/`SEC`/`GSS` id; another domain may differ). Decoding to `:skip` drops a page that is
      not a component (tombstones, intent edges).
    * The **source** is injected — an `EchoData.ChampView.Source` module that supplies the
      snapshot and the page reads. `echo_store` (the layer that owns Graft) implements it, and
      this module calls it through the handed-in module, so the dependency runs top→base rather
      than `echo_data` reaching up into `echo_store`.
  """

  alias EchoData.BrandedChamp

  @type entry :: {EchoData.BrandedId.t(), term()}
  @type decoder :: (page_idx :: non_neg_integer(), bytes :: binary() -> {:ok, entry()} | :skip)

  @doc """
  Fold an enumerable of `{:ok, {id, value}} | :skip` results into a `BrandedChamp`.
  Pure: no process, no IO — the same input always yields the same view.
  """
  @spec rebuild_view(Enumerable.t()) :: BrandedChamp.t()
  def rebuild_view(decoded) do
    Enum.reduce(decoded, BrandedChamp.new(), fn
      {:ok, {id, value}}, champ -> BrandedChamp.put(champ, id, value)
      :skip, champ -> champ
    end)
  end

  @doc """
  Build a `BrandedChamp` view of a Graft Volume, reading pages through `source` (an
  `EchoData.ChampView.Source` implementation) and decoding each live page with `decoder`. The
  snapshot defaults to the source's head (`opts[:snapshot]` pins a point-in-time projection of
  the durable log). `echo_data` names no store; the Graft access arrives via `source`.
  """
  @spec from_volume(EchoData.BrandedId.t(), module(), decoder(), keyword()) :: BrandedChamp.t()
  def from_volume(volume_id, source, decoder, opts \\ [])
      when is_atom(source) and is_function(decoder, 2) do
    snap = Keyword.get_lazy(opts, :snapshot, fn -> source.snapshot(volume_id) end)

    snap
    |> snapshot_pages()
    |> Stream.map(fn idx ->
      case source.read_at(volume_id, snap, idx) do
        {:ok, bytes} -> decoder.(idx, bytes)
        :absent -> :skip
      end
    end)
    |> rebuild_view()
  end

  @doc """
  Re-derive a `ChampServer`'s entire map from a Graft Volume (via `source`) and install it
  atomically. Returns `{:ok, size}`. This is recovery for the L0 tier: replay the durable log
  into a fresh view and swap it in, rather than mutating in place.
  """
  @spec rebuild_server(GenServer.server(), EchoData.BrandedId.t(), module(), decoder()) ::
          {:ok, non_neg_integer()}
  def rebuild_server(server, volume_id, source, decoder)
      when is_atom(source) and is_function(decoder, 2) do
    champ = from_volume(volume_id, source, decoder)
    :ok = EchoData.ChampServer.replace(server, champ)
    {:ok, BrandedChamp.size(champ)}
  end

  # --- helpers ---------------------------------------------------------------

  # A snapshot's `index` maps page_idx => {lsn, segment_id}; its keys are the live pages.
  defp snapshot_pages(%{index: index}) when is_map(index), do: Map.keys(index)
  defp snapshot_pages(_), do: []
end

defmodule EchoData.ChampView.Source do
  @moduledoc """
  The durable-page source `EchoData.ChampView` reads through — the dependency-inversion seam that
  lets `echo_data` (the pure base layer) rebuild a CHAMP view from Graft **without naming
  `echo_store`** (the layer that owns Graft). The store provides a module implementing these two
  callbacks; `ChampView` is handed that module and calls it, so the dependency runs top→base.

  An `echo_store` implementation delegates to `EchoStore.Graft.VolumeServer.snapshot/1` and
  `EchoStore.Graft.read_at/3`.
  """

  @doc "The current (or a pinned) snapshot of `volume_id`; its `:index` keys are the live pages."
  @callback snapshot(volume_id :: EchoData.BrandedId.t()) :: map()

  @doc """
  Read one page at `snapshot`: `{:ok, bytes}` for a live page, `:absent` for a hole — resolved
  lock-free at the snapshot's LSN, faulting from the remote on a local miss.
  """
  @callback read_at(
              volume_id :: EchoData.BrandedId.t(),
              snapshot :: map(),
              page_idx :: non_neg_integer()
            ) :: {:ok, binary()} | :absent
end

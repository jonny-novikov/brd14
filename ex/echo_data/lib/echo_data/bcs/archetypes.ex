defmodule EchoData.Bcs.Archetypes do
  @moduledoc """
  Archetypes are data: an archetype is an entity (`ARC` namespace) whose
  value is a property bundle, optionally extending one parent via `:extends`.
  An instrument carries its archetype's id plus an overrides map, and the
  composed view is computed at read time as a fold -- base bundle first,
  each descendant after, the instrument's overrides last. No behaviour
  modules, no hierarchy of code, one `:extends` at most per bundle.
  Pure core: the resolver takes a fetch function, so the boundary stays
  wherever the definitions live -- a store call or a snapshot walk.
  Chapter 2.4.
  """

  @max_depth 8

  @doc "Right-most wins: later bundles override earlier ones, overrides win last."
  @spec compose([map()], map()) :: map()
  def compose(chain, overrides) when is_list(chain) and is_map(overrides) do
    chain
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
    |> Map.merge(overrides)
    |> Map.delete(:extends)
  end

  @doc """
  Resolves a composed view: walks the `:extends` chain root-first through
  the given fetch function, then applies the instrument's overrides.
  `fetch.(id)` must return `{:ok, props}` or `{:error, reason}`.
  """
  @spec resolve((binary() -> {:ok, map()} | {:error, term()}), binary(), map()) ::
          {:ok, map()} | {:error, term()}
  def resolve(fetch, arc_id, overrides \\ %{}) when is_function(fetch, 1) do
    with {:ok, chain} <- walk(fetch, arc_id, [], MapSet.new()) do
      {:ok, compose(chain, overrides)}
    end
  end

  defp walk(_fetch, _id, acc, _seen) when length(acc) >= @max_depth, do: {:error, :depth}

  defp walk(fetch, id, acc, seen) do
    if MapSet.member?(seen, id) do
      {:error, :cycle}
    else
      case fetch.(id) do
        {:ok, props} ->
          case Map.fetch(props, :extends) do
            {:ok, parent} -> walk(fetch, parent, [props | acc], MapSet.put(seen, id))
            :error -> {:ok, [props | acc]}
          end

        {:error, _} = err ->
          err
      end
    end
  end
end

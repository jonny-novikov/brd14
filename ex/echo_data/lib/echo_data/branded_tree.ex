defmodule EchoData.BrandedTree do
  @moduledoc """
  An ordered branded map: a `:gb_trees` general balanced tree per namespace.
  Persistent (plain functional data), O(log n) point operations — and unlike
  the hash-placed `BrandedMap`/`BrandedChamp`, iteration order is key order,
  which for snowflakes means creation order. The structure to hold *in a
  process* when order is part of the state: a LiveView assign carrying a feed,
  the newest/oldest entity, the page after a cursor — each is `iterator_from/2`
  plus a bounded take, never a sort.
  """

  alias EchoData.BrandedId

  defstruct namespaces: %{}, size: 0

  def new, do: %__MODULE__{}

  def put(%__MODULE__{} = t, id, value) when is_binary(id) do
    case BrandedId.parse(id) do
      {:ok, ns, snow} -> put_by_snowflake(t, ns, snow, value)
      :error -> raise ArgumentError, "invalid branded id: #{inspect(id)}"
    end
  end

  def put_by_snowflake(%__MODULE__{namespaces: nss, size: size} = t, ns, snow, value) do
    tree = Map.get_lazy(nss, ns, fn -> :gb_trees.empty() end)
    delta = if :gb_trees.is_defined(snow, tree), do: 0, else: 1

    %__MODULE__{
      t
      | namespaces: Map.put(nss, ns, :gb_trees.enter(snow, value, tree)),
        size: size + delta
    }
  end

  def fetch(%__MODULE__{namespaces: nss}, id) when is_binary(id) do
    with {:ok, ns, snow} <- BrandedId.parse(id),
         %{^ns => tree} <- nss,
         {:value, value} <- :gb_trees.lookup(snow, tree) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  def delete(%__MODULE__{namespaces: nss, size: size} = t, id) when is_binary(id) do
    with {:ok, ns, snow} <- BrandedId.parse(id),
         %{^ns => tree} <- nss,
         true <- :gb_trees.is_defined(snow, tree) do
      tree = :gb_trees.delete(snow, tree)
      nss = if :gb_trees.is_empty(tree), do: Map.delete(nss, ns), else: Map.put(nss, ns, tree)
      %__MODULE__{t | namespaces: nss, size: size - 1}
    else
      _ -> t
    end
  end

  @doc "Oldest entry in the namespace — `gb_trees:smallest/1`."
  def first(%__MODULE__{namespaces: nss}, ns) do
    case nss do
      %{^ns => tree} ->
        {snow, value} = :gb_trees.smallest(tree)
        {:ok, BrandedId.encode!(ns, snow), value}

      _ ->
        :error
    end
  end

  @doc "Newest entry in the namespace — `gb_trees:largest/1`."
  def last(%__MODULE__{namespaces: nss}, ns) do
    case nss do
      %{^ns => tree} ->
        {snow, value} = :gb_trees.largest(tree)
        {:ok, BrandedId.encode!(ns, snow), value}

      _ ->
        :error
    end
  end

  @doc "Up to `n` entries strictly after the cursor, in creation order."
  def page_after(%__MODULE__{namespaces: nss}, ns, cursor, n) when n > 0 do
    from =
      case cursor do
        nil -> 0
        id when is_binary(id) -> BrandedId.decode!(id) + 1
      end

    case nss do
      %{^ns => tree} -> from |> :gb_trees.iterator_from(tree) |> take(n, ns, [])
      _ -> []
    end
  end

  @doc "Entries minted in `[from, until)`, in creation order."
  def between(%__MODULE__{namespaces: nss}, ns, %DateTime{} = from, %DateTime{} = until) do
    lo = EchoData.Snowflake.min_for(from)
    hi = EchoData.Snowflake.min_for(until)

    case nss do
      %{^ns => tree} -> lo |> :gb_trees.iterator_from(tree) |> take_while_below(hi, ns, [])
      _ -> []
    end
  end

  @doc "Whole namespace in creation order — `gb_trees:to_list/1` is already sorted."
  def to_list(%__MODULE__{namespaces: nss}, ns) do
    case nss do
      %{^ns => tree} ->
        for {snow, v} <- :gb_trees.to_list(tree), do: {BrandedId.encode!(ns, snow), v}

      _ ->
        []
    end
  end

  def size(%__MODULE__{size: size}), do: size

  defp take(_iter, 0, _ns, acc), do: :lists.reverse(acc)

  defp take(iter, n, ns, acc) do
    case :gb_trees.next(iter) do
      {snow, value, rest} -> take(rest, n - 1, ns, [{BrandedId.encode!(ns, snow), value} | acc])
      :none -> :lists.reverse(acc)
    end
  end

  defp take_while_below(iter, hi, ns, acc) do
    case :gb_trees.next(iter) do
      {snow, value, rest} when snow < hi ->
        take_while_below(rest, hi, ns, [{BrandedId.encode!(ns, snow), value} | acc])

      _ ->
        :lists.reverse(acc)
    end
  end
end

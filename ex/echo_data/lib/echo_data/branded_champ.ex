defmodule EchoData.BrandedChamp do
  @moduledoc """
  Persistent branded-ID map over a CHAMP forest: one trie per namespace,
  snowflake-keyed, dispatched on the 3-byte prefix. Final form, audit applied.

  When to choose this over `EchoData.BrandedMap`: choose `BrandedMap` by
  default — it rides the BEAM's native HAMTs and wins the general matrix.
  `BrandedChamp` is the structure to reach for when the **in-trie placement
  itself is part of a contract** (the same `hash32` positions keys here, in
  the native tables, and in any Go or Node consumer), or when you need to
  instrument, persist, or mirror the tree shape across runtimes.

  Boundary behavior is loud, per the gate doctrine: `put!/3` and `delete/2`
  raise on an invalid branded ID; `fetch/2` returns `:error` for both invalid
  and absent, and `parse`-level failures are distinguishable via
  `EchoData.BrandedId.parse/1`.

      iex> champ = EchoData.BrandedChamp.new()
      iex> champ = EchoData.BrandedChamp.put!(champ, "USR0KHTOWnGLuC", %{name: "Alice"})
      iex> EchoData.BrandedChamp.fetch(champ, "USR0KHTOWnGLuC")
      {:ok, %{name: "Alice"}}
      iex> EchoData.BrandedChamp.fetch_by_snowflake(champ, "USR", 274557032793636864)
      {:ok, %{name: "Alice"}}
      iex> EchoData.BrandedChamp.size(champ)
      1
  """

  alias EchoData.{BrandedId, ChampNode}

  import EchoData.BrandedId, only: [is_branded: 1]

  @type t :: %__MODULE__{
          namespaces: %{optional(binary()) => ChampNode.t()},
          namespace_sizes: %{optional(binary()) => non_neg_integer()},
          size: non_neg_integer()
        }

  defstruct namespaces: %{}, namespace_sizes: %{}, size: 0

  @behaviour Access

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new([{BrandedId.t(), any()}]) :: t()
  def new(entries) when is_list(entries) do
    Enum.reduce(entries, new(), fn {id, value}, acc -> put!(acc, id, value) end)
  end

  # ---- reads -------------------------------------------------------------------

  @impl Access
  @spec fetch(t(), BrandedId.t()) :: {:ok, any()} | :error
  def fetch(%__MODULE__{namespaces: namespaces}, id) when is_branded(id) do
    case BrandedId.parse_hash(id) do
      {:ok, ns, snow, hash} ->
        case namespaces do
          %{^ns => node} -> ChampNode.fetch(node, snow, hash, 0)
          _ -> :error
        end

      :error ->
        :error
    end
  end

  def fetch(_champ, _id), do: :error

  def get(champ, id, default \\ nil) do
    case fetch(champ, id) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @spec fetch_by_snowflake(t(), binary(), non_neg_integer()) :: {:ok, any()} | :error
  def fetch_by_snowflake(%__MODULE__{namespaces: namespaces}, ns, snow)
      when is_binary(ns) and byte_size(ns) == 3 and is_integer(snow) and snow >= 0 do
    case namespaces do
      %{^ns => node} -> ChampNode.fetch(node, snow, BrandedId.hash32(snow), 0)
      _ -> :error
    end
  end

  def has_key?(champ, id), do: fetch(champ, id) != :error

  # ---- writes (loud at the boundary) ---------------------------------------------

  @doc "Inserts or updates. Raises `ArgumentError` on an invalid branded ID."
  @spec put!(t(), BrandedId.t(), any()) :: t()
  def put!(champ, id, value) do
    case BrandedId.parse_hash(id) do
      {:ok, ns, snow, hash} -> do_put(champ, ns, snow, hash, value)
      :error -> raise ArgumentError, "invalid branded id: #{inspect(id)}"
    end
  end

  @doc """
  Inserts or updates, delegating to `put!/3` (loud at the boundary). Provided for
  surface-parity with `BrandedMap`/`BrandedTree`/`Buckets`, whose `put/3` is the
  same insert-or-update over a branded id.
  """
  @spec put(t(), BrandedId.t(), any()) :: t()
  def put(champ, id, value), do: put!(champ, id, value)

  @spec put_by_snowflake(t(), binary(), non_neg_integer(), any()) :: t()
  def put_by_snowflake(champ, ns, snow, value)
      when is_binary(ns) and byte_size(ns) == 3 and is_integer(snow) and snow >= 0 do
    do_put(champ, ns, snow, BrandedId.hash32(snow), value)
  end

  defp do_put(
         %__MODULE__{namespaces: namespaces, namespace_sizes: sizes, size: size} = champ,
         ns,
         snow,
         hash,
         value
       ) do
    {node, delta} =
      case namespaces do
        %{^ns => node} ->
          delta = if ChampNode.fetch(node, snow, hash, 0) == :error, do: 1, else: 0
          {ChampNode.put(node, snow, value, hash, 0), delta}

        _ ->
          {ChampNode.singleton(snow, value, hash, 0), 1}
      end

    %__MODULE__{
      champ
      | namespaces: Map.put(namespaces, ns, node),
        namespace_sizes: Map.update(sizes, ns, delta, &(&1 + delta)),
        size: size + delta
    }
  end

  @doc "Deletes. Raises `ArgumentError` on an invalid branded ID; absent key is a no-op."
  @spec delete(t(), BrandedId.t()) :: t()
  def delete(champ, id) do
    case BrandedId.parse_hash(id) do
      {:ok, ns, snow, hash} -> do_delete(champ, ns, snow, hash)
      :error -> raise ArgumentError, "invalid branded id: #{inspect(id)}"
    end
  end

  def delete_by_snowflake(champ, ns, snow)
      when is_binary(ns) and byte_size(ns) == 3 and is_integer(snow) and snow >= 0 do
    do_delete(champ, ns, snow, BrandedId.hash32(snow))
  end

  defp do_delete(
         %__MODULE__{namespaces: namespaces, namespace_sizes: sizes, size: size} = champ,
         ns,
         snow,
         hash
       ) do
    with %{^ns => node} <- namespaces,
         {:ok, _} <- ChampNode.fetch(node, snow, hash, 0) do
      new_node = ChampNode.delete(node, snow, hash, 0)
      ns_size = Map.fetch!(sizes, ns) - 1

      {namespaces, sizes} =
        if ns_size == 0 do
          {Map.delete(namespaces, ns), Map.delete(sizes, ns)}
        else
          {Map.put(namespaces, ns, new_node), Map.put(sizes, ns, ns_size)}
        end

      %__MODULE__{champ | namespaces: namespaces, namespace_sizes: sizes, size: size - 1}
    else
      _ -> champ
    end
  end

  def update(champ, id, default, fun) when is_function(fun, 1) do
    case fetch(champ, id) do
      {:ok, value} -> put!(champ, id, fun.(value))
      :error -> put!(champ, id, default)
    end
  end

  # ---- forest queries --------------------------------------------------------------

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  def empty?(%__MODULE__{size: 0}), do: true
  def empty?(_), do: false

  @doc "O(1): per-namespace counts are cached."
  def namespace_size(%__MODULE__{namespace_sizes: sizes}, ns) when byte_size(ns) == 3 do
    Map.get(sizes, ns, 0)
  end

  def namespaces(%__MODULE__{namespaces: namespaces}), do: Map.keys(namespaces)

  @spec get_namespace(t(), binary()) :: [{BrandedId.t(), any()}]
  def get_namespace(%__MODULE__{namespaces: namespaces}, ns) when byte_size(ns) == 3 do
    case namespaces do
      %{^ns => node} ->
        node
        |> ChampNode.reduce([], fn {snow, v}, acc -> [{BrandedId.encode!(ns, snow), v} | acc] end)
        |> :lists.reverse()

      _ ->
        []
    end
  end

  @spec to_list(t()) :: [{BrandedId.t(), any()}]
  def to_list(%__MODULE__{namespaces: namespaces}) do
    namespaces
    |> Enum.reduce([], fn {ns, node}, acc ->
      ChampNode.reduce(node, acc, fn {snow, v}, a -> [{BrandedId.encode!(ns, snow), v} | a] end)
    end)
    |> :lists.reverse()
  end

  @doc "Zero-codec traversal output: `{ns, snowflake, value}` triples."
  def to_snowflake_list(%__MODULE__{namespaces: namespaces}) do
    namespaces
    |> Enum.reduce([], fn {ns, node}, acc ->
      ChampNode.reduce(node, acc, fn {snow, v}, a -> [{ns, snow, v} | a] end)
    end)
    |> :lists.reverse()
  end

  def to_map(champ), do: Map.new(to_list(champ))
  def keys(champ), do: for({k, _} <- to_list(champ), do: k)
  def values(champ), do: champ |> to_snowflake_list() |> Enum.map(fn {_, _, v} -> v end)

  def merge(champ1, %__MODULE__{} = champ2) do
    champ2
    |> to_snowflake_list()
    |> Enum.reduce(champ1, fn {ns, snow, v}, acc -> put_by_snowflake(acc, ns, snow, v) end)
  end

  # ---- Access ------------------------------------------------------------------------

  @impl Access
  def get_and_update(champ, id, fun) do
    current = get(champ, id)

    case fun.(current) do
      {get_value, update_value} -> {get_value, put!(champ, id, update_value)}
      :pop -> {current, delete(champ, id)}
    end
  end

  @impl Access
  def pop(champ, id) do
    case fetch(champ, id) do
      {:ok, value} -> {value, delete(champ, id)}
      :error -> {nil, champ}
    end
  end
end

defimpl Enumerable, for: EchoData.BrandedChamp do
  # Streams {ns, snowflake, value} through the ChampNode iterator — no
  # intermediate list, full halt/suspend support.
  alias EchoData.{BrandedChamp, ChampNode}

  def count(champ), do: {:ok, BrandedChamp.size(champ)}

  def member?(champ, {ns, snow, value}) do
    case BrandedChamp.fetch_by_snowflake(champ, ns, snow) do
      {:ok, ^value} -> {:ok, true}
      _ -> {:ok, false}
    end
  end

  def member?(_champ, _), do: {:ok, false}

  def slice(_champ), do: {:error, __MODULE__}

  def reduce(%BrandedChamp{namespaces: namespaces}, acc, fun) do
    do_outer(Map.to_list(namespaces), nil, nil, acc, fun)
  end

  defp do_outer(_rest, _ns, _iter, {:halt, acc}, _fun), do: {:halted, acc}

  defp do_outer(rest, ns, iter, {:suspend, acc}, fun) do
    {:suspended, acc, &do_outer(rest, ns, iter, &1, fun)}
  end

  defp do_outer(rest, ns, iter, {:cont, acc}, fun) do
    case iter && ChampNode.next(iter) do
      {snow, v, iter2} ->
        do_outer(rest, ns, iter2, fun.({ns, snow, v}, acc), fun)

      _ ->
        case rest do
          [{next_ns, node} | more] ->
            do_outer(more, next_ns, ChampNode.iterator(node), {:cont, acc}, fun)

          [] ->
            {:done, acc}
        end
    end
  end
end

defimpl Collectable, for: EchoData.BrandedChamp do
  def into(champ) do
    {champ,
     fn
       acc, {:cont, {id, value}} -> EchoData.BrandedChamp.put!(acc, id, value)
       acc, :done -> acc
       _acc, :halt -> :ok
     end}
  end
end

defimpl Inspect, for: EchoData.BrandedChamp do
  import Inspect.Algebra

  def inspect(champ, opts) do
    concat([
      "#BrandedChamp<size: #{EchoData.BrandedChamp.size(champ)}, namespaces: ",
      to_doc(EchoData.BrandedChamp.namespaces(champ), opts),
      ">"
    ])
  end
end

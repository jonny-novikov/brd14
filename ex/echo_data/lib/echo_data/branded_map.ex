# branded_map.ex — persistent branded map over native HAMTs, NIF codec at the boundary.
#
# Value semantics throughout: every write returns a new %BrandedMap{}; existing
# references are never affected. Iteration streams through :maps.iterator with
# no intermediate list. The structure is plain Elixir data — it pattern-matches,
# inspects, serializes, and survives in any context a map does.

defmodule EchoData.BrandedMap do
  @moduledoc """
  A persistent branded-ID map: `%{namespace => %{snowflake => value}}` inside,
  branded strings at the API. Decode/encode/hash run in the native codec
  (`EchoData.BrandedId`, native when present); storage and structural sharing are the BEAM's own HAMTs.
  """

  alias __MODULE__, as: T

  @type t :: %T{
          namespaces: %{optional(binary()) => %{optional(non_neg_integer()) => any()}},
          size: non_neg_integer()
        }
  defstruct namespaces: %{}, size: 0

  @behaviour Access

  def new, do: %T{}

  def new(entries) when is_list(entries) do
    Enum.reduce(entries, new(), fn {id, v}, acc -> put(acc, id, v) end)
  end

  @impl Access
  def fetch(%T{namespaces: nss}, id) when is_binary(id) do
    case EchoData.BrandedId.parse(id) do
      {:ok, ns, snow} ->
        case nss do
          %{^ns => inner} -> Map.fetch(inner, snow)
          _ -> :error
        end

      :error ->
        :error
    end
  end

  def get(t, id, default \\ nil) do
    case fetch(t, id) do
      {:ok, v} -> v
      :error -> default
    end
  end

  def put(%T{namespaces: nss, size: size} = t, id, value) when is_binary(id) do
    case EchoData.BrandedId.parse(id) do
      {:ok, ns, snow} ->
        inner = Map.get(nss, ns, %{})
        delta = if is_map_key(inner, snow), do: 0, else: 1
        %T{t | namespaces: Map.put(nss, ns, Map.put(inner, snow, value)), size: size + delta}

      :error ->
        raise ArgumentError, "invalid branded id: #{inspect(id)}"
    end
  end

  def delete(%T{namespaces: nss, size: size} = t, id) when is_binary(id) do
    with {:ok, ns, snow} <- EchoData.BrandedId.parse(id),
         %{^ns => inner} <- nss,
         true <- is_map_key(inner, snow) do
      inner = Map.delete(inner, snow)
      nss = if map_size(inner) == 0, do: Map.delete(nss, ns), else: Map.put(nss, ns, inner)
      %T{t | namespaces: nss, size: size - 1}
    else
      _ -> t
    end
  end

  def has_key?(t, id), do: fetch(t, id) != :error

  def size(%T{size: size}), do: size

  def namespaces(%T{namespaces: nss}), do: Map.keys(nss)

  # O(1): the inner HAMT tracks its own size.
  def namespace_size(%T{namespaces: nss}, ns) do
    case nss do
      %{^ns => inner} -> map_size(inner)
      _ -> 0
    end
  end

  def fetch_by_snowflake(%T{namespaces: nss}, ns, snow) do
    case nss do
      %{^ns => inner} -> Map.fetch(inner, snow)
      _ -> :error
    end
  end

  def put_by_snowflake(%T{namespaces: nss, size: size} = t, ns, snow, value) do
    inner = Map.get(nss, ns, %{})
    delta = if is_map_key(inner, snow), do: 0, else: 1
    %T{t | namespaces: Map.put(nss, ns, Map.put(inner, snow, value)), size: size + delta}
  end

  def get_namespace(%T{namespaces: nss}, ns) do
    case nss do
      %{^ns => inner} ->
        for {snow, v} <- inner, do: {EchoData.BrandedId.encode!(ns, snow), v}

      _ ->
        []
    end
  end

  def to_list(%T{namespaces: nss}) do
    for {ns, inner} <- nss, {snow, v} <- inner do
      {EchoData.BrandedId.encode!(ns, snow), v}
    end
  end

  # Zero-codec variant for consumers that work in integers.
  def to_snowflake_list(%T{namespaces: nss}) do
    for {ns, inner} <- nss, {snow, v} <- inner, do: {ns, snow, v}
  end

  def to_map(t), do: Map.new(to_list(t))
  def keys(t), do: for({k, _} <- to_list(t), do: k)
  def values(%T{namespaces: nss}), do: for({_, inner} <- nss, {_, v} <- inner, do: v)

  def update(t, id, default, fun) when is_function(fun, 1) do
    case fetch(t, id) do
      {:ok, v} -> put(t, id, fun.(v))
      :error -> put(t, id, default)
    end
  end

  def merge(t1, %T{} = t2) do
    Enum.reduce(t2, t1, fn {ns, snow, v}, acc -> put_by_snowflake(acc, ns, snow, v) end)
  end

  @impl Access
  def get_and_update(t, id, fun) do
    current = get(t, id)

    case fun.(current) do
      {get_value, update_value} -> {get_value, put(t, id, update_value)}
      :pop -> {current, delete(t, id)}
    end
  end

  @impl Access
  def pop(t, id) do
    case fetch(t, id) do
      {:ok, v} -> {v, delete(t, id)}
      :error -> {nil, t}
    end
  end
end

defimpl Enumerable, for: EchoData.BrandedMap do
  # Streams {ns, snowflake, value} through :maps.iterator — no intermediate list.
  def count(t), do: {:ok, EchoData.BrandedMap.size(t)}

  def member?(t, {ns, snow, value}) do
    case EchoData.BrandedMap.fetch_by_snowflake(t, ns, snow) do
      {:ok, ^value} -> {:ok, true}
      _ -> {:ok, false}
    end
  end

  def member?(_t, _), do: {:ok, false}

  def slice(_t), do: {:error, __MODULE__}

  def reduce(%EchoData.BrandedMap{namespaces: nss}, acc, fun) do
    outer = :maps.iterator(nss)
    do_outer(:maps.next(outer), nil, nil, acc, fun)
  end

  # Walk namespaces; within one, walk its iterator.
  defp do_outer(_outer_next, _ns, _inner, {:halt, acc}, _fun), do: {:halted, acc}

  defp do_outer(outer_next, ns, inner, {:suspend, acc}, fun) do
    {:suspended, acc, &do_outer(outer_next, ns, inner, &1, fun)}
  end

  defp do_outer(outer_next, ns, inner, {:cont, acc}, fun) do
    case inner && :maps.next(inner) do
      {snow, v, rest} ->
        do_outer(outer_next, ns, rest, fun.({ns, snow, v}, acc), fun)

      _ ->
        case outer_next do
          {next_ns, inner_map, rest_outer} ->
            do_outer(
              :maps.next(rest_outer),
              next_ns,
              :maps.iterator(inner_map),
              {:cont, acc},
              fun
            )

          :none ->
            {:done, acc}
        end
    end
  end
end

defimpl Collectable, for: EchoData.BrandedMap do
  def into(t) do
    {t,
     fn
       acc, {:cont, {id, v}} -> EchoData.BrandedMap.put(acc, id, v)
       acc, :done -> acc
       _acc, :halt -> :ok
     end}
  end
end

defimpl Inspect, for: EchoData.BrandedMap do
  import Inspect.Algebra

  def inspect(t, opts) do
    concat([
      "#BrandedMap<size: #{EchoData.BrandedMap.size(t)}, namespaces: ",
      to_doc(EchoData.BrandedMap.namespaces(t), opts),
      ">"
    ])
  end
end

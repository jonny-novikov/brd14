defmodule EchoData.Edges do
  @moduledoc """
  A parent→children hierarchy over `:ets` `ordered_set` with composite keys
  `{parent_snowflake, child_snowflake}`. Erlang term order on tuples compares
  element-wise, so all children of a parent are contiguous and — because
  children are snowflakes — already in creation order. "First 20 modules of
  this course", "replies after this one": each is a bounded key walk from
  `{parent, cursor}`, no sort, no secondary index, no join table ordering
  column. The id pair IS the index.
  """

  alias EchoData.BrandedId

  defstruct [:tab, :parent_ns, :child_ns]

  def new(parent_ns, child_ns) do
    tab =
      :ets.new(:branded_edges, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    %__MODULE__{tab: tab, parent_ns: parent_ns, child_ns: child_ns}
  end

  def add(
        %__MODULE__{tab: tab, parent_ns: pns, child_ns: cns},
        parent_id,
        child_id,
        payload \\ nil
      ) do
    with {:ok, ^pns, p} <- BrandedId.parse(parent_id),
         {:ok, ^cns, c} <- BrandedId.parse(child_id) do
      :ets.insert(tab, {{p, c}, payload})
      :ok
    else
      _ ->
        raise ArgumentError, "expected #{pns}/#{cns} ids, got: #{inspect({parent_id, child_id})}"
    end
  end

  def add_by_snowflake(%__MODULE__{tab: tab}, p, c, payload \\ nil) do
    :ets.insert(tab, {{p, c}, payload})
    :ok
  end

  @doc "Up to `n` children in creation order, strictly after `cursor` (nil for the first page)."
  def children_page(%__MODULE__{tab: tab, parent_ns: pns, child_ns: cns}, parent_id, cursor, n)
      when n > 0 do
    {:ok, ^pns, p} = BrandedId.parse(parent_id)

    from =
      case cursor do
        nil -> {p, -1}
        id -> {p, BrandedId.decode!(id)}
      end

    walk(tab, :ets.next(tab, from), p, n, cns, [])
  end

  def count_children(%__MODULE__{tab: tab, parent_ns: pns}, parent_id) do
    {:ok, ^pns, p} = BrandedId.parse(parent_id)
    :ets.select_count(tab, [{{{p, :_}, :_}, [], [true]}])
  end

  def size(%__MODULE__{tab: tab}), do: :ets.info(tab, :size)

  defp walk(_tab, :"$end_of_table", _p, _n, _cns, acc), do: :lists.reverse(acc)
  defp walk(_tab, {p2, _}, p, _n, _cns, acc) when p2 != p, do: :lists.reverse(acc)
  defp walk(_tab, _key, _p, 0, _cns, acc), do: :lists.reverse(acc)

  defp walk(tab, {p, c} = key, p, n, cns, acc) when n > 0 do
    [{^key, payload}] = :ets.lookup(tab, key)
    walk(tab, :ets.next(tab, key), p, n - 1, cns, [{BrandedId.encode!(cns, c), payload} | acc])
  end
end

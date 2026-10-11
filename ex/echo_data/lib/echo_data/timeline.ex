defmodule EchoData.Timeline do
  @moduledoc """
  A time-ordered, concurrently writable feed over `:ets` `ordered_set`, keyed
  by raw snowflakes with the branded form at the edges. Because snowflakes are
  minted in time order, key order IS chronological order: latest-N, cursor
  pagination, and time-window counts are all range operations on the key —
  no timestamp column, no secondary index, no sort.

  The branded ID doubles as the public cursor token: it looks opaque, it is
  URL-safe, and `after_cursor/3` resumes exactly where the page ended. A
  *synthetic* cursor for any instant comes from `EchoData.Snowflake.min_for/1`,
  so "everything since 14:00" needs no stored id at all.

  The table is `:public` with read/write concurrency; in production give it an
  owner process (or an `heir`) so its lifetime is supervised.
  """

  alias EchoData.{BrandedId, Snowflake}

  defstruct [:tab, :ns]

  def new(ns) when is_binary(ns) and byte_size(ns) == 3 do
    tab =
      :ets.new(:branded_timeline, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    %__MODULE__{tab: tab, ns: ns}
  end

  @doc "Inserts by branded ID (namespace enforced) or appends a freshly minted entry."
  def put(%__MODULE__{tab: tab, ns: ns}, id, value) do
    case BrandedId.parse(id) do
      {:ok, ^ns, snow} ->
        :ets.insert(tab, {snow, value})
        :ok

      _ ->
        raise ArgumentError, "expected a #{ns} branded id, got: #{inspect(id)}"
    end
  end

  def put_by_snowflake(%__MODULE__{tab: tab}, snow, value) when is_integer(snow) do
    :ets.insert(tab, {snow, value})
    :ok
  end

  @doc "Mints, inserts, returns the branded id — an append-only event feed in one call."
  def append(%__MODULE__{tab: tab, ns: ns}, value) do
    snow = Snowflake.next()
    :ets.insert(tab, {snow, value})
    BrandedId.encode!(ns, snow)
  end

  def fetch(%__MODULE__{tab: tab, ns: ns}, id) do
    with {:ok, ^ns, snow} <- BrandedId.parse(id),
         [{^snow, value}] <- :ets.lookup(tab, snow) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  @doc "Newest `n` entries, newest first."
  def latest(%__MODULE__{tab: tab, ns: ns}, n) when n > 0 do
    walk(tab, :ets.last(tab), n, ns, &:ets.prev/2, [])
    |> :lists.reverse()
  end

  @doc "The page strictly after `cursor` (a branded id), oldest first — resumable pagination."
  def after_cursor(%__MODULE__{tab: tab, ns: ns}, cursor, n) when n > 0 do
    case BrandedId.parse(cursor) do
      {:ok, ^ns, snow} ->
        walk(tab, :ets.next(tab, snow), n, ns, &:ets.next/2, []) |> :lists.reverse()

      _ ->
        raise ArgumentError, "invalid cursor: #{inspect(cursor)}"
    end
  end

  @doc "The page at or after an instant — a synthetic cursor, no stored id needed."
  def since(%__MODULE__{tab: tab, ns: ns}, %DateTime{} = dt, n) when n > 0 do
    from = Snowflake.min_for(dt)
    walk(tab, :ets.next(tab, from - 1), n, ns, &:ets.next/2, []) |> :lists.reverse()
  end

  @doc "How many entries landed in `[from, until)` — one bounded `select_count`."
  def window_count(%__MODULE__{tab: tab}, %DateTime{} = from, %DateTime{} = until) do
    lo = Snowflake.min_for(from)
    hi = Snowflake.min_for(until)

    :ets.select_count(tab, [
      {{:"$1", :_}, [{:andalso, {:>=, :"$1", lo}, {:<, :"$1", hi}}], [true]}
    ])
  end

  def size(%__MODULE__{tab: tab}), do: :ets.info(tab, :size)

  def delete(%__MODULE__{tab: tab, ns: ns}, id) do
    with {:ok, ^ns, snow} <- BrandedId.parse(id) do
      :ets.delete(tab, snow)
      :ok
    else
      _ -> :error
    end
  end

  defp walk(_tab, :"$end_of_table", _n, _ns, _step, acc), do: acc
  defp walk(_tab, _key, 0, _ns, _step, acc), do: acc

  defp walk(tab, key, n, ns, step, acc) do
    case :ets.lookup(tab, key) do
      [{^key, value}] ->
        walk(tab, step.(tab, key), n - 1, ns, step, [{BrandedId.encode!(ns, key), value} | acc])

      [] ->
        walk(tab, step.(tab, key), n, ns, step, acc)
    end
  end
end

defmodule EchoData.Buckets do
  @moduledoc """
  A generational store: entries grouped into time buckets derived from the
  snowflake itself — `bucket = snowflake >>> (22 + bucket_bits)`, so a bucket
  spans `2^bucket_bits` milliseconds. The id carries its own creation time,
  which turns expiry from a per-entry bookkeeping problem into a structural
  one: `expire_older_than/2` drops whole buckets, O(buckets), touching no
  entry. Sessions, presence, rate-limit windows, ephemeral caches — anything
  whose lifetime is "minted less than X ago" — pay nothing per entry for TTL.

  Persistent value semantics throughout (plain nested maps); `fetch/2` is two
  map hops because the bucket of any id is computable, never searched for.
  """

  import Bitwise
  alias EchoData.{BrandedId, Snowflake}

  defstruct bucket_bits: 12, shift: 34, buckets: %{}, size: 0

  @doc "`bucket_bits` sets granularity: 10 → 1.024 s, 12 → 4.096 s, 16 → ~65 s, 20 → ~17.5 min."
  def new(opts \\ []) do
    bits = Keyword.get(opts, :bucket_bits, 12)
    %__MODULE__{bucket_bits: bits, shift: 22 + bits}
  end

  def put(%__MODULE__{} = b, id, value) when is_binary(id) do
    case BrandedId.decode(id) do
      {:ok, snow} -> put_by_snowflake(b, snow, value)
      :error -> raise ArgumentError, "invalid branded id: #{inspect(id)}"
    end
  end

  def put_by_snowflake(%__MODULE__{shift: shift, buckets: buckets, size: size} = b, snow, value) do
    key = snow >>> shift
    inner = Map.get(buckets, key, %{})
    delta = if is_map_key(inner, snow), do: 0, else: 1

    %__MODULE__{
      b
      | buckets: Map.put(buckets, key, Map.put(inner, snow, value)),
        size: size + delta
    }
  end

  def fetch(%__MODULE__{} = b, id) when is_binary(id) do
    with {:ok, snow} <- BrandedId.decode(id), do: fetch_by_snowflake(b, snow)
  end

  def fetch_by_snowflake(%__MODULE__{shift: shift, buckets: buckets}, snow) do
    key = snow >>> shift

    case buckets do
      %{^key => inner} -> Map.fetch(inner, snow)
      _ -> :error
    end
  end

  def delete_by_snowflake(%__MODULE__{shift: shift, buckets: buckets, size: size} = b, snow) do
    key = snow >>> shift

    with %{^key => inner} <- buckets, true <- is_map_key(inner, snow) do
      inner = Map.delete(inner, snow)

      buckets =
        if map_size(inner) == 0, do: Map.delete(buckets, key), else: Map.put(buckets, key, inner)

      %__MODULE__{b | buckets: buckets, size: size - 1}
    else
      _ -> b
    end
  end

  @doc "Drops every bucket strictly older than the instant. O(number of buckets)."
  def expire_older_than(
        %__MODULE__{shift: shift, buckets: buckets, size: size} = b,
        %DateTime{} = dt
      ) do
    cutoff = Snowflake.min_for(dt) >>> shift

    {dropped, kept} = Enum.split_with(buckets, fn {key, _} -> key < cutoff end)
    expired = Enum.reduce(dropped, 0, fn {_, inner}, acc -> acc + map_size(inner) end)

    {expired, %__MODULE__{b | buckets: Map.new(kept), size: size - expired}}
  end

  def size(%__MODULE__{size: size}), do: size
  def bucket_count(%__MODULE__{buckets: buckets}), do: map_size(buckets)

  def to_snowflake_list(%__MODULE__{buckets: buckets}) do
    for {_key, inner} <- buckets, {snow, v} <- inner, do: {snow, v}
  end
end

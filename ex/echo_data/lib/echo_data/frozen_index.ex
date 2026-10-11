defmodule EchoData.FrozenIndex do
  @moduledoc """
  An immutable membership-and-range index: snowflakes sorted into one flat
  binary, 8 bytes per entry, searched by binary search over bit-syntax slices.
  Two properties make it more than a curiosity. First, density: 8 B/entry
  against the tens of bytes a `MapSet` entry costs on the heap. Second — the
  pure-Elixir answer to the snapshot-handoff niche the Rust resource owned in
  the persistence article — a binary over 64 bytes is reference-counted on
  the BEAM, so SENDING the index to another process copies nothing: thousands
  of LiveView processes can share one allowlist/published-set snapshot for
  the cost of a pointer.

  Because the entries are sorted snowflakes, `range_count/3` answers "how many
  ids were minted in this window" in two binary searches — interval analytics
  on a frozen set with no scan.
  """

  alias EchoData.{BrandedId, Snowflake}

  defstruct [:bin, :count]

  @doc "Freezes any enumerable of snowflakes or branded ids (deduplicated, sorted)."
  def freeze(enum) do
    snows =
      enum
      |> Enum.map(fn
        snow when is_integer(snow) -> snow
        id when is_binary(id) -> BrandedId.decode!(id)
      end)
      |> Enum.sort()
      |> Enum.dedup()

    bin = for snow <- snows, into: <<>>, do: <<snow::unsigned-64>>
    %__MODULE__{bin: bin, count: length(snows)}
  end

  def member?(%__MODULE__{} = idx, id) when is_binary(id) do
    case BrandedId.decode(id) do
      {:ok, snow} -> member_snowflake?(idx, snow)
      :error -> false
    end
  end

  def member_snowflake?(%__MODULE__{bin: bin, count: count}, snow) do
    pos = lower_bound(bin, count, snow)
    pos < count and at(bin, pos) == snow
  end

  @doc "Entries minted in `[from, until)` — two binary searches, no scan."
  def range_count(%__MODULE__{bin: bin, count: count}, %DateTime{} = from, %DateTime{} = until) do
    lower_bound(bin, count, Snowflake.min_for(until)) -
      lower_bound(bin, count, Snowflake.min_for(from))
  end

  def count(%__MODULE__{count: count}), do: count
  def bytes(%__MODULE__{bin: bin}), do: byte_size(bin)

  def min(%__MODULE__{count: 0}), do: :error
  def min(%__MODULE__{bin: <<snow::unsigned-64, _::binary>>}), do: {:ok, snow}

  def max(%__MODULE__{count: 0}), do: :error
  def max(%__MODULE__{bin: bin, count: count}), do: {:ok, at(bin, count - 1)}

  def to_snowflake_list(%__MODULE__{bin: bin}), do: for(<<snow::unsigned-64 <- bin>>, do: snow)

  # first position whose value is >= target
  defp lower_bound(bin, count, target), do: lb(bin, 0, count, target)

  defp lb(_bin, lo, lo, _target), do: lo

  defp lb(bin, lo, hi, target) do
    mid = div(lo + hi, 2)

    if at(bin, mid) < target do
      lb(bin, mid + 1, hi, target)
    else
      lb(bin, lo, mid, target)
    end
  end

  defp at(bin, i) do
    <<_::binary-size(i * 8), snow::unsigned-64, _::binary>> = bin
    snow
  end
end

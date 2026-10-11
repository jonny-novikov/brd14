defmodule EchoData.Graft.PageSet do
  @moduledoc """
  A compact sparse set of page indices — the pure-Elixir stand-in for Graft's
  `splinter-rs` bitmap. A Segment references the set of page indices it carries;
  a Snapshot's resolution index is built from these sets.

  Membership is a `MapSet`; the wire form is a sorted **delta + varint** binary,
  which is small for the clustered, sparse index sets a page workload produces.
  If sets grow large and dense enough that this representation costs, a
  Roaring-style bitmap (or a Rustler binding to `splinter-rs`) is the forward
  optimization — at the price of native code in the BEAM, the same trade the
  journal-isolation design weighs, so the pure form is the default.
  """
  import Bitwise

  @opaque t :: MapSet.t(non_neg_integer())

  @spec new() :: t
  def new, do: MapSet.new()

  @spec from_list([non_neg_integer()]) :: t
  def from_list(list), do: MapSet.new(list)

  @spec put(t, non_neg_integer()) :: t
  def put(set, idx) when is_integer(idx) and idx >= 0, do: MapSet.put(set, idx)

  @spec member?(t, non_neg_integer()) :: boolean()
  def member?(set, idx), do: MapSet.member?(set, idx)

  @spec size(t) :: non_neg_integer()
  def size(set), do: MapSet.size(set)

  @spec union(t, t) :: t
  def union(a, b), do: MapSet.union(a, b)

  @spec to_list(t) :: [non_neg_integer()]
  def to_list(set), do: set |> MapSet.to_list() |> Enum.sort()

  @doc "Serializes the set to a sorted delta-varint binary."
  @spec encode(t) :: binary()
  def encode(set) do
    set
    |> to_list()
    |> deltas(0, [])
    |> Enum.map(&varint/1)
    |> IO.iodata_to_binary()
  end

  @doc "Parses a delta-varint binary back into a set."
  @spec decode(binary()) :: t
  def decode(bin) when is_binary(bin) do
    bin |> unvarint([]) |> undeltas(0, []) |> MapSet.new()
  end

  # --- delta coding -------------------------------------------------------
  defp deltas([], _prev, acc), do: Enum.reverse(acc)
  defp deltas([h | t], prev, acc), do: deltas(t, h, [h - prev | acc])

  defp undeltas([], _prev, acc), do: Enum.reverse(acc)
  defp undeltas([d | t], prev, acc) do
    v = prev + d
    undeltas(t, v, [v | acc])
  end

  # --- LEB128-style varint ------------------------------------------------
  defp varint(n) when n >= 0 and n < 0x80, do: <<n>>
  defp varint(n) when n >= 0x80, do: <<1::1, band(n, 0x7F)::7>> <> varint(bsr(n, 7))

  defp unvarint(<<>>, acc), do: Enum.reverse(acc)
  defp unvarint(bin, acc) do
    {v, rest} = take_varint(bin, 0, 0)
    unvarint(rest, [v | acc])
  end

  defp take_varint(<<1::1, x::7, rest::binary>>, shift, acc),
    do: take_varint(rest, shift + 7, bor(acc, bsl(x, shift)))

  defp take_varint(<<0::1, x::7, rest::binary>>, shift, acc),
    do: {bor(acc, bsl(x, shift)), rest}
end

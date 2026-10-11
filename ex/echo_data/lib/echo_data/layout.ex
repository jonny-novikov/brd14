defmodule EchoData.Layout do
  @moduledoc """
  Layout profiles (docs/contract.md, Extensions): custom metadata inside a valid 14-byte id.

  A profile `(n, s, m)` re-splits the 22 bits under the timestamp as
  `node(n) | seq(s) | meta(m)`, meta lowest, with `n + s + m = 22`. `{10, 12, 0}` is the base
  layout bit for bit, so every existing id reads the same under `std/0`. The id is still a brd14
  id — same codec, same order — and the profile is not recorded in it: bind a namespace's profile
  where its policy lives (`EchoData.Namespace`), and never change it once ids exist.

  Meta sits lowest so one generator stays strictly increasing whatever meta each id carries: the
  cell `ts <<< s ||| seq` advances exactly as `EchoData.Snowflake`'s does.

      iex> {:ok, audit} = EchoData.Layout.new(6, 12, 4)
      iex> {:ok, snow} = EchoData.Layout.pack(audit, 65_459_497_641, 33, 7, 0b1001)
      iex> EchoData.Layout.fields(audit, snow)
      {:ok, {65_459_497_641, 33, 7, 9}}
      iex> EchoData.Layout.new(10, 12, 1)
      {:error, :layout}
  """

  import Bitwise

  @low_bits 22
  @ts_limit 1 <<< 41
  @max_snow 9_223_372_036_854_775_807
  @epoch_ms 1_704_067_200_000

  @enforce_keys [:node, :seq, :meta]
  defstruct [:node, :seq, :meta]

  @type t :: %__MODULE__{node: 0..22, seq: 0..22, meta: 0..22}

  @doc "The base layout, `{10, 12, 0}`."
  @spec std() :: t()
  def std, do: %__MODULE__{node: 10, seq: 12, meta: 0}

  @doc "A profile, or `{:error, :layout}` unless each width is in 0..22 and they sum to 22."
  @spec new(integer(), integer(), integer()) :: {:ok, t()} | {:error, :layout}
  def new(n, s, m)
      when is_integer(n) and is_integer(s) and is_integer(m) and n in 0..@low_bits and
             s in 0..@low_bits and m in 0..@low_bits and n + s + m == @low_bits,
      do: {:ok, %__MODULE__{node: n, seq: s, meta: m}}

  def new(_, _, _), do: {:error, :layout}

  @doc "Like `new/3`, raising `ArgumentError` on an invalid profile."
  @spec new!(integer(), integer(), integer()) :: t()
  def new!(n, s, m) do
    case new(n, s, m) do
      {:ok, layout} -> layout
      {:error, :layout} -> raise ArgumentError, "invalid layout profile #{inspect({n, s, m})}"
    end
  end

  @doc "`{ts, node, seq, meta}` of a snowflake under the profile; `{:error, :range}` at or above 2^63."
  @spec fields(t(), integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}}
          | {:error, :range}
  def fields(%__MODULE__{seq: s, meta: m} = l, snow)
      when is_integer(snow) and snow >= 0 and snow <= @max_snow do
    {:ok,
     {snow >>> @low_bits, snow >>> (s + m) &&& mask(l.node), snow >>> m &&& mask(s),
      snow &&& mask(m)}}
  end

  def fields(%__MODULE__{}, _snow), do: {:error, :range}

  @doc "The snowflake of the fields under the profile; `{:error, :range}` if one does not fit."
  @spec pack(t(), integer(), integer(), integer(), integer()) ::
          {:ok, non_neg_integer()} | {:error, :range}
  def pack(%__MODULE__{node: n, seq: s, meta: m}, ts, node, seq, meta)
      when is_integer(ts) and ts >= 0 and ts < @ts_limit and is_integer(node) and node >= 0 and
             node < 1 <<< n and is_integer(seq) and seq >= 0 and seq < 1 <<< s and
             is_integer(meta) and meta >= 0 and meta < 1 <<< m do
    {:ok, ts <<< @low_bits ||| node <<< (s + m) ||| seq <<< m ||| meta}
  end

  def pack(%__MODULE__{}, _ts, _node, _seq, _meta), do: {:error, :range}

  defp mask(bits), do: (1 <<< bits) - 1

  # ── the profiled generator ─────────────────────────────────────────────────

  defmodule Generator do
    @moduledoc false
    @type t :: %__MODULE__{}
    @enforce_keys [:layout, :node, :cell, :clock]
    defstruct [:layout, :node, :cell, :clock]
  end

  @doc """
  A generator under the profile, minting with a fixed `node`. Lock-free like
  `EchoData.Snowflake`: one `:atomics` cell holding `ts <<< s ||| seq`, advanced by CAS to
  `max(now, last + 1)`. `clock:` (a 0-arity function returning Unix ms) is for tests.
  """
  @spec generator(t(), non_neg_integer(), keyword()) :: {:ok, Generator.t()} | {:error, :range}
  def generator(%__MODULE__{node: n} = layout, node, opts \\ [])
      when is_integer(node) and node >= 0 do
    if node < 1 <<< n do
      clock = Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)
      cell = :atomics.new(1, signed: true)
      :atomics.put(cell, 1, 0)
      {:ok, %Generator{layout: layout, node: node, cell: cell, clock: clock}}
    else
      {:error, :range}
    end
  end

  @doc "Mints the next snowflake carrying `meta`; `{:error, :range}` if `meta` does not fit."
  @spec next(Generator.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, :range}
  def next(%Generator{layout: %__MODULE__{seq: s, meta: m} = l, node: node} = g, meta \\ 0)
      when is_integer(meta) do
    if meta >= 0 and meta < 1 <<< m do
      cell = advance(g.cell, (g.clock.() - @epoch_ms) <<< s)
      pack(l, cell >>> s, node, cell &&& mask(s), meta)
    else
      {:error, :range}
    end
  end

  defp advance(ref, cand) do
    last = :atomics.get(ref, 1)
    next = max(cand, last + 1)

    case :atomics.compare_exchange(ref, 1, last, next) do
      :ok -> next
      _ -> advance(ref, cand)
    end
  end
end

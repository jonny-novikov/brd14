defmodule EchoData.Snowflake do
  @moduledoc """
  Lock-free snowflake generator. Layout: `ts(41) <<< 22 ||| node(10) <<< 12 ||| seq(12)`,
  epoch 2024-01-01T00:00:00Z, values in `[0, 2^63)`.

  State is one `:atomics` cell holding `ts <<< 12 ||| seq` (53 bits). Each mint
  performs a compare-exchange of `max(now_part, last + 1)`:

    * normal flow — the clock advanced, `now_part` wins, sequence restarts;
    * burst — same millisecond, `last + 1` increments the sequence;
    * sequence exhausted (4096/ms) — the carry borrows into the timestamp,
      preserving strict monotonicity at the cost of running at most a few
      milliseconds ahead under sustained >4M ids/s;
    * clock regression — `now_part < last`, so `last + 1` keeps minting from
      the logical clock; no duplicates, no blocking.

  Call `start/1` once (typically in `Application.start/2`). The node field is
  fixed at `start/1`; `next/1` accepts a per-call node id over the SAME cell,
  for callers that derive the node at mint time (the timestamp+sequence parts —
  the only collision-bearing fields — come from the shared monotonic cell, so a
  per-call node never reintroduces a same-millisecond collision).

  ## Back-compat helpers (re-implemented atop the lock-free core)

  `generate/1`, `timestamp/1`, `worker_id/1`, and `extract/1` preserve the prior
  `EchoData.Snowflake` surface still named by the umbrella's id consumers on the
  unchanged bit layout.
  """

  import Bitwise

  @epoch_ms 1_704_067_200_000
  @seq_bits 12
  @node_bits 10
  @worker_mask (1 <<< @node_bits) - 1
  @sequence_mask (1 <<< @seq_bits) - 1
  @key {__MODULE__, :state}

  @doc "Initializes the generator. `node_id` in 0..1023; defaults to `phash2(node())`. Idempotent."
  def start(node_id \\ nil) do
    node_id =
      node_id || Application.get_env(:echo_data, :node_id) ||
        :erlang.phash2(node(), 1 <<< @node_bits)

    unless node_id in 0..((1 <<< @node_bits) - 1) do
      raise ArgumentError, "node_id must be in 0..1023, got: #{inspect(node_id)}"
    end

    case :persistent_term.get(@key, nil) do
      nil ->
        ref = :atomics.new(1, signed: true)
        :atomics.put(ref, 1, now_part())
        :persistent_term.put(@key, {ref, node_id})
        :ok

      {_ref, _node} ->
        :ok
    end
  end

  @doc "Mints the next snowflake using the node fixed at `start/1`. Safe to call concurrently."
  @spec next() :: non_neg_integer()
  def next do
    {ref, node_id} = state()
    pack(advance(ref, now_part()), node_id)
  end

  @doc """
  Mints the next snowflake with a caller-supplied `node_id` (0..1023) over the
  shared monotonic cell. The timestamp+sequence parts come from the same
  lock-free CAS as `next/0`, so concurrent `next/0`/`next/1` mints never collide.
  """
  @spec next(non_neg_integer()) :: non_neg_integer()
  def next(node_id) when is_integer(node_id) and node_id >= 0 and node_id <= @worker_mask do
    {ref, _node} = state()
    pack(advance(ref, now_part()), node_id)
  end

  # Packs a monotonic `ts <<< 12 ||| seq` value and a node id into the wire layout.
  defp pack(v, node_id) do
    ts = v >>> @seq_bits
    seq = v &&& 0xFFF
    ts <<< 22 ||| node_id <<< @seq_bits ||| seq
  end

  defp state do
    :persistent_term.get(@key, nil) ||
      raise("EchoData.Snowflake.start/1 has not been called")
  end

  defp advance(ref, cand) do
    last = :atomics.get(ref, 1)
    next = max(cand, last + 1)

    case :atomics.compare_exchange(ref, 1, last, next) do
      :ok -> next
      _actual -> advance(ref, cand)
    end
  end

  defp now_part, do: (System.system_time(:millisecond) - @epoch_ms) <<< @seq_bits

  @doc "Mints and brands in one call."
  def next_branded(ns), do: EchoData.BrandedId.encode!(ns, next())

  @spec unix_ms(non_neg_integer()) :: non_neg_integer()
  def unix_ms(snowflake), do: (snowflake >>> 22) + @epoch_ms

  @spec to_datetime(non_neg_integer()) :: DateTime.t()
  def to_datetime(snowflake), do: DateTime.from_unix!(unix_ms(snowflake), :millisecond)

  def node_id(snowflake), do: snowflake >>> @seq_bits &&& 0x3FF
  def sequence(snowflake), do: snowflake &&& 0xFFF

  @doc "Smallest snowflake mintable at or after the instant; for half-open time-range scans."
  def min_for(%DateTime{} = dt) do
    (DateTime.to_unix(dt, :millisecond) - @epoch_ms) <<< 22
  end

  def valid?(s), do: is_integer(s) and s >= 0 and s <= 9_223_372_036_854_775_807

  def epoch_ms, do: @epoch_ms

  # ---- back-compat helpers (re-implemented atop the unchanged bit layout) ------

  @doc """
  Mints a snowflake with explicit `worker_id:`/`sequence:` options on the
  unchanged bit layout. Retained for consumers that pass an explicit
  `worker_id`; the defaults preserve the prior per-process behavior.

  ## Options

    * `:worker_id` — 0..1023, default derived from the calling process;
    * `:sequence` — 0..4095, default an auto-incrementing per-process counter.
  """
  @spec generate(keyword()) :: non_neg_integer()
  def generate(opts \\ []) do
    ts = System.system_time(:millisecond) - @epoch_ms
    worker = Keyword.get(opts, :worker_id, default_worker_id())
    seq = Keyword.get(opts, :sequence, next_sequence())
    ts <<< 22 ||| (worker &&& @worker_mask) <<< @seq_bits ||| (seq &&& @sequence_mask)
  end

  @doc "The mint instant of a snowflake as a `DateTime` (≡ `to_datetime/1`)."
  @spec timestamp(non_neg_integer()) :: DateTime.t()
  def timestamp(snowflake) when is_integer(snowflake) and snowflake >= 0 do
    to_datetime(snowflake)
  end

  @doc "The 10-bit worker/node field of a snowflake (≡ `node_id/1`)."
  @spec worker_id(non_neg_integer()) :: non_neg_integer()
  def worker_id(snowflake) when is_integer(snowflake) and snowflake >= 0 do
    snowflake >>> @seq_bits &&& @worker_mask
  end

  @doc "Decodes a snowflake into its `%{timestamp, timestamp_ms, worker_id, sequence}` fields."
  @spec extract(non_neg_integer()) :: %{
          timestamp: DateTime.t(),
          timestamp_ms: non_neg_integer(),
          worker_id: non_neg_integer(),
          sequence: non_neg_integer()
        }
  def extract(snowflake) when is_integer(snowflake) and snowflake >= 0 do
    ms = unix_ms(snowflake)

    %{
      timestamp: DateTime.from_unix!(ms, :millisecond),
      timestamp_ms: ms,
      worker_id: worker_id(snowflake),
      sequence: sequence(snowflake)
    }
  end

  defp default_worker_id, do: :erlang.phash2(self(), @worker_mask + 1)

  defp next_sequence do
    seq = Process.get(:echo_data_snowflake_sequence, 0)
    Process.put(:echo_data_snowflake_sequence, seq + 1 &&& @sequence_mask)
    seq
  end
end

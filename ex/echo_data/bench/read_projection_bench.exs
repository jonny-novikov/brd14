# bcs2.2 E4 — the figure: mailbox reads vs projection reads, 8 concurrent readers.
#
# Run: cd echo/apps/echo_data && TMPDIR=/tmp mix run bench/read_projection_bench.exs
#
# Derivation (before measurement, the house law): the bcs1.1 read path is one
# serialized GenServer.call round-trip through a single owner mailbox — its
# aggregate ceiling is 1/rtt regardless of reader count, so it cannot beat 1x
# its single-reader rate at any reader count. The projection path is an
# :ets.lookup-class operation under read_concurrency: true in the caller's
# process — it scales with schedulers until memory bandwidth. At 8 readers the
# claimed floor (projection >= 3x mailbox) is deliberately conservative.
#
# The {:get, id} arm is deleted from the shipped store (reads are caller-side
# since bcs2.2), so the HEAD-shape call path is preserved for comparison by a
# bench-local GenServer whose read arm replicates the bcs1.1 shape byte-for-
# byte (gate + :ets.lookup on a private ordered_set — property_store.ex:61-72
# @ 3b99e42b), holding the same seeded data.

defmodule Bench.MailboxStore do
  @moduledoc false
  use GenServer

  alias EchoData.Bcs

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    ns = Keyword.fetch!(opts, :namespace)
    GenServer.start_link(__MODULE__, ns, name: name)
  end

  @impl true
  def init(ns) do
    table = :ets.new(:bench_mailbox_tab, [:ordered_set, :private])
    {:ok, %{ns: ns, table: table}}
  end

  @impl true
  def handle_call({:put, id, value}, _from, s) do
    case Bcs.gate(id, s.ns) do
      {:ok, _snow} ->
        :ets.insert(s.table, {id, value})
        {:reply, :ok, s}

      {:error, _} = err ->
        {:reply, err, s}
    end
  end

  # the bcs1.1 read arm, byte-shape (HEAD property_store.ex:61-72 @ 3b99e42b)
  def handle_call({:get, id}, _from, s) do
    case Bcs.gate(id, s.ns) do
      {:ok, _snow} ->
        case :ets.lookup(s.table, id) do
          [{^id, value}] -> {:reply, {:ok, value}, s}
          [] -> {:reply, {:error, :not_found}, s}
        end

      {:error, _} = err ->
        {:reply, err, s}
    end
  end
end

defmodule Bench.ReadProjection do
  @moduledoc false

  alias EchoData.BrandedId
  alias EchoData.Bcs.Projection
  alias EchoData.Bcs.PropertyStore

  @ns "ORD"
  @n_ids 10_000
  @readers 8
  @passes 2
  @floor 3.0

  def main do
    IO.puts("""
    bcs2.2 read-projection bench — #{@readers} readers x #{@passes} passes x #{@n_ids} ids per path

    DERIVATION (before measurement): a serialized mailbox is capped at 1/rtt in
    aggregate — it cannot beat 1x at any reader count; an :ets.lookup under
    read_concurrency scales with schedulers. Floor claimed: >= #{@floor}x at #{@readers} readers.
    """)

    {:ok, _} = PropertyStore.start_link(name: :bench_props, namespace: @ns)
    {:ok, _} = Bench.MailboxStore.start_link(name: :bench_mailbox, namespace: @ns)

    ids = for i <- 1..@n_ids, do: BrandedId.encode!(@ns, i)
    # a 200-byte value: >= 64 bytes, so it lives off-heap (refc binary) and the
    # projection row shares it — the memory delta is keys + pointers, not payload
    value = :binary.copy(<<0xAB>>, 200)

    Enum.each(ids, fn id ->
      :ok = PropertyStore.put(:bench_props, id, value)
      :ok = GenServer.call(:bench_mailbox, {:put, id, value})
    end)

    proj_read = fn id -> {:ok, _} = PropertyStore.get(:bench_props, id) end
    mail_read = fn id -> {:ok, _} = GenServer.call(:bench_mailbox, {:get, id}) end

    # warm-up pass, both paths, single reader
    run(ids, mail_read, 1, 1)
    run(ids, proj_read, 1, 1)

    {n_mail, us_mail} = run(ids, mail_read, @readers, @passes)
    {n_proj, us_proj} = run(ids, proj_read, @readers, @passes)

    mail_ops = n_mail * 1_000_000 / us_mail
    proj_ops = n_proj * 1_000_000 / us_proj
    speedup = proj_ops / mail_ops

    word = :erlang.system_info(:wordsize)

    truth_tid =
      Enum.find(:ets.all(), fn t -> :ets.info(t, :name) == :bcs_props end) ||
        raise "truth table not found"

    truth_mem = :ets.info(truth_tid, :memory)
    proj_mem = :ets.info(Projection.table_name(:bench_props), :memory)

    IO.puts("""
    mailbox path     : #{fmt(mail_ops)} ops/s  (#{n_mail} reads in #{us_mail} us)
    projection path  : #{fmt(proj_ops)} ops/s  (#{n_proj} reads in #{us_proj} us)
    speedup          : #{Float.round(speedup, 2)}x  (floor #{@floor}x at #{@readers} readers)

    memory (words, #{word}-byte words):
      truth alone            : #{truth_mem} words (#{truth_mem * word} bytes)
      truth + projection     : #{truth_mem + proj_mem} words (#{(truth_mem + proj_mem) * word} bytes)
      projection delta       : #{proj_mem} words (#{proj_mem * word} bytes) for #{@n_ids} rows
    refc note: the 200-byte values are refc binaries (>= 64 bytes, shared
    off-heap) — the projection duplicates keys and pointer words, never payload,
    so the delta is far below 2x the truth's data volume.
    """)

    if speedup >= @floor do
      IO.puts("FLOOR: PASS (#{Float.round(speedup, 2)}x >= #{@floor}x)")
    else
      raise "FLOOR: FAIL — #{Float.round(speedup, 2)}x < #{@floor}x at #{@readers} readers"
    end
  end

  defp run(ids, read_fun, readers, passes) do
    parent = self()
    t0 = System.monotonic_time(:microsecond)

    refs =
      for _ <- 1..readers do
        {_pid, ref} =
          spawn_monitor(fn ->
            for _ <- 1..passes, do: Enum.each(ids, read_fun)
            send(parent, :reader_done)
          end)

        ref
      end

    Enum.each(refs, fn ref ->
      receive do
        {:DOWN, ^ref, :process, _pid, :normal} -> :ok
        {:DOWN, ^ref, :process, _pid, reason} -> raise "reader died: #{inspect(reason)}"
      after
        120_000 -> raise "reader timed out"
      end
    end)

    # drain the done markers
    for _ <- 1..readers do
      receive do
        :reader_done -> :ok
      after
        0 -> :ok
      end
    end

    t1 = System.monotonic_time(:microsecond)
    {readers * passes * length(ids), t1 - t0}
  end

  defp fmt(ops) do
    ops
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1_")
    |> String.reverse()
  end
end

Bench.ReadProjection.main()

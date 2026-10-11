defmodule EchoData.Bcs.PropertyStore do
  @moduledoc """
  A BCS system in skeleton: a GenServer owning one private ordered_set
  property table keyed by the 14-byte branded string. Rung bcs1.1.

  Rung bcs2.2 splits the concern: writes stay on the mailbox against the
  private truth table; reads are served caller-side from a `:protected`
  named projection (`EchoData.Bcs.Projection`) the owner mirrors to as the
  last act before every reply — write-last, so read-your-writes holds the
  instant a write call returns. The gate is the same pure `Bcs.gate/2`,
  now run in the reader's process before any table is touched.
  """

  use GenServer

  alias EchoData.{BrandedId, Bcs}
  alias EchoData.Bcs.Projection

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    # fail fast in the caller, as bcs1.1 did
    Keyword.fetch!(opts, :namespace)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(store, id, value) when is_binary(id), do: GenServer.call(store, {:put, id, value})

  @doc "Caller-side read over the projection: gate first, then `:ets.lookup`."
  def get(store, id) when is_binary(id) do
    t = proj_table(store)

    case Bcs.gate(id, Projection.gate_meta(t)) do
      {:ok, _snow} ->
        case :ets.lookup(t, id) do
          [{^id, value}] -> {:ok, value}
          [] -> {:error, :not_found}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Caller-side descending page walk over the projection (ungated, as bcs1.1 shipped it)."
  def page_desc(store, n) when is_integer(n) and n > 0 do
    t = proj_table(store)
    {:ok, walk_desc(t, :ets.last(t), n)}
  end

  @doc """
  Record a bare entity (`{id, true}`), silently dropping a foreign kind.
  The arm stays a cast; the wrapper synchronizes with a no-op `:sync` call
  that queues BEHIND the cast in the normal mailbox, so read-your-writes
  holds the instant this returns (US3), exactly as the bcs1.1 read-as-call
  serialized behind pending casts. The barrier rides the NORMAL mailbox,
  never a system message: a suspended owner still answers the sys plane
  without draining its mailbox, so a sys-plane barrier returns while the
  cast is still queued — this call blocks under suspension in `put/3`'s
  class instead (Apollo G-1 / D-6).
  """
  def record_entity(store, id) when is_binary(id) do
    :ok = GenServer.cast(store, {:entity, id})
    :ok = GenServer.call(store, :sync)
    :ok
  end

  @doc """
  Ascending ids in [lo, hi) — Chapter 1.5's synthetic cursors landed on the
  ordered_set. Bounds are branded ids (synthetic via min_for or real) and are
  gated like any ingress. Added by the Chapter 2.2 architecture review.
  Caller-side since bcs2.2: both bounds gated, then the select runs on the
  projection with the bcs1.1 match spec.
  """
  def window(store, lo, hi) when is_binary(lo) and is_binary(hi) do
    t = proj_table(store)
    ns = Projection.gate_meta(t)

    with {:ok, _} <- Bcs.gate(lo, ns),
         {:ok, _} <- Bcs.gate(hi, ns) do
      spec = [{{:"$1", :_}, [{:>=, :"$1", {:const, lo}}, {:<, :"$1", {:const, hi}}], [:"$1"]}]
      {:ok, :ets.select(t, spec)}
    else
      {:error, _} = err -> err
    end
  end

  @spec placement(binary()) :: {:ok, non_neg_integer()} | {:error, :invalid}
  def placement(id) when is_binary(id) do
    case BrandedId.parse(id) do
      {:ok, _ns, snow} -> {:ok, BrandedId.hash32(snow)}
      :error -> {:error, :invalid}
    end
  end

  @impl true
  def init(opts) do
    {:ok, _mode} = BrandedId.self_check!()
    ns = Keyword.fetch!(opts, :namespace)
    name = Keyword.fetch!(opts, :name)
    table = :ets.new(:bcs_props, [:ordered_set, :private])

    proj =
      name
      |> Projection.table_name()
      |> Projection.open(gate: ns, heir: Keyword.get(opts, :heir))

    {:ok, %{ns: ns, table: table, proj: proj}}
  end

  @impl true
  def handle_call({:put, id, value}, _from, s) do
    case Bcs.gate(id, s.ns) do
      {:ok, _snow} ->
        :ets.insert(s.table, {id, value})
        # write-last law: the projection is the final write before the reply
        :ets.insert(s.proj, {id, value})
        {:reply, :ok, s}

      {:error, _} = err ->
        {:reply, err, s}
    end
  end

  # the record_entity/2 mailbox barrier (D-6): a no-op answered only when the
  # owner has drained everything ahead of it — including the {:entity, …} cast
  def handle_call(:sync, _from, s), do: {:reply, :ok, s}

  @impl true
  def handle_cast({:entity, id}, s) do
    case Bcs.gate(id, s.ns) do
      {:ok, _snow} ->
        :ets.insert(s.table, {id, true})
        # write-last law: the projection is the final write of the arm
        :ets.insert(s.proj, {id, true})

      {:error, _} ->
        :ok
    end

    {:noreply, s}
  end

  defp proj_table(store) when is_atom(store), do: Projection.table_name(store)

  defp proj_table(store) when is_pid(store) do
    {:registered_name, name} = Process.info(store, :registered_name)
    Projection.table_name(name)
  end

  defp walk_desc(_table, :"$end_of_table", _n), do: []
  defp walk_desc(_table, _key, 0), do: []

  defp walk_desc(table, key, n),
    do: [key | walk_desc(table, :ets.prev(table, key), n - 1)]
end

defmodule EchoData.Bcs.EdgeStore do
  @moduledoc """
  A relation as a system: one owning process, one kind of edge, both ends
  gated. *Portfolio holds asset* is a row keyed by the tuple of names --
  `{subject, object}` -- never an id list embedded in either endpoint.
  The store owns its own indexes: a forward table for traversal from the
  subject and a reverse table for traversal from the object, maintained
  together by the single owner, exported to nobody. Chapter 2.5.

  Rung bcs2.2 splits the concern: writes stay on the mailbox against the
  private truth tables; reads are served caller-side from two `:protected`
  named projections (`EchoData.Bcs.Projection` — fwd and rev) the owner
  mirrors to as the last acts before every reply — write-last, so
  read-your-writes holds the instant a write call returns. Both ends are
  still gated by the same pure `Bcs.gate/2`, now run in the reader's
  process before any table is touched.
  """

  use GenServer

  alias EchoData.{Bcs, BrandedId}
  alias EchoData.Bcs.Projection

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Creates or updates the edge subject->object with the given props."
  def link(store, subj, obj, props \\ %{}) when is_binary(subj) and is_binary(obj),
    do: GenServer.call(store, {:link, subj, obj, props})

  @doc "Removes the edge in both directions."
  def unlink(store, subj, obj) when is_binary(subj) and is_binary(obj),
    do: GenServer.call(store, {:unlink, subj, obj})

  @doc "The edge's props, if it exists. Caller-side over the forward projection."
  def props(store, subj, obj) when is_binary(subj) and is_binary(obj) do
    t = proj_fwd(store)
    {sns, ons} = Projection.gate_meta(t)

    with {:ok, _} <- Bcs.gate(subj, sns),
         {:ok, _} <- Bcs.gate(obj, ons) do
      case :ets.lookup(t, {subj, obj}) do
        [{_, p}] -> {:ok, p}
        [] -> {:error, :not_found}
      end
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Forward traversal: `{object, props}` ascending by object, optionally limited.
  Caller-side over the forward projection.
  """
  def from(store, subj, limit \\ :all) when is_binary(subj) do
    t = proj_fwd(store)
    {sns, _ons} = Projection.gate_meta(t)

    with {:ok, _} <- Bcs.gate(subj, sns) do
      spec = [{{{subj, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]
      {:ok, take(t, spec, limit)}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Reverse traversal: `{subject, props}` ascending by subject, optionally limited.
  Caller-side over the reverse projection.
  """
  def to(store, obj, limit \\ :all) when is_binary(obj) do
    t = proj_rev(store)
    {_sns, ons} = Projection.gate_meta(t)

    with {:ok, _} <- Bcs.gate(obj, ons) do
      spec = [{{{obj, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]
      {:ok, take(t, spec, limit)}
    else
      {:error, _} = err -> err
    end
  end

  @doc "Forward edge count for a subject. Caller-side over the forward projection."
  def degree(store, subj) when is_binary(subj) do
    t = proj_fwd(store)
    {sns, _ons} = Projection.gate_meta(t)

    with {:ok, _} <- Bcs.gate(subj, sns) do
      {:ok, :ets.select_count(t, [{{{subj, :_}, :_}, [], [true]}])}
    else
      {:error, _} = err -> err
    end
  end

  @impl true
  def init(opts) do
    {:ok, _mode} = BrandedId.self_check!()
    name = Keyword.fetch!(opts, :name)
    sns = Keyword.fetch!(opts, :subject_ns)
    ons = Keyword.fetch!(opts, :object_ns)
    heir = Keyword.get(opts, :heir)

    proj_fwd =
      name
      |> Projection.table_name()
      |> Projection.open(gate: {sns, ons}, heir: heir)

    proj_rev =
      name
      |> Projection.table_name(:rev)
      |> Projection.open(gate: {sns, ons}, heir: heir)

    {:ok,
     %{
       relation: Keyword.fetch!(opts, :relation),
       subject_ns: sns,
       object_ns: ons,
       fwd: :ets.new(:edges_fwd, [:ordered_set, :private]),
       rev: :ets.new(:edges_rev, [:ordered_set, :private]),
       proj_fwd: proj_fwd,
       proj_rev: proj_rev
     }}
  end

  @impl true
  def handle_call({:link, s, o, p}, _from, st) do
    with {:ok, _} <- Bcs.gate(s, st.subject_ns),
         {:ok, _} <- Bcs.gate(o, st.object_ns) do
      :ets.insert(st.fwd, {{s, o}, p})
      :ets.insert(st.rev, {{o, s}, p})
      # write-last law: the projections are the final writes before the reply
      :ets.insert(st.proj_fwd, {{s, o}, p})
      :ets.insert(st.proj_rev, {{o, s}, p})
      {:reply, :ok, st}
    else
      {:error, _} = err -> {:reply, err, st}
    end
  end

  def handle_call({:unlink, s, o}, _from, st) do
    with {:ok, _} <- Bcs.gate(s, st.subject_ns),
         {:ok, _} <- Bcs.gate(o, st.object_ns) do
      if :ets.member(st.fwd, {s, o}) do
        :ets.delete(st.fwd, {s, o})
        :ets.delete(st.rev, {o, s})
        # write-last law: the projections are the final writes before the reply
        :ets.delete(st.proj_fwd, {s, o})
        :ets.delete(st.proj_rev, {o, s})
        {:reply, :ok, st}
      else
        {:reply, {:error, :not_found}, st}
      end
    else
      {:error, _} = err -> {:reply, err, st}
    end
  end

  defp proj_fwd(store) when is_atom(store), do: Projection.table_name(store)
  defp proj_fwd(store) when is_pid(store), do: Projection.table_name(registered!(store))

  defp proj_rev(store) when is_atom(store), do: Projection.table_name(store, :rev)
  defp proj_rev(store) when is_pid(store), do: Projection.table_name(registered!(store), :rev)

  defp registered!(pid) do
    {:registered_name, name} = Process.info(pid, :registered_name)
    name
  end

  defp take(t, spec, :all), do: :ets.select(t, spec)

  defp take(t, spec, n) when is_integer(n) and n > 0 do
    case :ets.select(t, spec, n) do
      {res, _cont} -> res
      :"$end_of_table" -> []
    end
  end
end

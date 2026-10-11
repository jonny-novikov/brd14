defmodule EchoData.Bcs.Projection do
  @moduledoc """
  The read projection: one home for the law. A BCS system store is two tables
  under one owner — the `:private` write table (the truth, read by nobody but
  the owner) and this `:protected`, `read_concurrency: true` **named** view the
  owner maintains and the world reads without a message.

  **The write-last law**: inside every write arm, the owner updates the
  projection as the LAST act before the reply — so when a write call returns,
  the projection reflects it (read-your-writes after return; a concurrent
  reader may observe pre-state until the reply instant, never a torn row).
  A visibility barrier for a cast-shaped write verb must ride the NORMAL
  mailbox (a plain call queued behind the cast), never a system message —
  a suspended owner answers the sys plane without draining its mailbox, so
  a sys-plane barrier claims a visibility the projection does not yet have.
  Only the owner may write (`:protected` — a reader's insert raises); readers
  derive the table atom purely from the store's required `:name` and touch no
  process.

  Lifetime: heir-less by default — the projection dies with its owner; a
  declared `:heir` is the one exception, passed through to `:ets.new`.
  """

  @doc "The projection table atom for a store name: `:\"<name>.reads\"`."
  def table_name(name) when is_atom(name), do: :"#{name}.reads"

  @doc "The reverse-index projection atom: `:\"<name>.reads_rev\"`."
  def table_name(name, :rev) when is_atom(name), do: :"#{name}.reads_rev"

  @doc """
  Open the projection table (owner-side, from `init/1`): `:ordered_set`,
  `:protected`, `:named_table`, `read_concurrency: true`, with an optional
  `:heir` passed through (`heir: {pid, data}` or the raw `{:heir, pid, data}`).

  `gate: meta` records the store's gate metadata beside the table (a
  `:persistent_term` keyed by the table atom) so the caller-side read verbs
  run the same pure `Bcs.gate/2` without touching any process or table —
  the no-process form of the `EchoStore.spec/1` caller-side directory.
  """
  def open(table, opts \\ []) when is_atom(table) do
    base = [:ordered_set, :protected, :named_table, {:read_concurrency, true}]

    ets_opts =
      case List.keyfind(opts, :heir, 0) do
        {:heir, pid, data} -> [{:heir, pid, data} | base]
        {:heir, {pid, data}} -> [{:heir, pid, data} | base]
        {:heir, nil} -> base
        nil -> base
      end

    ^table = :ets.new(table, ets_opts)

    case List.keyfind(opts, :gate, 0) do
      {:gate, meta} -> :persistent_term.put({__MODULE__, table}, meta)
      nil -> :ok
    end

    table
  end

  @doc """
  The gate metadata recorded at `open/2` — fetched in the reader's process,
  before any table dereference (a refused ingress therefore touches no table).
  """
  def gate_meta(table) when is_atom(table), do: :persistent_term.get({__MODULE__, table})
end

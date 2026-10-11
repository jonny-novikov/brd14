defmodule EchoData.Graft.Commit do
  @moduledoc """
  One entry in a Volume's log. `lsn` is the Volume-local monotonic version the
  single writer assigns; `id` is the global `CMT` GID; `segment_id` names the
  Segment carrying this commit's pages; `pages` is the set of page indices the
  commit touched.
  """
  @enforce_keys [:lsn, :id, :segment_id, :pages]
  defstruct [:lsn, :id, :segment_id, :pages, :ts]

  @type t :: %__MODULE__{
          lsn: non_neg_integer(),
          id: EchoData.BrandedId.t(),
          segment_id: EchoData.BrandedId.t(),
          pages: EchoData.Graft.PageSet.t(),
          ts: integer() | nil
        }
end

defmodule EchoData.Graft.Snapshot do
  @moduledoc """
  An immutable view of a Volume at an LSN. `index` resolves a page index to the
  `{lsn, segment_id}` that last wrote it at or below this snapshot — the lookup
  the reader uses to find which Segment to fetch. The struct holds no process
  state and no locks, so any number of readers share it concurrently.
  """
  @enforce_keys [:volume_id, :lsn]
  defstruct [:volume_id, :lsn, index: %{}]

  @type t :: %__MODULE__{
          volume_id: EchoData.BrandedId.t(),
          lsn: non_neg_integer(),
          index: %{optional(non_neg_integer()) => {non_neg_integer(), EchoData.BrandedId.t()}}
        }

  @doc "Resolves which Segment holds `page_idx` at or below this snapshot."
  @spec segment_for(t, non_neg_integer()) :: {:ok, EchoData.BrandedId.t()} | :absent
  def segment_for(%__MODULE__{index: index}, page_idx) do
    case Map.get(index, page_idx) do
      {_lsn, segment_id} -> {:ok, segment_id}
      nil -> :absent
    end
  end
end

defmodule EchoData.Graft.SyncPoint do
  @moduledoc """
  The local↔remote replication cursor for a volume. `local_watermark` is the
  highest local LSN pushed to remote; `remote` is the highest remote LSN pulled
  locally; `volume_id` is the branded volume the cursor coordinates (optional —
  the runtime cursor is keyed by its `db`, so it stays `nil` unless built with
  `new/1`). New snapshots are built from the current SyncPoint, so reads stay
  consistent across the replication boundary.

  The durable frontier beneath a volume's `head_lsn`: the committer/streamer
  drain a log whose pushed/pulled frontier is explicit (the
  commit-log-as-outbox), not implied by "the streamer fired on commit".
  """
  defstruct volume_id: nil, local_watermark: 0, remote: 0

  @type t :: %__MODULE__{
          volume_id: EchoData.BrandedId.t() | nil,
          local_watermark: non_neg_integer(),
          remote: non_neg_integer()
        }

  @doc "A fresh cursor for `volume_id`."
  @spec new(EchoData.BrandedId.t()) :: t()
  def new(volume_id) when is_binary(volume_id), do: %__MODULE__{volume_id: volume_id}

  @doc "Mark the local log pushed up to `lsn` (monotonic; never moves backward)."
  @spec advance_local(t(), non_neg_integer()) :: t()
  def advance_local(%__MODULE__{} = sp, lsn) when is_integer(lsn) and lsn >= 0,
    do: %{sp | local_watermark: max(sp.local_watermark, lsn)}

  @doc "Mark the remote log pulled up to `lsn` (monotonic)."
  @spec advance_remote(t(), non_neg_integer()) :: t()
  def advance_remote(%__MODULE__{} = sp, lsn) when is_integer(lsn) and lsn >= 0,
    do: %{sp | remote: max(sp.remote, lsn)}

  @doc "True when everything the local head holds has reached the remote."
  @spec synced?(t(), head_lsn :: non_neg_integer()) :: boolean()
  def synced?(%__MODULE__{local_watermark: w}, head_lsn), do: w >= head_lsn

  @doc "How many local commits are not yet pushed (the committer/streamer backlog)."
  @spec unsynced(t(), head_lsn :: non_neg_integer()) :: non_neg_integer()
  def unsynced(%__MODULE__{local_watermark: w}, head_lsn), do: max(head_lsn - w, 0)
end

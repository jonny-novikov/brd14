defmodule EchoData.Graft.Id do
  @moduledoc """
  Branded GIDs for Graft entities, minted through the BCS branded-id contract
  (`EchoData.BrandedId`: a `3 x [A-Z]` namespace ++ base62(snowflake), 14 bytes).

  Graft identifies Volumes, Segments, and Commits with GIDs. The BCS branded id
  is the same shape, and its snowflake suffix is monotonic, so a commit id minted
  by a Volume's single writer orders by mint order — which is commit order. That
  is the property `EchoStore.Table`'s newer-wins coherence (a 14-byte version)
  relies on, so a commit id doubles as the page version on the L1.

  Namespaces:

    * `VOL` — a Volume (the replication unit)
    * `SEG` — a Segment (a deduplicated page bundle)
    * `CMT` — a Commit (one entry in a Volume's log)
  """
  alias EchoData.BrandedId

  @spec volume() :: BrandedId.t()
  def volume, do: BrandedId.generate!("VOL")

  @spec segment() :: BrandedId.t()
  def segment, do: BrandedId.generate!("SEG")

  @spec commit() :: BrandedId.t()
  def commit, do: BrandedId.generate!("CMT")

  @doc "Classifies a branded id by its Graft namespace."
  @spec kind(BrandedId.t()) :: :volume | :segment | :commit | :other
  def kind(id) do
    case BrandedId.namespace(id) do
      "VOL" -> :volume
      "SEG" -> :segment
      "CMT" -> :commit
      _ -> :other
    end
  end
end

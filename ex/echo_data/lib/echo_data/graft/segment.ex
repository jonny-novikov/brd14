defmodule EchoData.Graft.Segment do
  @moduledoc """
  A Segment is the unit of page transfer: the deduplicated pages of one (rolled
  up) commit, addressed by `SEG` GID. `build/3` collects the latest version of
  each staged page, packs them into frames of at most `@frame_pages` pages, and
  compresses each frame with zlib (Graft uses Zstd; zlib is the stdlib analogue
  and the codec is swappable). The wire form is self-describing so a replica can
  decode a fetched Segment without out-of-band schema.

  Layout (all integers big-endian):

      <<page_count::32, (page_idx::32, frame_no::16)*page_count,
        frame_count::16, (frame_len::32, zlib_frame::binary)*frame_count>>
  """
  alias EchoData.Graft.PageSet

  @frame_pages 64

  @enforce_keys [:id, :lsn, :pages]
  defstruct [:id, :lsn, :pages, :directory, :frames]

  @type t :: %__MODULE__{
          id: EchoData.BrandedId.t(),
          lsn: non_neg_integer(),
          pages: PageSet.t(),
          directory: %{optional(non_neg_integer()) => non_neg_integer()} | nil,
          frames: [binary()] | nil
        }

  @doc """
  Builds a Segment from a staged page map (`%{page_idx => page_binary}`). Pages
  are sorted by index, chunked into frames of `@frame_pages`, and each frame is
  zlib-compressed. The directory maps each page index to its frame number.
  """
  @spec build(EchoData.BrandedId.t(), non_neg_integer(), %{non_neg_integer() => binary()}) :: t
  def build(id, lsn, staged) when is_map(staged) do
    sorted = staged |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))
    chunks = Enum.chunk_every(sorted, @frame_pages)

    {frames, directory, _} =
      Enum.reduce(chunks, {[], %{}, 0}, fn chunk, {frames, dir, frame_no} ->
        body = chunk |> Enum.map(fn {_idx, bin} -> <<byte_size(bin)::32, bin::binary>> end) |> IO.iodata_to_binary()
        dir = Enum.reduce(chunk, dir, fn {idx, _}, d -> Map.put(d, idx, frame_no) end)
        {[:zlib.compress(body) | frames], dir, frame_no + 1}
      end)

    %__MODULE__{
      id: id,
      lsn: lsn,
      pages: staged |> Map.keys() |> PageSet.from_list(),
      directory: directory,
      frames: Enum.reverse(frames)
    }
  end

  @doc "Reads one page out of a (decoded) Segment, or `:absent`."
  @spec page(t, non_neg_integer()) :: {:ok, binary()} | :absent
  def page(%__MODULE__{directory: dir, frames: frames}, page_idx) do
    with frame_no when is_integer(frame_no) <- Map.get(dir, page_idx, :absent),
         frame when is_binary(frame) <- Enum.at(frames, frame_no) do
      frame |> :zlib.uncompress() |> scan_frame(page_idx, dir, frames)
    else
      _ -> :absent
    end
  end

  # frames hold pages in index order; find ours by walking the frame's records
  # against the directory's page indices that map to this frame
  defp scan_frame(body, page_idx, dir, _frames) do
    idxs = dir |> Enum.filter(fn {_i, f} -> Map.get(dir, page_idx) == f end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    take_page(body, idxs, page_idx)
  end

  defp take_page(<<len::32, page::binary-size(len), rest::binary>>, [idx | idxs], target) do
    if idx == target, do: {:ok, page}, else: take_page(rest, idxs, target)
  end

  defp take_page(_, _, _), do: :absent

  @doc "Serializes a built Segment to its self-describing wire form."
  @spec encode(t) :: binary()
  def encode(%__MODULE__{directory: dir, frames: frames}) do
    entries = dir |> Enum.sort_by(&elem(&1, 0))
    dir_bin = entries |> Enum.map(fn {idx, fno} -> <<idx::32, fno::16>> end) |> IO.iodata_to_binary()
    frames_bin = frames |> Enum.map(fn f -> <<byte_size(f)::32, f::binary>> end) |> IO.iodata_to_binary()
    <<length(entries)::32, dir_bin::binary, length(frames)::16, frames_bin::binary>>
  end

  @doc "Parses a Segment wire form. `id`/`lsn` are carried in the commit, not the blob."
  @spec decode(binary(), EchoData.BrandedId.t(), non_neg_integer()) :: t
  def decode(<<pc::32, rest::binary>>, id, lsn) do
    {dir, rest} = take_dir(rest, pc, %{})
    <<fc::16, frest::binary>> = rest
    frames = take_frames(frest, fc, [])
    %__MODULE__{id: id, lsn: lsn, pages: dir |> Map.keys() |> PageSet.from_list(), directory: dir, frames: frames}
  end

  defp take_dir(rest, 0, acc), do: {acc, rest}
  defp take_dir(<<idx::32, fno::16, rest::binary>>, n, acc), do: take_dir(rest, n - 1, Map.put(acc, idx, fno))

  defp take_frames(_rest, 0, acc), do: Enum.reverse(acc)
  defp take_frames(<<len::32, f::binary-size(len), rest::binary>>, n, acc),
    do: take_frames(rest, n - 1, [f | acc])
end

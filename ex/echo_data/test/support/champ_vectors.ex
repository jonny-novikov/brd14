defmodule EchoData.Test.ChampVectors do
  @moduledoc """
  Replays `vectors/champ.tsv` (docs/structures/spec.md): the SplitMix64 programs, and the shape
  digest — FNV-1a-64 over the preorder serialization of a `ChampNode` trie.
  """
  import Bitwise
  alias EchoData.ChampNode

  @mask64 0xFFFFFFFFFFFFFFFF
  @dir Path.expand("../../../../vectors", __DIR__)

  def path, do: Path.join(@dir, "champ.tsv")
  def present?, do: File.exists?(path())

  @doc "Rows as maps: kind, case, program (list of {:put | :delete, key}), keys, size, digest."
  def rows do
    path()
    |> File.stream!()
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      [kind, name, seed, ops, keys, program, size, digest] = String.split(line, "\t")

      {pool, program} =
        case kind do
          "explicit" ->
            steps = for step <- String.split(program, ","), do: step(step)
            {Enum.map(steps, &elem(&1, 1)), steps}

          "stream" ->
            stream(String.to_integer(seed), String.to_integer(ops), String.to_integer(keys))
        end

      %{
        kind: kind,
        case: name,
        program: program,
        keys: Enum.uniq(pool),
        size: String.to_integer(size),
        digest: digest
      }
    end)
  end

  defp step("+" <> k), do: {:put, String.to_integer(k)}
  defp step("-" <> k), do: {:delete, String.to_integer(k)}

  def stream(seed, ops, keys) do
    {pool, _} =
      Enum.map_reduce(1..keys, bxor(seed, 0xD1B54A32D192ED03), fn _, s ->
        {s, z} = next(s)
        {z >>> 1, s}
      end)

    pool = List.to_tuple(pool)

    {program, _} =
      Enum.map_reduce(1..ops, seed, fn _, s ->
        {s, r} = next(s)
        k = elem(pool, rem(r &&& 0xFFFFFFFF, keys))
        {if(r >>> 62 == 3, do: {:delete, k}, else: {:put, k}), s}
      end)

    {Tuple.to_list(pool), program}
  end

  defp next(s) do
    s = s + 0x9E3779B97F4A7C15 &&& @mask64
    z = s
    z = bxor(z, z >>> 30) * 0xBF58476D1CE4E5B9 &&& @mask64
    z = bxor(z, z >>> 27) * 0x94D049BB133111EB &&& @mask64
    {s, bxor(z, z >>> 31)}
  end

  @doc "16 lowercase hex digits of the shape digest of a ChampNode trie."
  def digest(%ChampNode{} = node) do
    node
    |> serialize([])
    |> IO.iodata_to_binary()
    |> fnv1a64(0xCBF29CE484222325)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end

  defp serialize(%ChampNode{datamap: 0, nodemap: 0, content: {{:collision, pairs}}}, acc) do
    keys = for {k, _} <- pairs, do: <<k::little-64>>
    [acc, <<0x43, length(pairs)::little-32>> | keys]
  end

  defp serialize(%ChampNode{datamap: dm, nodemap: nm, content: content}, acc) do
    data_count = popcount(dm)
    keys = for i <- 0..(data_count - 1)//1, do: <<elem(content, i * 2)::little-64>>
    acc = [acc, <<0x4E, dm::little-32, nm::little-32>> | keys]

    Enum.reduce(0..(popcount(nm) - 1)//1, acc, fn i, a ->
      serialize(elem(content, data_count * 2 + i), a)
    end)
  end

  defp fnv1a64(<<>>, h), do: h
  defp fnv1a64(<<b, rest::binary>>, h), do: fnv1a64(rest, bxor(h, b) * 0x100000001B3 &&& @mask64)

  defp popcount(0), do: 0
  defp popcount(n), do: 1 + popcount(n &&& n - 1)
end

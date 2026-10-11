defmodule EchoData.ChampVectorsTest do
  @moduledoc """
  Shape parity: `EchoData.BrandedChamp` (over `ChampNode`) replays every row of
  `vectors/champ.tsv` and must reproduce its size, its shape digest and the value of every key.
  The vectors come from `tools/champ_oracle.py`, written from docs/structures/spec.md alone.
  """
  use ExUnit.Case, async: true

  alias EchoData.BrandedChamp
  alias EchoData.Test.ChampVectors

  @ns "AAA"

  if ChampVectors.present?() do
    for row <- ChampVectors.rows() do
      @row row
      test "champ.tsv #{row.kind} #{row.case}: size, digest, read-back" do
        %{program: program, keys: keys, size: size, digest: digest} = @row

        {champ, model} =
          program
          |> Enum.with_index()
          |> Enum.reduce({BrandedChamp.new(), %{}}, fn
            {{:put, k}, i}, {c, m} ->
              {BrandedChamp.put_by_snowflake(c, @ns, k, i), Map.put(m, k, i)}

            {{:delete, k}, _}, {c, m} ->
              {BrandedChamp.delete_by_snowflake(c, @ns, k), Map.delete(m, k)}
          end)

        assert BrandedChamp.size(champ) == size
        assert BrandedChamp.namespace_size(champ, @ns) == size
        root = Map.get(champ.namespaces, @ns, EchoData.ChampNode.new())
        assert ChampVectors.digest(root) == digest

        for k <- keys do
          assert BrandedChamp.fetch_by_snowflake(champ, @ns, k) == Map.fetch(model, k)
        end
      end
    end
  else
    if System.get_env("BRD14_REQUIRE_VECTORS") do
      test "vectors/champ.tsv is required" do
        flunk("vectors/champ.tsv absent but BRD14_REQUIRE_VECTORS is set")
      end
    end
  end
end
